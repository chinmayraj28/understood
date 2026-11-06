import Foundation
import HFCore
import HFDecisions
import HFEyes
import HFHands
import HFMemory
import HFTasks
import HFVoice
import Testing

/// The app's real tool definitions, from every package, sent to ElevenLabs and read back.
///
/// On 6 Nov the user's agent had only `demo_set_volume`: the app's update with the real tools had
/// never been accepted, and nothing said so. This sends exactly the tools the app registers (quick,
/// memory, task and sleep) to the TEST agent, never the user's, and checks every name came back,
/// so a definition the API rejects fails here rather than in a conversation.
/// Run with `HF_LIVE=1 swift test --filter AgentSyncLiveTests`.
private let isLiveSync = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

enum RealTools {
    /// The same lists the app builds in PartAssembly, with fakes only where the Mac would be touched.
    static func all() throws -> [ToolSpec] {
        let hands = FakeHands(bus: ActivityBus())
        let quick = QuickTools.make(hands: hands, guard: nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = Memory(store: try MemoryStore(fileURL: folder.appendingPathComponent("memory.db")))
        let memoryTools = MemoryTools.make(memory: memory)
        let rig = Rig { _ in IdleExecutor() }
        let taskTools = Array(rig.tools.values).sorted { $0.name < $1.name }
        let sleepTool = SleepTool.make(isTaskActive: { false }, requestSleep: { .goingToSleep })
        return quick + memoryTools + taskTools + [sleepTool]
    }
}

/// An executor that never runs: only the tool definitions matter here.
struct IdleExecutor: TaskExecuting {
    func run(goal: String, context: TaskContext) async throws -> String { "" }
}

@Suite(.serialized) struct AgentSyncLiveTests {
    @Test(.enabled(if: isLiveSync, "Set HF_LIVE=1 to update the test agent on ElevenLabs"))
    func theRealToolsAreAcceptedAndReadBack() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAPIKey.isEmpty)
        let tools = try RealTools.all()
        try ProductionAgentGuard.checkProductionTools(tools)
        let names = tools.map(\.name).sorted()
        print("SYNC: the app's tools (\(names.count)): \(names.joined(separator: ", "))")
        let undescribed = tools.flatMap(AgentConfiguration.parametersWithoutDescriptions)
        print("SYNC: parameters with no description in their package (filled in by the conversion): \(undescribed.isEmpty ? "none" : undescribed.joined(separator: ", "))")

        let testAgent = try await TestAgent.resolve(settings: settings)
        #expect(testAgent != settings.elevenLabsAgentID, "never the user's agent")
        let syncer = AgentSyncer(apiKey: settings.elevenLabsAPIKey, agentID: testAgent, role: .test(productionAgentID: settings.elevenLabsAgentID))
        let started = Date()
        let check = await syncer.push(tools: tools)
        print("SYNC: push took \(String(format: "%.2f", Date().timeIntervalSince(started))) s: \(check.summary)")
        if let detail = check.detail { print("SYNC: \(detail)") }
        #expect(check.inSync, "\(check.summary) \(check.detail ?? "")")
        #expect(check.toolNamesOnAgent == names)
        #expect(check.systemTools.contains("skip_turn"), "skip_turn is on the agent: \(check.systemTools)")
        #expect(check.model == "claude-sonnet-5-5", "model read back: \(check.model ?? "none")")
        #expect(check.reasoningEffort == "low", "reasoning read back: \(check.reasoningEffort ?? "none")")

        let verifyStarted = Date()
        let again = await syncer.verify(tools: tools)
        print("SYNC: read-back alone took \(String(format: "%.2f", Date().timeIntervalSince(verifyStarted))) s: \(again.summary)")
        #expect(again.inSync)

        // `hf-voice setup` repairs the prompt and settings and leaves the tools out of its update:
        // that must not strip the agent's tools.
        let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
        _ = try await api.createOrUpdateAgent(
            definition: AgentSyncer.withoutIdentity(AgentConfiguration().definition(tools: nil)), knownAgentID: testAgent)
        let afterSetup = await syncer.verify(tools: tools)
        print("SYNC: after a setup-style update without tools: \(afterSetup.summary)")
        #expect(afterSetup.inSync, "an update without the tool list must keep the tools")
        #expect(afterSetup.systemTools.contains("skip_turn"), "and keep skip_turn")
    }
}
