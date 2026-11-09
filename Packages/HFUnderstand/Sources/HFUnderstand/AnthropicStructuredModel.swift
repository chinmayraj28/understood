import Foundation
import HFCore
import os

/// A `StructuredLanguageModel` over Anthropic's Messages API (`POST /v1/messages`), written
/// directly against the HTTP API with URLSession because there is no official Swift SDK.
///
/// JSON comes back through structured outputs (`output_config.format` with a JSON Schema), so
/// the reply always matches the schema. Forced tool use was the older way to get JSON, but the
/// API rejects a forced `tool_choice` on Claude Sonnet 5.5 (a 400), as HFScreenAgent found.
///
/// Built for one short, latency-sensitive call per turn: thinking off where the model allows
/// it, low effort, no retries (the repairer has a 3-second budget and falls back to the
/// decider without a reading). The key goes in a header and is never logged.
public final class AnthropicStructuredModel: StructuredLanguageModel, @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The API version this request shape is documented with.
    public static let apiVersion = "2026-10-21"
    /// The model the repairer uses unless told otherwise. Chosen by measuring both on the same
    /// garbled turns (8 Nov 2026, this Mac, the real repair request): Haiku 5.5 took 1.34 to
    /// 1.66 s (7 calls), Sonnet 5.5 took 2.16 to 4.14 s (7 calls). Both read the test cases
    /// correctly; Sonnet said "high" more often, Haiku said "medium" more often, which only means
    /// one more yes/no question. Haiku fits inside the 3-second repair budget with room to spare;
    /// Sonnet's slower calls would not. Sonnet can be passed in for comparison in the evaluation.
    public static let defaultModel = "claude-haiku-5-5"

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let logger = Logger(subsystem: "com.handsfree", category: "understand")
    /// Called with a short description of each failure (HTTP status and the API's message, or
    /// the network error), for a developer's terminal. Never contains the key or the input.
    public var onFailure: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - apiKey: from `Settings.load().anthropicAPIKey`.
    ///   - model: `claude-haiku-5-5` (default) or `claude-sonnet-5-5`.
    ///   - session: a session with a short timeout; tests pass one with a fake protocol.
    public init(apiKey: String, model: String = AnthropicStructuredModel.defaultModel, session: URLSession = AnthropicStructuredModel.makeSession()) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// A session that gives up after `timeoutSeconds`, with no cache or cookies.
    public static func makeSession(timeoutSeconds: TimeInterval = 8) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// Returns a JSON object matching `schema`. Throws `SpeakableError` on any failure, and
    /// `CancellationError` when the calling task is cancelled.
    public func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw SpeakableError("I can't think without a Claude key. Please add it in settings.") }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Self.body(model: model, instructions: instructions, input: input, schema: schema))
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            logger.error("Messages API unreachable: \(String(describing: error), privacy: .public)")
            onFailure?("unreachable: \(error)")
            throw SpeakableError("I can't reach Claude. Please check the internet connection.")
        }
        guard let http = response as? HTTPURLResponse else { throw SpeakableError("Claude sent back something I couldn't read.") }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["message"]?.stringValue ?? ""
            logger.error("Messages API \(http.statusCode, privacy: .public): \(message, privacy: .public)")
            onFailure?("HTTP \(http.statusCode): \(message)")
            throw SpeakableError(http.statusCode == 401 || http.statusCode == 403
                ? "Claude rejected my key. Please check the Anthropic key in settings."
                : "Claude is having trouble right now.")
        }
        return try Self.object(fromResponse: data)
    }

    /// The request body. Public to the module so tests can check it line by line against the docs.
    static func body(model: String, instructions: String, input: String, schema: JSONValue) -> JSONValue {
        var body: JSONValue = [
            "model": .string(model),
            "max_tokens": 1024,
            "system": .string(instructions),
            "messages": [["role": "user", "content": .string(input)]],
            "output_config": ["format": ["type": "json_schema", "schema": schema], "effort": "low"],
        ]
        if let thinking = thinkingOff(for: model), case .object(var fields) = body {
            fields["thinking"] = thinking
            body = .object(fields)
        }
        return body
    }

    /// How to switch thinking off, which differs by model: Haiku 5.5 accepts "disabled" at low
    /// effort; Sonnet 5.5 rejects "disabled" and uses "between_tools" instead. Other models are
    /// left on their default (adaptive) and kept quick by the low effort.
    static func thinkingOff(for model: String) -> JSONValue? {
        if model.hasPrefix("claude-haiku-5") { return ["type": "disabled"] }
        if model.hasPrefix("claude-sonnet-5-5") { return ["type": "between_tools"] }
        return nil
    }

    /// The JSON object inside the first text block of a Messages API response.
    static func object(fromResponse data: Data) throws -> JSONValue {
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw SpeakableError("Claude sent back something I couldn't read.")
        }
        if response["stop_reason"]?.stringValue == "refusal" { throw SpeakableError("Claude declined to answer that.") }
        let text = (response["content"]?.arrayValue ?? [])
            .first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue ?? ""
        guard let json = text.data(using: .utf8),
            let object = try? JSONDecoder().decode(JSONValue.self, from: json), object.objectValue != nil
        else { throw SpeakableError("Claude's answer was not in the expected form.") }
        return object
    }
}
