import AVFoundation
import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Real conversations with the real agent. Run with `HF_LIVE=1 swift test`.
/// They use the TEST agent (`TestAgent`, ELEVENLABS_TEST_AGENT_ID), never the app's own.
private let isLive = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

/// A thread-safe list, for things that arrive from the session's callbacks.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []
    func add(_ element: Element) { lock.lock(); stored.append(element); lock.unlock() }
    var all: [Element] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Polls until `condition` holds or `timeout` passes. Returns how long it took, or nil.
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return nil
}

@Suite(.serialized) struct LiveVoiceTests {
    @Test(.enabled(if: isLive, "Set HF_LIVE=1 to talk to the real ElevenLabs agent"))
    @MainActor
    func typedMessageCallsToolAndPushedEventIsSpoken() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAPIKey.isEmpty && !settings.elevenLabsAgentID.isEmpty,
                     "ELEVENLABS_API_KEY and ELEVENLABS_AGENT_ID must be in .env (run hf-voice setup)")
        let calls = Recorder<JSONObject>()
        let replies = Recorder<String>()
        let heard = Recorder<String>()
        let session = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .text)
        session.addReplyListener { replies.add($0) }
        await session.start(tools: DemoTools.make { _, parameters in calls.add(parameters) },
                            memorySummary: "Nothing yet.", onUserSentence: { heard.add($0) })
        let connected = await session.waitUntilConnected(timeout: 25)
        try #require(connected, "could not connect to the agent")

        // 1. A typed message makes the agent call the demo tool, and the string result reaches it.
        try await session.sendText("Set the volume to 30 percent.")
        let toolLatency = await waitFor(15) { !calls.all.isEmpty }
        let replyLatency = await waitFor(15) { !replies.all.isEmpty }
        #expect(toolLatency != nil, "the demo tool was not called")
        #expect(calls.all.first?["percent"]?.intValue == 30)
        #expect(replyLatency != nil, "the agent did not reply after the tool")
        #expect(heard.all == ["Set the volume to 30 percent."], "typed text reaches the transcript listeners")
        let afterTool = replies.all.joined(separator: " ").lowercased()
        #expect(afterTool.contains("30") || afterTool.contains("thirty"), "reply: \(afterTool)")

        // 2. A pushed task question makes the agent speak with no user message.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let repliesBefore = replies.all.count
        session.push(TaskEvent(taskID: "t1", kind: .question, status: .needsInput,
                               text: "Two contacts match. Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"]))
        let pushLatency = await waitFor(20) { replies.all.count > repliesBefore }
        #expect(pushLatency != nil, "the agent did not speak the pushed question")
        let relayed = replies.all.dropFirst(repliesBefore).joined(separator: " ")
        #expect(relayed.contains("Shah") && relayed.contains("Patel"), "relayed: \(relayed)")
        #expect(session.queuedEventCount == 0)
        #expect(session.spokenNews.sentAgain == 0, "the question was recognised as said: \(session.spokenNews)")

        print("LIVE: tool call after \(toolLatency ?? -1) s, first reply after \(replyLatency ?? -1) s, pushed question spoken after \(pushLatency ?? -1) s")
        print("LIVE: replies = \(replies.all)")
        await session.stop()
    }

    @Test(.enabled(if: isLive, "Set HF_LIVE=1 to talk to the real ElevenLabs agent"))
    @MainActor
    func aConfirmationRightAfterAProgressLineIsSpokenPromptly() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAgentID.isEmpty)
        let replies = Recorder<String>()
        let session = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .text)
        session.addReplyListener { replies.add($0) }
        await session.start(tools: DemoTools.make(), memorySummary: "Nothing yet.")
        try #require(await session.waitUntilConnected(timeout: 25))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        session.push(TaskEvent(taskID: "t1", kind: .progress, status: .running, text: "Opening WhatsApp."))
        let progressReply = await waitFor(6) { !replies.all.isEmpty }
        print("LIVE: reply to a progress line: \(replies.all) after \(progressReply ?? -1) s (nil means the agent stayed silent)")
        let before = replies.all.count
        let pushedAt = Date()
        session.push(TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Send 'running late' to Amma?"))
        let spoken = await waitFor(15) { replies.all.count > before }
        print("LIVE: confirmation spoken after \(spoken ?? -1) s: \(Array(replies.all.dropFirst(before)))")
        #expect(spoken != nil && Date().timeIntervalSince(pushedAt) < 5, "the confirmation was held")
        #expect(replies.all.dropFirst(before).joined().contains("Amma"))
        // The app recognised the real agent's words as saying the confirmation: nothing was sent twice.
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("LIVE: spoken news counts: \(session.spokenNews)")
        #expect(session.spokenNews.sentAgain == 0 && session.spokenNews.unsaidNow == 0)
        await session.stop()
    }
}

/// Plays the agent through the real speakers with the real microphone open, to check
/// it does not hear itself. Makes about 25 s of sound. Run with `HF_LIVE_AUDIO=1 swift test`.
private let isLiveAudio = ProcessInfo.processInfo.environment["HF_LIVE_AUDIO"] == "1"

@Suite(.serialized) struct LiveAudioTests {
    @Test(.enabled(if: isLiveAudio, "Set HF_LIVE_AUDIO=1 to play the agent through the speakers"))
    @MainActor
    func theAgentDoesNotHearItselfThroughTheSpeakers() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAgentID.isEmpty)
        let bus = ActivityBus()
        let transcripts = Recorder<String>()
        let replies = Recorder<String>()
        let stream = bus.events()
        let watcher = Task { for await event in stream { if case .userSaid(let text) = event { transcripts.add(text) } } }
        let session = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .voice, bus: bus)
        session.addReplyListener { replies.add($0) }
        await session.start(tools: DemoTools.make(), memorySummary: "Nothing yet.")
        let connected = await session.waitUntilConnected(timeout: 30)
        try #require(connected, "could not start a voice session")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print("AUDIO: echo cancellation:\n\(VoiceDiagnostics.echoCancellationReport())")
        // Prove the microphone is live: another app says a command out loud.
        let calls = Recorder<JSONObject>()
        await session.stop()
        let probe = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .voice, bus: bus, syncAgentOnStart: false)
        await probe.start(tools: DemoTools.make { _, parameters in calls.add(parameters) }, memorySummary: "Nothing yet.")
        try #require(await probe.waitUntilConnected(timeout: 30))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["Set the volume to thirty percent."]
        try say.run()
        say.waitUntilExit()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        print("AUDIO: mic probe: peak voice activity=\(probe.peakVoiceActivity) heard=\(transcripts.all) tool calls=\(calls.all)")
        await probe.stop()
        let micLive = probe.peakVoiceActivity > 0.5 || !transcripts.all.isEmpty
        print("AUDIO: microphone live: \(micLive)")
        let echoBaseline = transcripts.all.count
        let session2 = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .voice, bus: bus, syncAgentOnStart: false)
        session2.addReplyListener { replies.add($0) }
        await session2.start(tools: DemoTools.make(), memorySummary: "Nothing yet.")
        try #require(await session2.waitUntilConnected(timeout: 30))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let repliesBefore = replies.all.count
        try await session2.sendText("Please describe, slowly, a quiet beach at sunrise, in four sentences.")
        try? await Task.sleep(nanoseconds: 25_000_000_000)
        let echoed = Array(transcripts.all.dropFirst(echoBaseline))
        print("AUDIO: interruptions=\(session2.interruptionCount) peak voice activity=\(session2.peakVoiceActivity) heard=\(echoed) replies=\(replies.all.dropFirst(repliesBefore))")
        await session2.stop()
        watcher.cancel()
        #expect(micLive, "the microphone looks silent, so the echo result proves nothing")
        #expect(session2.interruptionCount <= 1, "the agent interrupted itself")
        #expect(echoed.isEmpty, "the agent's own words came back as user speech: \(echoed)")
        #expect(replies.all.count - repliesBefore == 1, "one reply, not a spiral")
    }
}

/// Measures how soon `isUserSpeaking` turns true after speech starts, with real speech
/// (made by macOS `say`) mixed into the microphone at a known moment, and checks that the
/// agent's own voice through the speakers does not trip it. Run with `HF_LIVE_AUDIO=1`.
///
/// Order: a quiet baseline, then the agent talking through the speakers, then the
/// injected speech with the room microphone muted.
@Suite(.serialized) struct LiveSpeechSignalTests {
    struct Sample: Sendable { let time: TimeInterval; let level: Double }

    static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        return String(format: "min %.3f median %.3f p90 %.3f max %.3f (n=%d)", sorted.first!, sorted[sorted.count / 2],
                      sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last!, sorted.count)
    }

    @Test(.enabled(if: isLiveAudio, "Set HF_LIVE_AUDIO=1 to measure the speaking signal"))
    @MainActor
    func measureTheEarlySpeakingSignal() async throws {
        let settings = Settings.load()
        try #require(!settings.elevenLabsAgentID.isEmpty)
        let now = { ProcessInfo.processInfo.systemUptime }
        let vad = Recorder<Sample>()
        let transcripts = Recorder<Sample>()
        let heardText = Recorder<String>()
        let replies = Recorder<String>()
        let session = VoiceSession(settings: settings, agentID: try await TestAgent.resolve(settings: settings), mode: .voice, bus: ActivityBus())
        session.voiceActivityObserver = { level in vad.add(Sample(time: now(), level: level)) }
        session.addReplyListener { replies.add($0) }
        await session.start(tools: DemoTools.make(), memorySummary: "Nothing yet.",
                            onUserSentence: { text in transcripts.add(Sample(time: now(), level: 1)); heardText.add(text) })
        try #require(await session.waitUntilConnected(timeout: 30))
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        func watch(seconds: TimeInterval) async -> (trueChecks: Int, checks: Int) {
            let begin = now()
            var trueChecks = 0, checks = 0
            while now() - begin < seconds {
                checks += 1
                if session.isUserSpeaking { trueChecks += 1 }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return (trueChecks, checks)
        }

        // 1. Baseline: nobody is meant to be talking, real microphone open.
        let baselineStart = now()
        let baseline = await watch(seconds: 8)
        print("SIGNAL: baseline 8 s: isUserSpeaking true in \(baseline.trueChecks) of \(baseline.checks); VAD \(Self.summary(vad.all.filter { $0.time > baselineStart }.map(\.level))); heard \(heardText.all)")

        // 2. The agent talks through the speakers, real microphone open.
        let echoStart = now()
        let heardBefore = heardText.all.count
        try await session.sendText("Please describe, slowly, a quiet beach at sunrise, in four sentences.")
        let echo = await watch(seconds: 22)
        print("SIGNAL: agent speaking 22 s: isUserSpeaking true in \(echo.trueChecks) of \(echo.checks); VAD \(Self.summary(vad.all.filter { $0.time > echoStart }.map(\.level))); interruptions \(session.interruptionCount); heard \(Array(heardText.all.dropFirst(heardBefore))); replies \(replies.all.count)")

        // 3. Known speech mixed into the microphone, room muted.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-voice-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phrases = ["Stop.", "Wait, don't send it.", "Set the volume to thirty percent.", "Hold on, I want to change the message.",
                       "Cancel that.", "Stop what you are doing."]
        VoiceDiagnostics.setRoomMicrophoneVolume(0)
        var signalDelays: [Double] = [], vadDelays: [Double] = [], transcriptDelays: [Double] = [], speechLevels: [Double] = []
        for (index, phrase) in phrases.enumerated() {
            let url = folder.appendingPathComponent("clip\(index).wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", url.path, "--data-format=LEI16@16000", phrase]
            try say.run(); say.waitUntilExit()
            // Start from a clear state: the agent has finished and nothing counts as speech.
            let waitBegin = now()
            while (session.isUserSpeaking || !session.isQuietNow), now() - waitBegin < 15 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let before = transcripts.all.count
            let playedAt = now()
            let span = try VoiceDiagnostics.playIntoMicrophone(url)
            let speechStart = playedAt + span.start, speechEnd = playedAt + span.end
            var signalAt: TimeInterval?
            while now() - playedAt < 8 {
                if signalAt == nil, session.isUserSpeaking { signalAt = now() }
                if signalAt != nil, transcripts.all.count > before { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let firstHigh = vad.all.first { $0.time >= playedAt && $0.level >= 0.5 }?.time
            let heardAt = transcripts.all.dropFirst(before).first?.time
            if let signalAt { signalDelays.append(signalAt - speechStart) }
            if let firstHigh { vadDelays.append(firstHigh - speechStart) }
            if let heardAt { transcriptDelays.append(heardAt - speechEnd) }
            speechLevels += vad.all.filter { $0.time > speechStart + 0.35 && $0.time < speechEnd + 0.2 }.map(\.level)
            func ms(_ value: TimeInterval?) -> String { value.map { String(format: "%+.0f ms", $0 * 1000) } ?? "none" }
            print("SIGNAL: '\(phrase)' (\(String(format: "%.2f", span.end - span.start)) s): first VAD>=0.5 \(ms(firstHigh.map { $0 - speechStart })); isUserSpeaking \(ms(signalAt.map { $0 - speechStart })); transcript \(ms(heardAt.map { $0 - speechEnd })) after speech ends; heard '\(heardText.all.last ?? "")'")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        VoiceDiagnostics.setRoomMicrophoneVolume(1)
        print("SIGNAL: speech start -> first VAD>=0.5: \(Self.summary(vadDelays))")
        print("SIGNAL: speech start -> isUserSpeaking true: \(Self.summary(signalDelays))")
        print("SIGNAL: speech end -> transcript delivered: \(Self.summary(transcriptDelays))")
        print("SIGNAL: VAD while speech is arriving: \(Self.summary(speechLevels))")
        await session.stop()
        #expect(signalDelays.count == phrases.count, "the signal turned true for every utterance")
        // The agent's own words must never come back as user speech.
        let agentWords = Set(replies.all.joined(separator: " ").lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        let echoed = heardText.all.dropFirst(heardBefore + 1).filter { sentence in
            let words = sentence.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 }
            return !words.isEmpty && Double(words.filter(agentWords.contains).count) / Double(words.count) > 0.6
        }
        #expect(echoed.isEmpty, "the agent's own words came back as user speech: \(echoed)")
        // Whether the agent's voice trips the signal can only be judged in a quiet room.
        if baseline.trueChecks == 0 {
            #expect(echo.trueChecks == 0, "the agent's own voice tripped isUserSpeaking")
        } else {
            print("SIGNAL: the room was not quiet during the baseline, so the speaker check is not judged this run")
        }
    }
}
