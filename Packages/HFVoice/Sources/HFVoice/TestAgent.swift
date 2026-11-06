import Foundation
import HFCore

/// The agent that tests and the `hf-voice text` / `hf-voice talk` tools use. Never the user's.
///
/// Until 6 Nov the live tests and `hf-voice` wrote their demo tool onto the one agent in `.env`,
/// the agent the app uses. The app's own update at launch then failed to put the real tools back,
/// and the user spoke to an agent whose only tool was `demo_set_volume`. So:
/// - tests get their own agent, created on demand, named so it is obviously for tests, with its
///   id kept under `ELEVENLABS_TEST_AGENT_ID`, never `ELEVENLABS_AGENT_ID`;
/// - `ProductionAgentGuard` refuses, in code, any definition with demo tools for the production
///   agent, and refuses a "test" agent id that is the production one.
public enum TestAgent {
    public static let name = "Handsfree TEST agent (tests only, safe to delete)"
    public static let envKey = "ELEVENLABS_TEST_AGENT_ID"

    /// The test agent's id: the stored one if it still exists, else one found by name, else a new
    /// agent. The id is written to `.env` under `envKey`. Never returns the production agent's id.
    /// - Parameters:
    ///   - agentName, idKey: another test agent of its own, for example a prompt evaluation that must not
    ///     share an agent with these tests. The name must still say it is for tests.
    public static func resolve(
        settings: Settings, configuration: AgentConfiguration = AgentConfiguration(),
        agentName: String = TestAgent.name, idKey: String = TestAgent.envKey
    ) async throws -> String {
        guard idKey != "ELEVENLABS_AGENT_ID" else { throw SpeakableError("A test agent id must not be stored as ELEVENLABS_AGENT_ID.") }
        guard !settings.elevenLabsAPIKey.isEmpty else { throw SpeakableError("ELEVENLABS_API_KEY is not set.") }
        let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
        var definition = configuration.definition(tools: [])
        if case .object(var fields) = definition {
            fields["name"] = .string(agentName)
            fields["tags"] = ["handsfree", "test"]
            definition = .object(fields)
        }
        let stored = storedID(idKey)
        let sync = try await api.createOrUpdateAgent(definition: definition, knownAgentID: stored ?? "")
        try ProductionAgentGuard.refuseIfProduction(sync.agentID, settings: settings)
        if sync.agentID != stored, let file = EnvFile.find() {
            try EnvFile.set(idKey, to: sync.agentID, in: file)
        }
        return sync.agentID
    }

    /// The id in the environment or the repo's `.env`, if any. Not a secret.
    public static func storedID(_ envKey: String = TestAgent.envKey) -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment[envKey], !fromEnvironment.isEmpty { return fromEnvironment }
        guard let file = EnvFile.find(), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let value = Settings.parseEnvFile(text)[envKey] ?? ""
        return value.isEmpty ? nil : value
    }
}

/// Makes writing test material onto the user's agent impossible by accident.
public enum ProductionAgentGuard {
    /// Tool names that only tests and `hf-voice` use.
    public static func isTestTool(_ name: String) -> Bool { name.hasPrefix("demo_") }

    /// Throws if `agentID` is the production agent (ELEVENLABS_AGENT_ID).
    public static func refuseIfProduction(_ agentID: String, settings: Settings) throws {
        if !settings.elevenLabsAgentID.isEmpty, agentID == settings.elevenLabsAgentID {
            throw SpeakableError("The test agent must not be the app's own agent (ELEVENLABS_AGENT_ID).")
        }
    }

    /// Throws if a tool list meant for the production agent contains a test tool.
    public static func checkProductionTools(_ tools: [ToolSpec]) throws {
        let demo = tools.map(\.name).filter(isTestTool)
        if !demo.isEmpty {
            throw SpeakableError("Refusing to put test tools (\(demo.joined(separator: ", "))) on the app's own agent.")
        }
    }
}
