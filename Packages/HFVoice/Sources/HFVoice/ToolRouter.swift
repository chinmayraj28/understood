import Foundation
import HFCore

/// Routes the agent's tool calls to the right ToolSpec handler.
///
/// Parameters arrive as JSON bytes and become a `JSONObject`. The handler's
/// `JSONObject` goes back as JSON **text**: the server closes the conversation
/// (code 1008) if a tool result is a JSON object instead of a string.
public struct ToolRouter: Sendable {
    private let toolsByName: [String: ToolSpec]

    public init(tools: [ToolSpec]) {
        var byName: [String: ToolSpec] = [:]
        for tool in tools { byName[tool.name] = tool }  // a later duplicate wins
        toolsByName = byName
    }

    public var toolNames: [String] { toolsByName.keys.sorted() }

    /// The result to send back: JSON text, and whether it counts as an error.
    public struct Reply: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    /// Runs the named tool. Never throws: an unknown tool or bad parameters become an
    /// `ok: false` result the agent can read aloud.
    public func handle(toolName: String, parametersJSON: Data) async -> Reply {
        guard let tool = toolsByName[toolName] else {
            return Self.reply(ToolResult.failure("That action isn't available right now."))
        }
        var parameters = Self.decodeParameters(parametersJSON)
        // The Python SDK merged the call id into the parameters; never pass it to a handler.
        parameters["tool_call_id"] = nil
        let result = await tool.handler(parameters)
        return Self.reply(result)
    }

    /// Parameters as a JSON object. Anything that is not an object becomes `[:]`.
    static func decodeParameters(_ data: Data) -> JSONObject {
        guard !data.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return value.objectValue ?? [:]
    }

    static func reply(_ result: JSONObject) -> Reply {
        let isError = result["ok"]?.boolValue == false
        return Reply(text: encode(result), isError: isError)
    }

    /// A JSON object as compact text with stable key order.
    static func encode(_ object: JSONObject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(object)) else {
            return #"{"ok":false,"error":"Something went wrong with that action."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
