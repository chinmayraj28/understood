import Foundation
import HFCore
import os

/// Whether the agent on ElevenLabs has exactly the tools the app registers.
///
/// Three states:
/// - **In step** (`inSync`): the app's client tools and skip_turn are all there. A different model
///   or reasoning setting read back is only a `warning` (ElevenLabs may alias or retire a model).
/// - **Out of step** (`inSync == false`, `couldNotCheck == false`): a confirmed mismatch, or an
///   update ElevenLabs refused. No conversation opens until it is repaired.
/// - **Could not check** (`couldNotCheck`): the read-back or update failed for a reason that says
///   nothing about the agent (network, timeout, 5xx, 429, a body that won't decode). Conversations
///   still open; it is checked again at the next wake.
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
    /// The check itself failed (network, timeout, 5xx, 429, undecodable): nothing is known about the agent.
    public var couldNotCheck: Bool = false
    /// In step, but the model or reasoning read back is not what was sent. Shown and logged, never a refusal.
    public var warning: String? = nil

    public var toolCount: Int { toolNamesOnAgent.count }

    /// A confirmed problem with the agent itself (not a failed check).
    public var isConfirmedMismatch: Bool { !inSync && !couldNotCheck }

    public var summary: String {
        if inSync {
            var line = "in sync: \(toolCount) tools + \(systemTools.joined(separator: ", ")), model \(model ?? "?"), reasoning \(reasoningEffort ?? "?")"
            if let warning { line += " (warning: \(warning))" }
            return line
        }
        if couldNotCheck { return "could not check: \(detail ?? problem ?? "")" }
        var parts = [problem ?? "not in sync"]
        if !missing.isEmpty { parts.append("missing \(missing.joined(separator: ", "))") }
        if !unexpected.isEmpty { parts.append("unexpected \(unexpected.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    /// Said and shown when ElevenLabs can't be reached (network, timeout, 5xx, 429).
    public static let unreachableSentence = "I can't reach the voice service right now. Say Hey Handsfree to try again."
    /// Said and shown when the agent is confirmed wrong and the repair has not fixed it yet.
    public static let notSetUpSentence = "Handsfree's voice isn't set up correctly yet. It is trying again."

    /// A confirmed failure: the agent is wrong, or ElevenLabs refused the update.
    static func failed(_ problem: String = notSetUpSentence, detail: String?, at date: Date) -> AgentCheck {
        AgentCheck(inSync: false, toolNamesOnAgent: [], missing: [], unexpected: [], checkedAt: date, problem: problem, detail: detail)
    }

    /// The check could not be made. Says nothing about the agent.
    public static func couldNotCheck(detail: String?, at date: Date) -> AgentCheck {
        AgentCheck(inSync: false, toolNamesOnAgent: [], missing: [], unexpected: [], checkedAt: date,
                   problem: unreachableSentence, detail: detail, couldNotCheck: true)
    }
}

/// The read-back or update took too long.
struct CheckTimedOut: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "no answer within \(Int(seconds)) s" }
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

    /// A read-back gives up after this long and counts as "could not check".
    public static let readTimeout: TimeInterval = 5
    /// The update itself (it takes about 2.5 s when ElevenLabs is well).
    public static let updateTimeout: TimeInterval = 10

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
            let body = Self.withoutIdentity(configuration.definition(tools: tools))
            _ = try await Self.withDeadline(Self.updateTimeout) { [api, agentID] in
                try await api.call("PATCH", "/v1/convai/agents/\(agentID)", body: body, timeout: Self.updateTimeout)
            }
        } catch {
            let detail = Self.describe(error)
            if Self.isTransient(error) {
                Self.logger.error("Agent update could not be sent: \(detail, privacy: .public)")
                return .couldNotCheck(detail: detail, at: Date())
            }
            Self.logger.error("Agent update rejected: \(detail, privacy: .public)")
            return .failed(detail: detail, at: Date())
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

    /// Reads the agent back. In step: exactly the app's client tools, and skip_turn. A different
    /// model or reasoning setting is a warning only. A failed read is "could not check".
    public func verify(tools: [ToolSpec]) async -> AgentCheck {
        let expected = Set(tools.map(\.name))
        do {
            let agent = try await Self.withDeadline(Self.readTimeout) { try await readBack() }
            let names = Set(agent.clientTools)
            let missing = expected.subtracting(names).sorted()
            let unexpected = names.subtracting(expected).sorted()
            let hasSkipTurn = agent.systemTools.contains(AgentConfiguration.skipTurnName)
            var problems: [String] = []
            if !missing.isEmpty || !unexpected.isEmpty { problems.append("tools") }
            if !hasSkipTurn { problems.append("skip_turn") }
            var differences: [String] = []
            if agent.model != configuration.llm { differences.append("model \(agent.model ?? "none") (sent \(configuration.llm))") }
            if agent.reasoningEffort != configuration.reasoningEffort {
                differences.append("reasoning \(agent.reasoningEffort ?? "none") (sent \(configuration.reasoningEffort ?? "none"))")
            }
            let inSync = problems.isEmpty
            let warning = differences.isEmpty ? nil : "read back " + differences.joined(separator: ", ")
            if let warning { Self.logger.notice("Voice agent in step, but \(warning, privacy: .public)") }
            return AgentCheck(
                inSync: inSync, toolNamesOnAgent: names.sorted(),
                missing: missing + (hasSkipTurn ? [] : [AgentConfiguration.skipTurnName]), unexpected: unexpected,
                checkedAt: Date(),
                problem: inSync ? nil : AgentCheck.notSetUpSentence,
                detail: inSync ? nil : "differs in: \(problems.joined(separator: ", "))",
                model: agent.model, reasoningEffort: agent.reasoningEffort, systemTools: agent.systemTools,
                warning: warning)
        } catch {
            let detail = Self.describe(error)
            if Self.isTransient(error) { return .couldNotCheck(detail: detail, at: Date()) }
            return .failed(detail: detail, at: Date())
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
        let agent = try await api.agent(id: agentID, timeout: Self.readTimeout)
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
                let tool = try await api.call("GET", "/v1/convai/tools/\(id)", timeout: Self.readTimeout)
                if let name = tool["tool_config"]?["name"]?.stringValue ?? tool["name"]?.stringValue { clientTools.append(name) }
            }
        }
        return ReadBack(clientTools: clientTools, systemTools: systemTools.sorted(),
                        model: prompt?["llm"]?.stringValue, reasoningEffort: prompt?["reasoning_effort"]?.stringValue)
    }

    /// The names of the agent's client tools (for `hf-voice check` and older callers).
    func toolNames() async throws -> [String] { try await readBack().clientTools }

    /// True when the error says nothing about the agent: the network, a timeout, ElevenLabs being
    /// down or busy (5xx, 408, 429), or an answer that would not decode.
    static func isTransient(_ error: Error) -> Bool {
        if error is CheckTimedOut || error is URLError || error is DecodingError { return true }
        if let apiError = error as? ElevenLabsAPIError {
            return apiError.status == 408 || apiError.status == 429 || (500..<600).contains(apiError.status)
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Runs `body`, giving up after `seconds` (the request is cancelled).
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CheckTimedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CheckTimedOut(seconds: seconds) }
            return first
        }
    }

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
                await sync(tools) ? AgentCheck.matching(tools) : .failed(detail: nil, at: Date())
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
