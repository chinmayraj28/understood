import Foundation
import HFCore
import HFVoice

/// The agent the evaluation talks to. Never the user's agent, and never the tests' agent.
///
/// It is found the way the tests find theirs (HFVoice's `TestAgent`): the id stored in `.env`
/// under `ELEVENLABS_EVAL_AGENT_ID`, else an agent with this exact name, else a new one. Every
/// run rewrites it with the candidate prompt, model and the app's real tool definitions.
enum EvalAgent {
    /// Agreed with the HFVoice engineer: found or created by `TestAgent.resolve` under this name and key.
    static let name = "Handsfree EVAL agent (tests only, safe to delete)"
    static let envKey = "ELEVENLABS_EVAL_AGENT_ID"

    /// When the agent should stay silent for a turn. Written for the agent's LLM.
    static let skipTurnDescription = """
        Say nothing this turn: call this as your whole reply, with no text before or after it, because \
        any text is spoken aloud. Use it when the sentence was not meant for you \
        (someone talking to another person or another assistant), when it was a stray word or sound with \
        no request in it, and after start_task answers that the task is running.
        """

    /// What a run changes on top of the app's own agent definition.
    struct Variant: Sendable {
        var model: String
        var reasoningEffort: String?
        var prompt: String
        /// Turn on ElevenLabs' built-in `skip_turn`, which lets the agent stay silent for a turn.
        var skipTurn: Bool
        /// "off" (the app's setting), "auto" or "force", for every tool.
        var preToolSpeech: String
        var maxTokens: Int?
    }

    /// Makes the evaluation agent match `variant` with these tools, and returns its id.
    /// Stops, with an error, if anything about the user's agent changed.
    static func prepare(_ variant: Variant, tools: [ToolSpec], settings: Settings) async throws -> String {
        let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
        let before = try await productionFingerprint(api: api, settings: settings)

        var configuration = AgentConfiguration(prompt: variant.prompt)
        configuration.name = name
        configuration.llm = variant.model
        configuration.reasoningEffort = variant.reasoningEffort
        var definition = configuration.definition(tools: tools)
        definition = adjust(definition, for: variant)

        // Find or create the agent (HFVoice's TestAgent, with our own name and key), then update it by id.
        let evalID = try await TestAgent.resolve(
            settings: settings, configuration: configuration, agentName: name, idKey: envKey)
        try refuseIfShared(evalID, settings: settings)
        let sync = try await api.createOrUpdateAgent(definition: definition, knownAgentID: evalID)
        try refuseIfShared(sync.agentID, settings: settings)

        let after = try await productionFingerprint(api: api, settings: settings)
        guard before == after else {
            throw SpeakableError("Stopping: the user's agent changed while the evaluation agent was updated. Before: \(before). After: \(after).")
        }
        // Read back what the server kept, so a setting it silently dropped is noticed.
        let saved = try await api.agent(id: sync.agentID)
        let prompt = saved["conversation_config"]?["agent"]?["prompt"]
        let savedModel = prompt?["llm"]?.stringValue ?? "?"
        guard savedModel == variant.model else {
            throw SpeakableError("The evaluation agent kept model \(savedModel), not \(variant.model).")
        }
        return sync.agentID
    }

    /// The definition with the variant's extra settings.
    static func adjust(_ definition: JSONValue, for variant: Variant) -> JSONValue {
        guard case .object(var root) = definition,
            case .object(var conversation)? = root["conversation_config"],
            case .object(var agent)? = conversation["agent"],
            case .object(var prompt)? = agent["prompt"]
        else { return definition }
        root["tags"] = ["handsfree", "eval"]
        if let maxTokens = variant.maxTokens { prompt["max_tokens"] = .number(Double(maxTokens)) }
        if variant.skipTurn {
            prompt["built_in_tools"] = [
                "skip_turn": [
                    "type": "system", "name": "skip_turn", "description": "",
                    "params": ["system_tool_type": "skip_turn"],
                ]
            ]
        } else {
            prompt["built_in_tools"] = ["skip_turn": .null]
        }
        if case .array(let tools)? = prompt["tools"] {
            var adjusted = tools.map { tool -> JSONValue in
                guard case .object(var fields) = tool else { return tool }
                fields["pre_tool_speech"] = .string(variant.preToolSpeech)
                return .object(fields)
            }
            // With the (deprecated) inline tool list, the server rebuilds built_in_tools from this
            // list, so a system tool must be listed here too or it is dropped.
            if variant.skipTurn {
                adjusted.append([
                    "type": "system", "name": "skip_turn", "description": .string(EvalAgent.skipTurnDescription),
                    "params": ["system_tool_type": "skip_turn"], "pre_tool_speech": "off",
                ])
            }
            prompt["tools"] = .array(adjusted)
        }
        agent["prompt"] = .object(prompt)
        conversation["agent"] = .object(agent)
        root["conversation_config"] = .object(conversation)
        return .object(root)
    }

    /// The user's agent's model, prompt length and tools, to prove an evaluation run left them alone.
    static func productionFingerprint(api: ElevenLabsAPI, settings: Settings) async throws -> String {
        guard !settings.elevenLabsAgentID.isEmpty else { return "no production agent" }
        let agent = try await api.agent(id: settings.elevenLabsAgentID)
        let prompt = agent["conversation_config"]?["agent"]?["prompt"]
        let ids = (prompt?["tool_ids"]?.arrayValue ?? []).compactMap(\.stringValue).sorted()
        let tools = (prompt?["tools"]?.arrayValue ?? []).map { tool in
            "\(tool["name"]?.stringValue ?? "?"):\((tool["description"]?.stringValue ?? "").hashValue)"
        }.sorted()
        let model = prompt?["llm"]?.stringValue ?? "?"
        let promptLength = prompt?["prompt"]?.stringValue?.count ?? 0
        return "model=\(model) prompt=\(promptLength) ids=\(ids.joined(separator: ",")) tools=\(tools.joined(separator: ","))"
    }

    static func refuseIfShared(_ agentID: String, settings: Settings) throws {
        try ProductionAgentGuard.refuseIfProduction(agentID, settings: settings)
        let testID = ProcessInfo.processInfo.environment[TestAgent.envKey]
            ?? EnvFile.find().flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { Settings.parseEnvFile($0)[TestAgent.envKey] ?? "" }
            ?? ""
        if !testID.isEmpty, agentID == testID {
            throw SpeakableError("The evaluation agent must not be the tests' agent (\(TestAgent.envKey)).")
        }
    }

    static func storedID() -> String? {
        if let value = ProcessInfo.processInfo.environment[envKey], !value.isEmpty { return value }
        guard let file = EnvFile.find(), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let value = Settings.parseEnvFile(text)[envKey] ?? ""
        return value.isEmpty ? nil : value
    }
}
