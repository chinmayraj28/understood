import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Stands in for ElevenLabs text-to-speech. Each reply becomes `chunks`; with `endless`, the
/// stream sends one chunk and then waits until it is cancelled, like a long reply mid-stream.
final class FakeSpeech: SpeechStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var chunks: [Data] = [Data(count: 3_200), Data(count: 3_200)]
    var endless = false
    var failure: Error?
    var asked: [String] { lock.withLock { texts } }

    func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { texts.append(text) }
        let chunks = chunks, endless = endless, failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure { continuation.finish(throwing: failure); return }
                for chunk in chunks.prefix(endless ? 1 : chunks.count) { continuation.yield(chunk) }
                if endless {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What the app's sink was given.
final class FakeSink: @unchecked Sendable {
    let played = Recorder<Int>()
    let stops = Recorder<Bool>()
    func setting(_ speech: FakeSpeech) -> OwnListening {
        let played = played, stops = stops
        return OwnListening(speech: speech, play: { played.add($0.count) }, stopPlaying: { stops.add(true) })
    }
}

private let question = TaskEvent(taskID: "t1", kind: .question, status: .needsInput, text: "Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])

@Suite(.serialized) @MainActor struct OwnListeningTests {
    @Test func offByDefaultTheVoicePathIsUnchanged() async {
        let harness = Harness(mode: .voice)
        await harness.start()
        #expect(!harness.session.isOwnListening)
        #expect(harness.driver.request?.textOnly == false)
    }

    @Test func theConversationIsTextOnlySoTheSDKMicrophoneIsNeverOpened() async {
        let speech = FakeSpeech(), sink = FakeSink()
        let harness = Harness(mode: .voice, ownListening: sink.setting(speech))
        await harness.start()
        #expect(harness.session.isOwnListening)
        #expect(harness.driver.request?.textOnly == true)
        await harness.session.close()
        #expect(harness.prefetches.all.allSatisfy { $0 }, "the next connection is prepared text-only too")
    }

    @Test func aHeardTurnGoesWhereASpokenTranscriptGoes() async throws {
        let speech = FakeSpeech(), sink = FakeSink()
        let harness = Harness(ownListening: sink.setting(speech))
        let heard = Recorder<String>()
        harness.session.addTranscriptListener { heard.add($0) }
        await harness.start()
        try await harness.session.sendHeardTurn("Message Mum")
        await harness.settle()
        #expect(harness.driver.userMessages == ["Message Mum"])
        #expect(heard.all == ["Message Mum"])
        #expect(harness.posted.all.contains(.userSaid("Message Mum")))
        #expect(harness.session.isAgentSpeaking, "a reply is on its way")
    }

    @Test func aHeardTurnBeforeConnectingFails() async {
        let harness = Harness(ownListening: FakeSink().setting(FakeSpeech()))
        await #expect(throws: SpeakableError.self) { try await harness.session.sendHeardTurn("hello") }
    }

    @Test func aReplyIsSpokenIntoTheSinkAndTheAgentIsAudibleUntilItHasPlayed() async {
        let speech = FakeSpeech(), sink = FakeSink()
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("Volume's at thirty."))
        await harness.settle()
        #expect(speech.asked == ["Volume's at thirty."])
        #expect(sink.played.all == [3_200, 3_200])
        #expect(harness.posted.all.contains(.agentSpeaking("Volume's at thirty.")))
        #expect(harness.session.isAgentSpeaking)
        #expect(harness.session.lastSpeechStartDelay != nil)
        // 6,400 bytes is 0.2 s of audio, plus the 0.3 s tail.
        harness.clock.advance(0.6)
        await harness.settle()
        #expect(!harness.session.isAgentSpeaking)
        let listening = harness.posted.all.filter { $0 == .listening }.count
        #expect(listening >= 2, "listening is posted again once the voice has finished")
    }

    @Test func aPushWaitsUntilTheSpokenReplyHasFinished() async {
        let speech = FakeSpeech(), sink = FakeSink()
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("Here is the weather."))
        await harness.settle()
        harness.session.push(question)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "a push would talk over the agent")
        harness.clock.advance(1.5)
        await harness.settle()
        #expect(harness.driver.userMessages.first?.hasPrefix("[APP] Task t1 asks:") == true)
    }

    @Test func interruptingStopsTheVoiceAtOnceAndCountsIt() async {
        let speech = FakeSpeech(), sink = FakeSink()
        speech.endless = true
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("A long story about the sea."))
        await harness.settle()
        #expect(harness.session.isAgentSpeaking)
        harness.session.interruptAgentSpeech()
        await harness.settle()
        #expect(sink.stops.all.count == 1)
        #expect(harness.session.interruptionCount == 1)
        #expect(!harness.session.isAgentSpeaking)
        let playedBefore = sink.played.all.count
        await harness.settle()
        #expect(sink.played.all.count == playedBefore, "nothing more is played after the interruption")
    }

    @Test func aNewHeardTurnStopsAReplyStillPlaying() async throws {
        let speech = FakeSpeech(), sink = FakeSink()
        speech.endless = true
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("A long story about the sea."))
        await harness.settle()
        try await harness.session.sendHeardTurn("Stop")
        #expect(sink.stops.all.count == 1)
        #expect(harness.driver.userMessages == ["Stop"])
    }

    @Test func interruptingWhenNothingPlaysDoesNothing() async {
        let sink = FakeSink()
        let harness = Harness(ownListening: sink.setting(FakeSpeech()))
        await harness.start()
        harness.session.interruptAgentSpeech()
        #expect(sink.stops.all.isEmpty)
        #expect(harness.session.interruptionCount == 0)
    }

    @Test func theAppsLevelsDriveIsUserSpeakingAndTheBus() async {
        let harness = Harness(ownListening: FakeSink().setting(FakeSpeech()))
        await harness.start()
        harness.session.userIsSpeaking(level: 0.2)
        #expect(harness.session.isUserSpeaking)
        await harness.settle()
        #expect(harness.posted.all.contains { if case .userSpeaking = $0 { return true } else { return false } })
    }

    @Test func levelsAreIgnoredOutsideOwnListening() async {
        let harness = Harness()
        await harness.start()
        harness.session.userIsSpeaking(level: 0.9)
        #expect(!harness.session.isUserSpeaking)
    }

    @Test func closingStopsTheVoice() async {
        let speech = FakeSpeech(), sink = FakeSink()
        speech.endless = true
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("A long story about the sea."))
        await harness.settle()
        await harness.session.close()
        #expect(sink.stops.all.count >= 1)
        #expect(!harness.session.isAgentSpeaking)
    }

    @Test func aSpeechFailureIsReportedAndDoesNotHoldTheConversation() async {
        let speech = FakeSpeech(), sink = FakeSink()
        speech.failure = SpeakableError("I couldn't say the reply aloud (text-to-speech error 401).")
        let harness = Harness(ownListening: sink.setting(speech))
        await harness.start()
        harness.driver.emit(.agentResponse("Hello."))
        await harness.settle()
        #expect(sink.played.all.isEmpty)
        #expect(harness.session.lastSpeechProblem?.contains("401") == true)
        harness.clock.advance(1)
        #expect(!harness.session.isAgentSpeaking)
    }
}
