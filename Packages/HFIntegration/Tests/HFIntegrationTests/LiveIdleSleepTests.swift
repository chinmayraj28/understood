import Foundation
import HFCore
import HFVoice
import HFWake
import Testing

/// Proof, with a real conversation, that idle sleep happens: HFWake's real cycle, a real
/// VoiceSession in text mode on the TEST agent, and the app's rule for "is anything going on"
/// (CycleWiring.snapshot). Text mode has no microphone, so room noise cannot be tested here;
/// what this proves is that the agent's own signals (its reply, its state, tool calls, pushed
/// news) end, and do not hold the conversation open. Run with `HF_LIVE=1 swift test --filter LiveIdleSleepTests`.
private let isLiveIdle = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

@Suite(.serialized) struct LiveIdleSleepTests {
    @Test(.enabled(if: isLiveIdle, "Set HF_LIVE=1 to talk to the test agent"))
    @MainActor
    func aRealConversationGoesToSleepAfterTheIdleTime() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAPIKey.isEmpty)
        let testAgent = try await TestAgent.resolve(settings: settings)
        let idle = 6.0
        let bus = ActivityBus()
        let started = Date()
        let timeline = Log<String>()
        let replies = Log<String>()
        let watcher = Task {
            for await event in bus.events() {
                let at = String(format: "%5.2f", Date().timeIntervalSince(started))
                switch event {
                case .asleep: timeline.append("\(at) asleep")
                case .waking: timeline.append("\(at) waking")
                case .listening: timeline.append("\(at) listening")
                case .userSaid: timeline.append("\(at) user said (first utterance)")
                case .agentSpeaking: timeline.append("\(at) agent replied")
                case .voiceDisconnected(let reason): timeline.append("\(at) disconnected: \(reason)")
                default: break
                }
            }
        }

        let session = VoiceSession(settings: settings, agentID: testAgent, mode: .text, bus: bus)
        session.announcesFailedOpens = false
        session.addReplyListener { replies.append($0) }
        session.prepare(tools: try RealTools.all(), memorySummary: "Nothing yet.")

        // The app's "is anything going on", read on the main actor 5 times a second (ActivityMirror).
        let mirror = TestActivityMirror()
        let refreshing = Task { @MainActor in
            while !Task.isCancelled {
                let now = session.activity
                mirror.store(HFWake.ConversationActivity(
                    someoneSpeaking: now.isUserSpeaking || now.isAgentSpeaking || now.hasUnspokenNews,
                    taskRunning: false, awaitingAnswer: false))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let listener = TestWakeListener()
        let cycle = ListeningCycle(
            mode: .phrase, wakePhrase: "Hey Handsfree", sleepAfterIdleSeconds: idle, listener: listener,
            openConversation: { firstUtterance in
                await session.open(firstUtterance: firstUtterance)
                if let refusal = await session.openRefusal { throw SpeakableError(refusal) }
                guard await session.waitUntilConnected(timeout: 5) else { throw SpeakableError("no connection") }
            },
            closeConversation: { await session.close() },
            currentActivity: { mirror.current },
            bus: bus)
        await cycle.start()
        _ = await waitFor(10) { listener.isListening }

        listener.hear("What is two plus two? Answer in one short sentence.")
        let replied = await waitFor(20) { !replies.items.isEmpty }
        try #require(replied != nil, "the agent did not answer")
        let repliedAt = Date()
        let slept = await waitFor(idle + 15) { listener.startCount >= 2 && !session.isOpen }
        let sleptAfter = Date().timeIntervalSince(repliedAt)
        print("IDLE: replies \(replies.items)")
        print("IDLE: timeline\n" + timeline.items.joined(separator: "\n"))
        print("IDLE: went back to sleep \(String(format: "%.1f", sleptAfter)) s after the agent's reply (idle setting \(idle) s)")
        #expect(slept != nil, "it never went back to sleep")
        #expect(sleptAfter >= idle - 0.5 && sleptAfter <= idle + 3, "slept \(sleptAfter) s after the last reply, idle is \(idle) s")
        #expect(!session.hasConversationResources)

        await cycle.stop()
        refreshing.cancel()
        watcher.cancel()
    }
}

/// Polls until `condition` holds or `timeout` passes. Returns how long it took, or nil.
@MainActor
private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}
