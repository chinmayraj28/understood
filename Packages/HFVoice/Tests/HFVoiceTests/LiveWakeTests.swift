import Foundation
import HFCore
import Testing

@testable import HFVoice

/// The wake and sleep path against the real agent, in text mode (no microphone, no sound).
/// Run with `HF_LIVE=1 swift test --filter openCloseAndOpenAgain`. Uses the TEST agent, never the app's own;
/// the app restores the real tools when it next starts.
private let isLive = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

// In the same serialized suite as the other live tests: the check for conversations left open counts
// every conversation in the process, so no other live test may run at the same time.
extension LiveVoiceTests {
    static func seconds(_ value: TimeInterval?) -> String { value.map { String(format: "%.2f s", $0) } ?? "none" }

    @Test(.enabled(if: isLive, "Set HF_LIVE=1 to talk to the real ElevenLabs agent"))
    @MainActor
    func openCloseAndOpenAgainWithTheFirstUtterance() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAPIKey.isEmpty && !settings.elevenLabsAgentID.isEmpty,
                     "ELEVENLABS_API_KEY and ELEVENLABS_AGENT_ID must be in .env (run hf-voice setup)")
        let calls = Recorder<Date>()
        let replies = Recorder<String>()
        let heard = Recorder<String>()
        let session = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .text, bus: ActivityBus())
        session.addReplyListener { replies.add($0) }

        // Launch: the agent's definition is updated once, and a credential is fetched ahead.
        let tools = DemoTools.make { _, _ in calls.add(Date()) }
        let launchedAt = Date()
        session.prepare(tools: tools, memorySummary: "Nothing yet.", onUserSentence: { heard.add($0) })

        // Wake 1 comes at once, so it waits for the update still on its way (the worst case).
        var rounds: [(label: String, connected: TimeInterval, toolCall: TimeInterval?, waitedForSync: TimeInterval)] = []
        func wake(_ label: String, firstUtterance: String) async throws {
            let callsBefore = calls.all.count
            let repliesBefore = replies.all.count
            let openedAt = Date()
            await session.open(firstUtterance: firstUtterance)
            try #require(session.isConnected, "\(label): could not connect")
            let timing = try #require(session.lastOpenTiming)
            var toolLatency: TimeInterval?
            if !firstUtterance.isEmpty {
                _ = await waitFor(15) { calls.all.count > callsBefore }
                toolLatency = calls.all.dropFirst(callsBefore).first.map { $0.timeIntervalSince(openedAt) }
                #expect(toolLatency != nil, "\(label): the first utterance did not reach the agent")
                _ = await waitFor(10) { replies.all.count > repliesBefore }
                #expect(replies.all.count > repliesBefore, "\(label): the agent did not reply")
            }
            rounds.append((label, timing.total, toolLatency, timing.waitedForAgentSync))
            print("LIVE WAKE: \(label): ready \(Self.seconds(timing.total)) after open (waited for agent update \(Self.seconds(timing.waitedForAgentSync)), connecting \(Self.seconds(timing.connecting))); tool call \(Self.seconds(toolLatency)) after open; replies \(Array(replies.all.dropFirst(repliesBefore)))")
            await session.close()
            #expect(!session.isConnected && !session.isOpen)
            #expect(!session.hasConversationResources, "\(label): something was left running")
            let leftover = VoiceDiagnostics.leftoverConversations
            #expect(leftover.active == 0, "\(label): an SDK conversation is still connected after close")
        }

        try await wake("wake 1 (right after launch)", firstUtterance: "Set the volume to 30 percent.")
        print("LIVE WAKE: launch to first wake ready: \(Self.seconds(Date().timeIntervalSince(launchedAt)))")
        // As the app would be: asleep for a moment between wakes, while the next credential is fetched.
        for index in 2...4 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try await wake("wake \(index)", firstUtterance: "Set the volume to \(index * 10) percent.")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        try await wake("wake 5 (phrase only)", firstUtterance: "")

        #expect(session.agentSyncCount == 1, "the agent's definition was updated once, not on every wake")
        #expect(session.openCount == 5)
        #expect(heard.all.count == 4, "each first utterance reached the transcript listeners once: \(heard.all)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let leftover = VoiceDiagnostics.leftoverConversations
        print("LIVE WAKE: SDK conversations left in memory after 5 wakes: \(leftover.inMemory), still connected: \(leftover.active)")
        #expect(leftover.active == 0)
        let warm = rounds.dropFirst().map(\.connected).sorted()
        if !warm.isEmpty {
            print("LIVE WAKE: later wakes, open to ready: min \(Self.seconds(warm.first)) median \(Self.seconds(warm[warm.count / 2])) max \(Self.seconds(warm.last))")
        }
        let toolTimes = rounds.compactMap(\.toolCall).sorted()
        if !toolTimes.isEmpty {
            print("LIVE WAKE: open to the first utterance's tool call: min \(Self.seconds(toolTimes.first)) median \(Self.seconds(toolTimes[toolTimes.count / 2])) max \(Self.seconds(toolTimes.last))")
        }
    }
}
