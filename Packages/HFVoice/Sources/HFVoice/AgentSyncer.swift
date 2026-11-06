import Foundation
import HFCore
import os

/// Whether the agent on ElevenLabs has exactly the tools the app registers.
public struct AgentCheck: Sendable, Equatable {
    public var inSync: Bool
    /// Tool names on the agent, sorted, as read back.
    public var toolNamesOnAgent: [String]
    /// Tools the app has that the agent lacks, and tools the agent has that the app lacks.
    public var missing: [String]
    public var unexpected: [String]
    public var checkedAt: Date
    /// One plain sentence when it is not in sync, fine to show and say.
    public var problem: String?
    /// For the log and tests only: the HTTP status and the start of ElevenLabs' answer. Never a key.
    public var detail: String?
    /// As read back: the agent's model, reasoning setting and built-in tools.
    public var model: String? = nil
    public var reasoningEffort: String? = nil
    public var systemTools: [String] = []

    public var toolCount: Int { toolNamesOnAgent.count }

    public var summary: String {
        if inSync { return "in sync: \(toolCount) tools + \(systemTools.joined(separator: ", ")), model \(model ?? "?"), reasoning \(reasoningEffort ?? "?")" }
        var parts = [problem ?? "not in sync"]
        if !missing.isEmpty { parts.append("missing \(missing.joined(separator: ", "))") }
        if !unexpected.isEmpty { parts.append("unexpected \(unexpected.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    static func failed(_ problem: String, detail: String?, at date: Date) -> AgentCheck {
        AgentCheck(inSync: false, toolNamesOnAgent: [], missing: [], unexpected: [], checkedAt: date, problem: problem, detail: detail)
    }
}

/// Brings the agent on ElevenLabs in line with the app's tools, and checks that it is.
///
/// `push` sends the whole definition (prompt, settings, tools) and then reads the agent back;
/// success is decided by the read-back, not by the update's status code. `verify` only reads it
/// back (measured at well under a second), so it can run often.
public struct AgentSyncer: Sendable {
    public enum Role: Sendable, Equatable {
        /// The user's agent: test tools are refused in code.
        case production
        /// A test agent: refused if it is the production agent.
        case test(productionAgentID: String)
    }

    let api: ElevenLabsAPI
    let configuration: AgentConfiguration
    public let agentID: String
    let role: Role
    private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    public init(apiKey: String, agentID: String, role: Role, configuration: AgentConfiguration = AgentConfiguration(), http: HTTPSending = URLSessionHTTP()) {
        self.api = ElevenLabsAPI(apiKey: apiKey, http: http)
        self.configuration = configuration
        self.agentID = agentID
        self.role = role
    }

    /// Sends the definition with these tools, then reads the agent back.
    public func push(tools: [ToolSpec]) async -> AgentCheck {
        if let refusal = guardFailure(tools) { return refusal }
        do {
            _ = try await api.call("PATCH", "/v1/convai/agents/\(agentID)", body: Self.withoutIdentity(configuration.definition(tools: tools)))
        } catch {
            let detail = Self.describe(error)
            Self.logger.error("Agent update rejected: \(detail, privacy: .public)")
            return .failed("ElevenLabs did not accept the agent's tools, so I can't start a conversation yet.", detail: detail, at: Date())
        }
        return await verify(tools: tools)
    }

    /// The definition without the agent's name and tags. An update never renames an agent: on
    /// 6 Nov an update of the test agent gave it the app agent's name, and `hf-voice setup` finds
    /// the app's agent by that name.
    public static func withoutIdentity(_ definition: JSONValue) -> JSONValue {
        guard case .object(var fields) = definition else { return definition }
        fields["name"] = nil
        fields["tags"] = nil
        return .object(fields)
    }

    /// Reads the agent back and compares its tool names with `tools`.
    /// Reads the agent back. In step means all three: exactly the app's client tools, the built-in
    /// skip_turn tool, and the model and reasoning setting the app sent.
    public func verify(tools: [ToolSpec]) async -> AgentCheck {
        let expected = Set(tools.map(\.name))
        do {
            let agent = try await readBack()
            let names = Set(agent.clientTools)
            let missing = expected.subtracting(names).sorted()
            let unexpected = names.subtracting(expected).sorted()
            var problems: [String] = []
            if !missing.isEmpty || !unexpected.isEmpty { problems.append("tools") }
            let hasSkipTurn = agent.systemTools.contains(AgentConfiguration.skipTurnName)
            if !hasSkipTurn { problems.append("skip_turn") }
            if agent.model != configuration.llm { problems.append("model") }
            if agent.reasoningEffort != configuration.reasoningEffort { problems.append("reasoning") }
            let inSync = problems.isEmpty
            return AgentCheck(
                inSync: inSync, toolNamesOnAgent: names.sorted(),
                missing: missing + (hasSkipTurn ? [] : [AgentConfiguration.skipTurnName]), unexpected: unexpected,
                checkedAt: Date(),
                problem: inSync ? nil : "The voice agent's set-up doesn't match the app, so I can't start a conversation yet.",
                detail: inSync ? nil : "differs in: \(problems.joined(separator: ", ")); model \(agent.model ?? "none"), reasoning \(agent.reasoningEffort ?? "none")",
                model: agent.model, reasoningEffort: agent.reasoningEffort, systemTools: agent.systemTools)
        } catch {
            return .failed("I can't check the voice agent right now.", detail: Self.describe(error), at: Date())
        }
    }

    /// What the agent has on ElevenLabs, as far as being in step goes.
    struct ReadBack {
        var clientTools: [String]
        /// Built-in (system) tools: inline ones of type "system", and the keys of `built_in_tools` that are set.
        var systemTools: [String]
        var model: String?
        var reasoningEffort: String?
    }

    func readBack() async throws -> ReadBack {
        let agent = try await api.agent(id: agentID)
        let prompt = agent["conversation_config"]?["agent"]?["prompt"]
        let inline = prompt?["tools"]?.arrayValue ?? []
        var clientTools = inline.filter { $0["type"]?.stringValue != "system" }.compactMap { $0["name"]?.stringValue }
        var systemTools = inline.filter { $0["type"]?.stringValue == "system" }.compactMap { $0["name"]?.stringValue }
        for (name, value) in prompt?["built_in_tools"]?.objectValue ?? [:] where value != .null {
            if !systemTools.contains(name) { systemTools.append(name) }
        }
        if inline.isEmpty {
            // Older agents list tools only by id.
            for id in (prompt?["tool_ids"]?.arrayValue ?? []).compactMap(\.stringValue) {
                let tool = try await api.call("GET", "/v1/convai/tools/\(id)")
                if let name = tool["tool_config"]?["name"]?.stringValue ?? tool["name"]?.stringValue { clientTools.append(name) }
            }
        }
        return ReadBack(clientTools: clientTools, systemTools: systemTools.sorted(),
                        model: prompt?["llm"]?.stringValue, reasoningEffort: prompt?["reasoning_effort"]?.stringValue)
    }

    /// The names of the agent's client tools (for `hf-voice check` and older callers).
    func toolNames() async throws -> [String] { try await readBack().clientTools }

    private func guardFailure(_ tools: [ToolSpec]) -> AgentCheck? {
        switch role {
        case .production:
            do { try ProductionAgentGuard.checkProductionTools(tools) } catch {
                return .failed((error as? SpeakableError)?.spokenMessage ?? "Refused.", detail: nil, at: Date())
            }
        case .test(let productionAgentID):
            if !productionAgentID.isEmpty, agentID == productionAgentID {
                return .failed("The test agent must not be the app's own agent.", detail: nil, at: Date())
            }
        }
        return nil
    }

    public static func describe(_ error: Error) -> String {
        if let apiError = error as? ElevenLabsAPIError { return "HTTP \(apiError.status): \(apiError.message)" }
        return String(describing: error)
    }
}

/// What the voice session uses to keep the agent in step: update it, and read it back.
/// Built from an `AgentSyncer` in the app; tests pass their own closures.
public struct AgentKeeper: Sendable {
    public var push: @Sendable ([ToolSpec]) async -> AgentCheck
    public var verify: @Sendable ([ToolSpec]) async -> AgentCheck

    public init(push: @escaping @Sendable ([ToolSpec]) async -> AgentCheck, verify: @escaping @Sendable ([ToolSpec]) async -> AgentCheck) {
        self.push = push
        self.verify = verify
    }

    public init(syncer: AgentSyncer) {
        self.init(push: { await syncer.push(tools: $0) }, verify: { await syncer.verify(tools: $0) })
    }

    /// From the older form, "did the update work": a read-back is assumed to agree.
    init(simple sync: @escaping @Sendable ([ToolSpec]) async -> Bool) {
        self.init(
            push: { tools in
                await sync(tools)
                    ? AgentCheck.matching(tools)
                    : .failed("The voice agent couldn't be updated, so I can't start a conversation yet.", detail: nil, at: Date())
            },
            verify: { tools in AgentCheck.matching(tools) })
    }
}

extension AgentCheck {
    /// An agent that has exactly these tools.
    public static func matching(_ tools: [ToolSpec], at date: Date = Date()) -> AgentCheck {
        AgentCheck(inSync: true, toolNamesOnAgent: tools.map(\.name).sorted(), missing: [], unexpected: [], checkedAt: date, problem: nil, detail: nil)
    }
}
