import Foundation
import HFCore

/// The whole ElevenLabs agent, defined in code so it can be reviewed and reproduced.
///
/// Every value here was chosen by experiment; the evidence is in
/// docs/spikes/elevenlabs.md. `definition(tools:)` is the JSON body for
/// `POST /v1/convai/agents/create` and `PATCH /v1/convai/agents/{id}`.
public struct AgentConfiguration: Sendable {
    /// The agent's name on ElevenLabs. Setup finds an existing agent by this name.
    public var name = "Hands-Free Laptop Agent"
    /// The system prompt. The master copy is docs/prompts/voice_agent.md; the
    /// package carries a copy as a resource, and a test fails if they differ.
    public var prompt: String
    /// Chosen on 6 Nov by the wake engineer's 37-case evaluation on the EVAL agent: with the new
    /// prompt, claude-sonnet-5-5 at low reasoning passed 36 of 37 (the old haiku setup 23 of 37),
    /// at 0.87 s median to the tool call. With reasoning "none" both models sometimes said their
    /// reasoning aloud; "low" stopped that for about 0.1 s.
    public var llm = "claude-sonnet-5-5"
    public var reasoningEffort: String? = "low"
    /// Used in order if the main model fails or is slow; both follow the same prompt the same way.
    public var backupLLMs = ["claude-haiku-5-5", "claude-haiku-4-5"]
    /// "Alice": a clear, calm voice. The user may pick another by ear.
    public var voiceID = "Xb7hH8MSUJpSbSDYk0k2"
    /// Puts the current time in the prompt, which "tomorrow at three" needs.
    public var timezone = TimeZone.current.identifier
    /// Empty: the agent does not greet on every reconnect. The companion shows it is listening.
    public var firstMessage = ""

    public init(prompt: String = AgentConfiguration.bundledPrompt()) {
        self.prompt = prompt
    }

    /// The prompt shipped inside the package.
    public static func bundledPrompt() -> String {
        guard let url = Bundle.module.url(forResource: "voice_agent", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// Placeholders for the prompt's dynamic variables, used when a session does not send them.
    public static let dynamicVariableDefaults: [String: String] = [
        "user_memory": "Nothing yet.",
        "session_context": "This is the start of the session. No task is running.",
    ]

    /// Server events the session listens to. The server sends only those listed.
    public static let clientEvents = [
        "conversation_initiation_metadata", "ping", "audio", "interruption", "user_transcript",
        "agent_response", "agent_response_correction", "client_tool_call", "agent_tool_request",
        "agent_tool_response", "vad_score", "agent_response_complete", "client_error",
    ]

    /// The agent definition. With `tools == nil` the tool list is left out, so an
    /// update keeps whatever tools the agent already has.
    public func definition(tools: [ToolSpec]?) -> JSONValue {
        var promptSettings: JSONObject = [
            "prompt": .string(prompt),
            "llm": .string(llm),
            "temperature": 0,
            "max_tokens": 300,
            "timezone": .string(timezone),
            "backup_llm_config": ["preference": "override", "order": .array(backupLLMs.map { .string($0) })],
            "cascade_timeout_seconds": 4,
        ]
        promptSettings["reasoning_effort"] = reasoningEffort.map { .string($0) } ?? .null
        if let tools {
            // skip_turn goes in the same list: with tools sent inline, the server rebuilds the built-in
            // tools from this list, and a separate `built_in_tools.skip_turn` is silently dropped.
            promptSettings["tools"] = .array(tools.map(Self.clientTool) + [Self.skipTurnTool])
        }
        let placeholders = JSONValue.object(Self.dynamicVariableDefaults.mapValues { .string($0) })
        return [
            "name": .string(name),
            "tags": ["handsfree"],
            "conversation_config": [
                "agent": [
                    "first_message": .string(firstMessage),
                    "language": "en",
                    "dynamic_variables": ["dynamic_variable_placeholders": placeholders],
                    "prompt": .object(promptSettings),
                ],
                // Patient turn-taking for slow or paused speech. turn_timeout -1 means the
                // agent never asks "are you still there?"; silence is normal here.
                "turn": [
                    "turn_eagerness": "patient",
                    "turn_timeout": -1,
                    "silence_end_call_timeout": -1,
                    "spelling_patience": "auto",
                    "speculative_turn": true,
                ],
                // Expressive mode adds tags like [happy] to the agent's speech; off for plain speech.
                "tts": ["voice_id": .string(voiceID), "expressive_mode": false],
                // The server's maximum; the default of 600 s would end every session after 10 minutes.
                "conversation": [
                    "max_duration_seconds": 7200,
                    "client_events": .array(Self.clientEvents.map { .string($0) }),
                ],
            ],
            // A session may switch to text only (automated tests) and set the first message.
            // Nothing else, in particular the prompt and the model, can be changed by a client.
            "platform_settings": [
                "overrides": [
                    "conversation_config_override": [
                        "conversation": ["text_only": true],
                        "agent": ["first_message": true],
                    ]
                ]
            ],
        ]
    }

    /// ElevenLabs' built-in tool for saying nothing this turn. The agent uses it for speech not
    /// meant for it, stray sounds, after start_task answers "running", and for progress notes; it
    /// removed the double "On it." in the evaluation. The server stores it as built_in_tools.skip_turn.
    public static let skipTurnName = "skip_turn"
    public static let skipTurnTool: JSONValue = [
        "type": "system", "name": .string(skipTurnName), "pre_tool_speech": "off",
        "params": ["system_tool_type": .string(skipTurnName)],
        "description": "Say nothing this turn: call this as your whole reply, with no text before or after it, because any text is spoken aloud. Use it when the sentence was not meant for you (someone talking to another person or another assistant), when it was a stray word or sound with no request in it, after start_task answers that the task is running, and for a progress note that needs no words.",
    ]

    /// One ToolSpec as an ElevenLabs client tool.
    ///
    /// The agent waits for every result, speaks no filler before a tool, and can
    /// always be interrupted. The server accepts timeouts of 1 to 120 seconds.
    public static func clientTool(_ spec: ToolSpec) -> JSONValue {
        [
            "type": "client",
            "name": .string(spec.name),
            "description": .string(spec.description),
            "parameters": describingEveryParameter(spec.parameters),
            "expects_response": true,
            "response_timeout_secs": .number(Double(min(max(spec.timeoutSeconds, 1), 120))),
            "pre_tool_speech": "off",
            "interruption_mode": "allow",
            "execution_mode": "immediate",
        ]
    }

    // MARK: Parameters ElevenLabs accepts

    /// ElevenLabs rejects a whole agent update (HTTP 400, "Must set one of: description,
    /// dynamic_variable, is_system_provided, constant_value, or is_omitted") if any tool parameter,
    /// at any depth, has no `description`. On 6 Nov that is why the app's real tools never reached
    /// the agent: `media_control`'s `action` had none. So every parameter without one gets a plain
    /// description from its name (and its allowed values), in properties and in array items.
    static func describingEveryParameter(_ schema: JSONValue) -> JSONValue {
        guard case .object(var fields) = schema else { return schema }
        if let properties = fields["properties"]?.objectValue {
            var described: [String: JSONValue] = [:]
            for (name, property) in properties {
                described[name] = describing(property, named: name)
            }
            fields["properties"] = .object(described)
        }
        if let items = fields["items"] {
            fields["items"] = describing(items, named: "item")
        }
        return .object(fields)
    }

    private static func describing(_ property: JSONValue, named name: String) -> JSONValue {
        guard case .object(var fields) = describingEveryParameter(property) else { return property }
        let existing = fields["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existing.isEmpty {
            let words = name.replacingOccurrences(of: "_", with: " ")
            let choices = (fields["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
            fields["description"] = .string(choices.isEmpty ? "The \(words)." : "The \(words): one of \(choices.joined(separator: ", ")).")
        }
        return .object(fields)
    }

    /// Where a definition lacks a parameter description, as "tool.parameter" paths. For tests and
    /// for telling each tool's owner what to write.
    public static func parametersWithoutDescriptions(_ spec: ToolSpec) -> [String] {
        var found: [String] = []
        func walk(_ schema: JSONValue, path: String) {
            guard let fields = schema.objectValue else { return }
            for (name, property) in fields["properties"]?.objectValue ?? [:] {
                let here = "\(path).\(name)"
                if (property["description"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty { found.append(here) }
                walk(property, path: here)
            }
            if let items = fields["items"] {
                if (items["description"]?.stringValue ?? "").isEmpty, items["properties"] == nil, items.objectValue != nil {
                    // A plain item type ("type": "string") needs one too.
                    found.append("\(path)[]")
                }
                walk(items, path: "\(path)[]")
            }
        }
        walk(spec.parameters, path: spec.name)
        return found.sorted()
    }
}
