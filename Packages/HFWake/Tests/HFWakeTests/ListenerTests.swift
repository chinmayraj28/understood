import Foundation
import HFCore
import Testing

@testable import HFWake

@Suite struct ListenerBehaviour {
    let source = FakeTranscriptSource()
    let wakes = Locked<[String]>([])

    func listener(timing: WakeTiming = WakeTiming(quietAfterBarePhrase: 0.05, quietMidSentence: 0.1, longestWait: 2)) -> WakeListener {
        let source = self.source
        return WakeListener(configuration: .init(timing: timing)) { source }
    }

    @Test func wakesWithTheRestOfTheSentence() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        #expect(listener.isListening)
        source.say("hey hands free open", final: false)
        source.say("Hey Handsfree, open Spotify.", final: true)
        #expect(await eventually { wakes.value == ["open Spotify"] })
        await listener.stop()
    }

    @Test func aBarePhraseWakesWithoutAnotherTranscript() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        source.say("hey handsfree")
        #expect(await eventually { wakes.value == [""] })
        await listener.stop()
    }

    @Test func wakesOnceUntilStartedAgain() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        for text in ["hey", "hey hands", "hey hands free", "hey hands free open mail"] { source.say(text) }
        source.say("Hey hands free, open Mail.", final: true)
        source.say("hey handsfree open safari", segment: 2, final: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(wakes.value == ["open Mail"])

        await listener.stop()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        source.say("hey handsfree open safari", segment: 1, final: true)
        #expect(await eventually { wakes.value == ["open Mail", "open safari"] })
        await listener.stop()
    }

    @Test func ordinarySpeechDoesNotWake() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        source.say("I use hands free in the car", final: true)
        source.say("she has a hands free kit", segment: 2, final: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(wakes.value.isEmpty)
        await listener.stop()
    }

    @Test func stopReleasesTheSourceAndIgnoresLateTranscripts() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        await listener.stop()
        #expect(source.stops.value == 1)
        #expect(!source.isRunning)
        #expect(!listener.isListening)
        source.say("hey handsfree open mail", final: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(wakes.value.isEmpty)
    }

    @Test func restartsAfterTheRecogniserStops() async throws {
        let listener = listener()
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        source.interrupt("recognition timed out")
        #expect(await eventually { source.starts.value == 2 && listener.isListening })
        #expect(source.stops.value == 1)
        source.say("hey handsfree open mail", final: true)
        #expect(await eventually { wakes.value == ["open mail"] })
        await listener.stop()
    }

    @Test func stopDuringARestartLeavesTheMicrophoneClosed() async throws {
        // Found by review: a restart in progress used to reopen the microphone after stop().
        let listener = listener()
        try await listener.start { _ in }
        source.startDelay.value = 0.3
        source.interrupt("the microphone changed")
        #expect(await eventually { source.starts.value == 2 })  // the restart is opening it
        await listener.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!source.isRunning, "nothing may hold the microphone after stop()")
        #expect(!listener.isListening)
    }

    @Test func keepsRetryingWhenARestartFails() async throws {
        let listener = listener()
        let diagnostics = Locked<[WakeDiagnostic]>([])
        listener.onDiagnostic = { diagnostic in diagnostics.update { $0.append(diagnostic) } }
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        source.startErrors.value = [SpeakableError("The microphone is busy.")]
        source.interrupt("the microphone changed")
        #expect(await eventually(timeout: 3) { source.starts.value == 3 && listener.isListening })
        #expect(diagnostics.value.contains(.restartFailed(SpeakableError("The microphone is busy."), retryInSeconds: 0.5)))
        await listener.stop()
    }

    @Test func aFailedStartThrowsASpeakableErrorAndIsNotListening() async throws {
        let listener = listener()
        let problem = SpeakableError("Orca isn't allowed to use the microphone, so I can't listen for the wake phrase.")
        source.startErrors.value = [problem]
        await #expect(throws: problem) {
            try await listener.start { _ in }
        }
        #expect(!listener.isListening)
        // A later start works.
        try await listener.start { [wakes] rest in wakes.update { $0.append(rest) } }
        #expect(listener.isListening)
        await listener.stop()
    }

    @Test func aNonSpeakableErrorBecomesASpeakableOne() async {
        let listener = listener()
        source.startErrors.value = [NSError(domain: "test", code: 1)]
        await #expect(throws: SpeakableError.self) { try await listener.start { _ in } }
    }

    @Test func transcriptsAreNotReportedUnlessAskedFor() async throws {
        let listener = listener()
        let diagnostics = Locked<[WakeDiagnostic]>([])
        listener.onDiagnostic = { diagnostic in diagnostics.update { $0.append(diagnostic) } }
        try await listener.start { _ in }
        source.say("something private said in the room", final: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!diagnostics.value.contains { if case .transcript = $0 { return true } else { return false } })
        await listener.stop()
    }

    @Test func contextualStringsNameTheWords() {
        let configuration = WakeListener.Configuration(phrase: "Hey Handsfree", alternatives: ["Okay Computer"])
        #expect(configuration.contextualStrings == ["Hey Handsfree", "Handsfree", "Okay Computer", "Computer"])
    }

    @Test func configurationFromSettingsUsesThePhrase() {
        let settings = Settings.load(environment: ["WAKE_PHRASE": "Hello Sam's Mac"], envFileCandidates: [])
        #expect(WakeListener.Configuration(settings: settings).phrase == "Hello Sam's Mac")
    }
}

@Suite struct TranscriberSessions {
    let input = FakeAudioInput()

    func transcriber(engine: FakeRecognitionEngine, clock: Locked<Double> = Locked(0)) -> StreamingTranscriber {
        StreamingTranscriber(input: input, engine: engine, requestPermission: false, quietBeforeReplacing: 1.5) { clock.value }
    }

    @Test func aSessionThatTimesOutIsReplacedWithoutLosingAudio() async throws {
        let engine = FakeRecognitionEngine()
        let transcriber = transcriber(engine: engine)
        let updates = Locked<[TranscriptUpdate]>([])
        try await transcriber.start(onUpdate: { update in updates.update { $0.append(update) } }, onInterrupted: { _ in })
        input.deliver(marker: 1)
        let first = engine.sessions.value[0]
        first.transcript("background", segment: 0, final: true)

        first.end()  // the recogniser timed out
        input.deliver(marker: 2)  // arrives while the next session is being made, or after
        #expect(await eventually { engine.sessions.value.count == 2 })
        let second = engine.sessions.value[1]
        input.deliver(marker: 3)
        #expect(await eventually { second.received.value == [2, 3] })
        #expect(first.received.value == [1])
        #expect(first.cancelled.value)

        // The old session's late words are ignored; the new session's segments are distinct.
        first.transcript("late words", segment: 5)
        second.transcript("hey handsfree", segment: 0)
        #expect(await eventually { updates.value.count == 2 })
        #expect(updates.value.map(\.text) == ["background", "hey handsfree"])
        #expect(updates.value[0].segment != updates.value[1].segment)
        await transcriber.stop()
    }

    @Test func aLongSessionIsReplacedAtAQuietMoment() async throws {
        let engine = FakeRecognitionEngine(preferredSessionSeconds: 10)
        let clock = Locked(0.0)
        let transcriber = transcriber(engine: engine, clock: clock)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        clock.value = 5
        input.deliver(marker: 1)
        #expect(engine.sessions.value.count == 1)
        clock.value = 11
        engine.sessions.value[0].transcript("words")  // still talking: not quiet
        input.deliver(marker: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(engine.sessions.value.count == 1)
        clock.value = 13  // two quiet seconds
        input.deliver(marker: 3)
        #expect(await eventually { engine.sessions.value.count == 2 })
        // The old session kept listening until the new one was ready.
        #expect(engine.sessions.value[0].received.value.prefix(3) == [1, 2, 3])
        #expect(await eventually { engine.sessions.value[0].cancelled.value })
        input.deliver(marker: 4)
        #expect(await eventually { engine.sessions.value[1].received.value.contains(4) })
        await transcriber.stop()
    }

    @Test func aReplacementFromBeforeARestartIsThrownAway() async throws {
        // Found by review: a session being made when stop() and start() happened used to
        // install itself over the fresh one.
        let engine = FakeRecognitionEngine()
        let transcriber = transcriber(engine: engine)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        engine.makeDelay.value = 0.3
        engine.sessions.value[0].end()  // a replacement starts, and takes 0.3 s
        try await Task.sleep(nanoseconds: 50_000_000)
        await transcriber.stop()
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        // Let the stale replacement finish whatever it was doing (it may not even make a session).
        try await Task.sleep(nanoseconds: 900_000_000)
        let live = engine.sessions.value.filter { !$0.cancelled.value }
        #expect(live.count == 1, "only the fresh session may be running")
        input.deliver(marker: 7)
        #expect(live.first?.received.value == [7])
        await transcriber.stop()
    }

    @Test func sessionsThatEndAtOnceAreReplacedMoreSlowly() async throws {
        let engine = FakeRecognitionEngine()
        let transcriber = transcriber(engine: engine)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            engine.sessions.value.last?.end()  // every session ends the moment it starts
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(engine.sessions.value.count <= 3, "made \(engine.sessions.value.count) sessions in 1.2 s")
        await transcriber.stop()
    }

    @Test func aLongSessionIsRenewedEvenWithoutAQuietMoment() async throws {
        let engine = FakeRecognitionEngine(preferredSessionSeconds: 10)
        let clock = Locked(0.0)
        let transcriber = transcriber(engine: engine, clock: clock)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        clock.value = 21
        engine.sessions.value[0].transcript("the television keeps talking")
        input.deliver(marker: 1)
        #expect(await eventually { engine.sessions.value.count == 2 })
        await transcriber.stop()
    }

    @Test func stopReleasesTheMicrophoneAndCancelsTheSession() async throws {
        let engine = FakeRecognitionEngine()
        let transcriber = transcriber(engine: engine)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        #expect(input.running.value)
        await transcriber.stop()
        #expect(!input.running.value)
        #expect(input.stops.value >= 1)
        #expect(engine.sessions.value[0].cancelled.value)
        // Audio after stop goes nowhere.
        input.deliver(marker: 9)
        #expect(engine.sessions.value[0].received.value.isEmpty)
    }

    @Test func startsAgainAfterStopWithAFreshMicrophone() async throws {
        let engine = FakeRecognitionEngine()
        let transcriber = transcriber(engine: engine)
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        await transcriber.stop()
        try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        #expect(input.prepares.value == 2)
        #expect(engine.sessions.value.count == 2)
        input.deliver(marker: 5)
        #expect(engine.sessions.value[1].received.value == [5])
        await transcriber.stop()
    }

    @Test func aPermissionProblemStopsStartBeforeTheMicrophoneOpens() async {
        let engine = FakeRecognitionEngine()
        engine.prepareError.value = SpeakableError("Orca isn't allowed to use the microphone.")
        let transcriber = transcriber(engine: engine)
        await #expect(throws: SpeakableError.self) {
            try await transcriber.start(onUpdate: { _ in }, onInterrupted: { _ in })
        }
        #expect(input.prepares.value == 0)
        #expect(!input.running.value)
    }
}

@Suite struct ListenerSpeechWithoutPhrase {
    @Test func countsFinishedUtterancesThatWereNotThePhraseWithoutTheirWords() async throws {
        let source = FakeTranscriptSource()
        let listener = WakeListener(configuration: .init()) { source }
        let diagnostics = Locked<[WakeDiagnostic]>([])
        listener.onDiagnostic = { diagnostic in diagnostics.update { $0.append(diagnostic) } }
        try await listener.start { _ in }
        source.say("what time is", segment: 1)  // a guess: not counted
        source.say("What time is it?", segment: 1, final: true)  // counted
        source.say("?", segment: 2, final: true)  // no words: not counted
        source.say("hey hands free", segment: 3, final: false)  // the phrase: not counted
        _ = await eventually { diagnostics.value.contains { if case .phraseHeard = $0 { return true } else { return false } } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = diagnostics.value.filter { $0 == .speechWithoutPhrase }.count
        #expect(count == 1)
        // The phrase diagnostic names the configured phrase, not what the recogniser wrote.
        #expect(diagnostics.value.contains(.phraseHeard(heardAs: "Hey Handsfree")))
        await listener.stop()
    }
}
