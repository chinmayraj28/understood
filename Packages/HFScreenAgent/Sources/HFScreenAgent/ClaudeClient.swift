import Foundation
import HFCore
import os

/// Sends one HTTP request. The real one is `URLSessionTransport`; tests pass a fake,
/// so no test needs the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport: one long-lived URLSession, so connections are reused
/// between the steps of a task (a new TLS handshake per step would add latency).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = 90) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `data(for:)` cancels the HTTP request when the calling Swift task is cancelled.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A client for Anthropic's Messages API (`POST /v1/messages`), written directly
/// against the HTTP API because there is no official Swift SDK.
///
/// Requests and responses are `JSONValue`, the same shape as the JSON on the
/// wire, so what this code sends can be checked line by line against Anthropic's
/// documentation. The API key goes in a header and is never logged.
public final class ClaudeClient: StructuredLanguageModel, @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The API version the computer-use toolset is documented with.
    public static let apiVersion = "2026-10-21"

    private let apiKey: String
    private let transport: HTTPTransport
    private let endpoint: URL
    /// The model `extract` uses (learning jobs are small, so the small model).
    private let structuredModel: String
    private let maxRetries: Int
    private let retryBaseDelay: TimeInterval
    private let logger = Logger(subsystem: "com.handsfree", category: "HFScreenAgent.ClaudeClient")
    /// Called with the HTTP status and the API's own error message when a request fails,
    /// for a developer's terminal. The message never contains the key.
    public var onAPIError: (@Sendable (Int, String) -> Void)?

    public init(
        apiKey: String,
        structuredModel: String = "claude-haiku-5-5",
        transport: HTTPTransport = URLSessionTransport(),
        endpoint: URL = ClaudeClient.defaultBaseURL,
        maxRetries: Int = 2,
        retryBaseDelay: TimeInterval = 0.5
    ) {
        self.apiKey = apiKey
        self.structuredModel = structuredModel
        self.transport = transport
        self.endpoint = endpoint
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
    }

    public convenience init(settings: Settings, transport: HTTPTransport = URLSessionTransport()) {
        self.init(apiKey: settings.anthropicAPIKey, structuredModel: settings.smallModel, transport: transport)
    }

    // MARK: - Messages

    /// Sends one Messages API request body and returns the response object.
    ///
    /// Retries overload and server errors (429, 500, 502, 503, 504, 529) and
    /// dropped connections a couple of times with a growing pause. Throws
    /// `CancellationError` when the Swift task is cancelled, and `SpeakableError`
    /// for everything else, so a failure can be read aloud as it is.
    public func createMessage(_ body: JSONValue) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw SpeakableError("I can't think without a Claude key. Please add it in settings.") }
        let payload = try JSONEncoder().encode(body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt < maxRetries {
                    attempt += 1
                    try await pause(seconds: retryBaseDelay * pow(2, Double(attempt - 1)))
                    continue
                }
                logger.error("Messages API unreachable: \(String(describing: error), privacy: .public)")
                throw SpeakableError("I can't reach Claude. Please check the internet connection.")
            }

            if response.statusCode == 200 {
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw SpeakableError("Claude sent back something I couldn't read.")
                }
                return decoded
            }

            let retryable: Set<Int> = [429, 500, 502, 503, 504, 529]
            if retryable.contains(response.statusCode), attempt < maxRetries {
                attempt += 1
                let suggested = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await pause(seconds: min(suggested ?? retryBaseDelay * pow(2, Double(attempt - 1)), 5))
                continue
            }
            throw mapFailure(status: response.statusCode, data: data)
        }
    }

    // MARK: - StructuredLanguageModel

    /// Returns a JSON object matching `schema`, using the API's structured outputs
    /// (`output_config.format`). Forced tool use would be the older way, but
    /// Claude Sonnet 5.5 and Opus 5.5 reject a forced `tool_choice` with a 400.
    public func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue {
        let body: JSONValue = [
            "model": .string(structuredModel),
            "max_tokens": 2048,
            "system": .string(instructions),
            "messages": [["role": "user", "content": .string(input)]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        let response = try await createMessage(body)
        if response["stop_reason"]?.stringValue == "refusal" {
            throw SpeakableError("Claude declined to answer that.")
        }
        let text = (response["content"]?.arrayValue ?? [])
            .first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue ?? ""
        guard let data = text.data(using: .utf8),
            let object = try? JSONDecoder().decode(JSONValue.self, from: data), object.objectValue != nil
        else { throw SpeakableError("Claude's answer was not in the expected form.") }
        return object
    }

    // MARK: - Helpers

    private func pause(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Turns an HTTP error into a sentence for the user. The API's own message
    /// goes to the log (it never contains the key), not to the user.
    private func mapFailure(status: Int, data: Data) -> SpeakableError {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        let apiMessage = decoded?["error"]?["message"]?.stringValue ?? ""
        logger.error("Messages API \(status, privacy: .public): \(apiMessage, privacy: .public)")
        onAPIError?(status, apiMessage)
        switch status {
        case 401, 403: return SpeakableError("Claude rejected my key. Please check the Anthropic key in settings.")
        case 429: return SpeakableError("Claude is busy right now. Please try again in a moment.")
        case 529, 500, 502, 503, 504: return SpeakableError("Claude is having trouble right now. Please try again shortly.")
        case 400, 404, 413, 422: return SpeakableError("Claude couldn't accept my request, so I stopped.")
        default: return SpeakableError("Something went wrong talking to Claude, so I stopped.")
        }
    }
}
