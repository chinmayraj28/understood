import Foundation
import HFCore
import os

/// Why Jev could not give a usable answer. The descriptions never contain the API key.
public enum JevError: Error, Sendable, Equatable, CustomStringConvertible {
    case timedOut(seconds: Double)
    case network(String)
    case http(status: Int, body: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .timedOut(let seconds): return "no answer within \(String(format: "%.2f", seconds))s"
        case .network(let kind): return "network error: \(kind)"
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .badResponse(let why): return "bad response: \(why)"
        }
    }
}

/// One question for Jev. A `choice` question has named options in `criteria`;
/// a `noul` question is a yes/no question answered with the probability of yes.
public struct JevQuestion: Sendable, Equatable {
    public enum Kind: String, Sendable { case choice, noul }

    public let kind: Kind
    public let instructions: String
    /// For a choice question: an object whose keys are the option names.
    public let criteria: JSONValue?

    public init(kind: Kind, instructions: String, criteria: JSONValue? = nil) {
        self.kind = kind
        self.instructions = instructions
        self.criteria = criteria
    }

    /// The option names of a choice question.
    public var options: Set<String> { Set(criteria?.objectValue?.keys.map { $0 } ?? []) }

    /// Exactly what is sent to Jev.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue), "instructions": .string(instructions)]
        if let criteria { object["criteria"] = criteria }
        return .object(object)
    }
}

/// One answer from Jev, already checked against the question it answers.
public enum JevAnswer: Sendable, Equatable {
    case choice(label: String, probabilities: [String: Double], confidence: Double?)
    case noul(probabilityOfYes: Double)

    /// The probability Jev gave an option (0 when it gave none).
    public func probability(of option: String) -> Double {
        switch self {
        case .choice(_, let probabilities, _): return probabilities[option] ?? 0
        case .noul(let yes): return option == "yes" ? yes : 1 - yes
        }
    }
}

/// Sends one HTTP request. Injected so tests never touch the network.
public protocol JevTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// The real transport: one long-lived URLSession, so the TLS connection is opened
/// once and reused. A cold call costs a handshake (measured: up to ~200 ms more).
public struct URLSessionJevTransport: JevTransport {
    public let session: URLSession

    public init(timeoutSeconds: Double) {
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, no cache on disk
        configuration.timeoutIntervalForRequest = max(timeoutSeconds * 2, 2)
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Asks Jev questions about a state through OpenRouter's System One endpoint.
///
/// Every call has a hard total deadline (`timeoutSeconds`). Every failure is a
/// `JevError`, so callers handle one error type. The key is only ever placed in
/// the Authorization header: it is never logged and never in an error.
public final class JevClient: Sendable {
    public let model: String
    public let url: URL
    public let timeoutSeconds: Double
    private let authorizationHeader: String
    private let transport: JevTransport
    private static let logger = Logger(subsystem: "com.handsfree", category: "HFDecisions")

    public init(apiKey: String, model: String, url: URL, timeoutSeconds: Double, transport: JevTransport? = nil) {
        self.model = model
        self.url = url
        self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
        self.authorizationHeader = "Bearer \(apiKey)"
        self.transport = transport ?? URLSessionJevTransport(timeoutSeconds: timeoutSeconds)
    }

    /// The allowed deadline range. The upper bound stays below the task runner's own
    /// 1.5 s classification timeout, so the keyword fallback always gets its chance.
    public static let timeoutRange: ClosedRange<Double> = 0.1...1.2
    public static let defaultTimeoutSeconds = 0.8

    /// A sane deadline from whatever the settings said: NaN, infinite or not
    /// positive means the default; anything else is clamped into `timeoutRange`.
    public static func clampedTimeout(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return defaultTimeoutSeconds }
        return min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    /// A client from the app's settings, or nil when no OpenRouter key is set.
    public convenience init?(settings: Settings, transport: JevTransport? = nil) {
        guard settings.isJevEnabled else { return nil }
        self.init(
            apiKey: settings.openRouterAPIKey, model: settings.jevModel, url: settings.jevURL,
            timeoutSeconds: settings.jevTimeoutSeconds, transport: transport)
    }

    /// Asks every question about `state` in one request. Throws `JevError`.
    public func ask(state: JSONValue, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        try await ask(state: state, questions: questions, deadlineSeconds: timeoutSeconds)
    }

    /// Opens the connection now, so the first real "stop" is not the slow one.
    /// Returns how long it took in milliseconds, or nil if it failed. Never throws.
    @discardableResult
    public func warmUp() async -> Double? {
        let started = ContinuousClock.now
        do {
            _ = try await ask(
                state: ["said": "hello"],
                questions: ["warm": JevQuestion(kind: .noul, instructions: "Is `said` a greeting?")],
                deadlineSeconds: max(timeoutSeconds, 5))  // a cold start may be slow; allow it here only
            return started.duration(to: .now).milliseconds
        } catch {
            Self.logger.info("Jev warm-up failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Internals

    private func ask(state: JSONValue, questions: [String: JevQuestion], deadlineSeconds: Double)
        async throws -> [String: JevAnswer]
    {
        try await withThrowingTaskGroup(of: [String: JevAnswer].self) { group in
            group.addTask { try await self.post(state: state, questions: questions) }
            group.addTask {
                // Never trap on a strange value: the deadline is already clamped, and this caps it again.
                let safeSeconds = deadlineSeconds.isFinite ? min(max(deadlineSeconds, 0), 10) : Self.defaultTimeoutSeconds
                try await Task.sleep(nanoseconds: UInt64(safeSeconds * 1_000_000_000))
                throw JevError.timedOut(seconds: deadlineSeconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JevError.timedOut(seconds: deadlineSeconds) }
            return first
        }
    }

    private func post(state: JSONValue, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        let body: JSONValue = [
            "model": .string(model),
            "state": state,
            "questions": .object(questions.mapValues(\.json)),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as JevError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw JevError.network("URLError \(error.code.rawValue)")
        } catch {
            throw JevError.network(String(describing: type(of: error)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JevError.http(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw JevError.badResponse("not JSON")
        }
        return try Self.checkAnswers(decoded, questions: questions)
    }

    /// Makes sure every question got a well-formed answer, or throws.
    ///
    /// A broken answer must never pass for a real one: for the safety gate, a
    /// missing probability read as 0 or 1 could turn into an approval.
    static func checkAnswers(_ response: JSONValue, questions: [String: JevQuestion]) throws -> [String: JevAnswer] {
        guard let answers = response["answers"]?.objectValue else { throw JevError.badResponse("no answers") }
        var checked: [String: JevAnswer] = [:]
        for (questionID, question) in questions {
            guard let answer = answers[questionID]?.objectValue else {
                throw JevError.badResponse("no answer for \(questionID)")
            }
            switch question.kind {
            case .noul:
                guard let yes = answer["noul"]?.doubleValue, isProbability(yes) else {
                    throw JevError.badResponse("bad noul for \(questionID)")
                }
                checked[questionID] = .noul(probabilityOfYes: yes)
            case .choice:
                let options = question.options
                guard let label = answer["choice"]?.stringValue, options.contains(label),
                    let rawProbabilities = answer["probabilities"]?.objectValue
                else { throw JevError.badResponse("bad choice for \(questionID)") }
                var probabilities: [String: Double] = [:]
                for (option, value) in rawProbabilities {
                    guard options.contains(option), let probability = value.doubleValue, isProbability(probability)
                    else { throw JevError.badResponse("bad probabilities for \(questionID)") }
                    probabilities[option] = probability
                }
                var confidence: Double?
                if let rawConfidence = answer["confidence"] {
                    guard let value = rawConfidence.doubleValue, isProbability(value) else {
                        throw JevError.badResponse("bad confidence for \(questionID)")
                    }
                    confidence = value
                }
                checked[questionID] = .choice(label: label, probabilities: probabilities, confidence: confidence)
            }
        }
        return checked
    }

    private static func isProbability(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1 }
}

extension Duration {
    /// This duration in milliseconds, for latency reporting.
    public var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
