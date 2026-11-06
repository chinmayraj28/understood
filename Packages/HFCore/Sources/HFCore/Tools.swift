import Foundation

/// One voice tool: something the ElevenLabs agent can ask the Mac to do.
///
/// This is the single source of truth for both sides. The app registers
/// `handler` under `name` with the voice session, and the same `description`
/// and `parameters` are sent to ElevenLabs as the agent's tool definition, so
/// the two can never drift apart.
public struct ToolSpec: Sendable {
    /// Which part of the product the tool belongs to.
    public enum Tier: Int, Sendable {
        case meta = 0  // memory and status
        case quick = 1  // one action, done the way a person does it
        case task = 3  // hands a multi-step goal to the screen agent
    }

    /// Takes the parameters the agent sent and returns a JSON object.
    ///
    /// A handler never throws. On failure it returns
    /// `["ok": false, "error": "<one short sentence that can be read aloud>"]`.
    /// On success it returns `["ok": true, ...]`.
    public typealias Handler = @Sendable (JSONObject) async -> JSONObject

    public let name: String
    /// Written for the agent's LLM: when to use this tool and when not to.
    public let description: String
    /// A JSON Schema object: `["type": "object", "properties": [...], "required": [...]]`.
    public let parameters: JSONValue
    public let tier: Tier
    /// How long the voice agent waits for the handler before giving up.
    public let timeoutSeconds: Int
    public let handler: Handler

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        tier: Tier,
        timeoutSeconds: Int = 20,
        handler: @escaping Handler
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.tier = tier
        self.timeoutSeconds = timeoutSeconds
        self.handler = handler
    }
}

public enum ToolResult {
    /// `["ok": true]` plus any extra fields.
    public static func ok(_ extra: JSONObject = [:]) -> JSONObject {
        extra.merging(["ok": true]) { _, new in new }
    }

    /// `["ok": false, "error": message]`. The message must be fine to read aloud.
    public static func failure(_ spokenMessage: String, _ extra: JSONObject = [:]) -> JSONObject {
        extra.merging(["ok": false, "error": .string(spokenMessage)]) { _, new in new }
    }
}

/// An error whose message is a short, plain sentence that is safe to say to the
/// user. Anything that can reach the voice agent should fail with one of these,
/// never with a stack trace or a system error code.
public struct SpeakableError: Error, Equatable, Sendable, CustomStringConvertible {
    public let spokenMessage: String
    public init(_ spokenMessage: String) { self.spokenMessage = spokenMessage }
    public var description: String { spokenMessage }
}
