import Foundation
import Testing

@testable import HFUnderstand

// The turn recorder's rules, fed made-up levels and transcripts: no microphone needed.
// Levels: -70 dBFS is a quiet room, -30 dBFS is someone speaking.

private let quiet = -70.0
private let speech = -30.0

/// Feeds `seconds` of one level in 50 ms chunks and returns everything the detector said.
@discardableResult
private func feed(_ detector: inout TurnEndDetector, _ decibels: Double, seconds: Double) -> [TurnDetectorEvent] {
    var events: [TurnDetectorEvent] = []
    for _ in 0..<Int((seconds / 0.05).rounded()) { events += detector.audio(decibels: decibels, duration: 0.05) }
    return events
}

private func boundaries(_ events: [TurnDetectorEvent]) -> [TurnBoundary] {
    events.compactMap { if case .turnEnded(let boundary) = $0 { return boundary } else { return nil } }
}

private func stops(_ events: [TurnDetectorEvent]) -> [String] {
    events.compactMap { if case .stopHeard(let word, _) = $0 { return word } else { return nil } }
}

@Suite("Turn recorder: end of turn")
struct TurnEndDetectorTests {
    @Test("A pause inside a sentence shorter than the end silence does not end the turn")
    func pauseInsideSentence() {
        var detector = TurnEndDetector()
        var events = feed(&detector, quiet, seconds: 1)
        events += feed(&detector, speech, seconds: 1)
        events += feed(&detector, quiet, seconds: 2.0)  // a long pause, but under 2.5 s
        #expect(boundaries(events).isEmpty)
        events += feed(&detector, speech, seconds: 1)
        events += feed(&detector, quiet, seconds: 3)
        let ended = boundaries(events)
        #expect(ended.count == 1)
        #expect(ended.first?.reason == .silence)
        // From the first sound less the pre-roll, to the last sound plus the kept quiet.
        #expect(abs((ended.first?.audioStart ?? 0) - 0.6) < 0.06)
        #expect(abs((ended.first?.audioEnd ?? 0) - 5.4) < 0.06)
    }

    @Test("A long silence ends the turn, exactly when the end silence has passed")
    func longSilenceEndsTurn() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 1)
        let early = feed(&detector, quiet, seconds: 2.4)
        #expect(boundaries(early).isEmpty)
        #expect(detector.isInTurn)
        let late = feed(&detector, quiet, seconds: 0.2)
        #expect(boundaries(late).first?.reason == .silence)
        #expect(!detector.isInTurn)
    }

    @Test("The end silence can be changed")
    func endSilenceIsSettable() {
        var detector = TurnEndDetector(settings: TurnEndSettings(endSilenceSeconds: 1.0))
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 1)
        #expect(boundaries(feed(&detector, quiet, seconds: 1.05)).count == 1)
    }

    @Test("Saying \"done\" ends the turn early, and \"done\" is taken off the transcript")
    func doneEndsEarly() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 1.0)
        feed(&detector, quiet, seconds: 0.4)
        feed(&detector, speech, seconds: 0.4)  // "done"
        let heard = detector.transcript(key: 1, segmentStart: 1.0, text: "Message Mum, done.")
        #expect(boundaries(heard).isEmpty)  // not before a moment of quiet
        let events = feed(&detector, quiet, seconds: 0.7)
        let ended = boundaries(events)
        #expect(ended.count == 1)
        #expect(ended.first?.reason == .saidDone)
        #expect(ended.first?.liveTranscript == "Message Mum")
        // The audio stops where "done" began (2.4 s), so the hearers do not hear it.
        #expect(abs((ended.first?.audioEnd ?? 0) - 2.4) < 0.06)
    }

    @Test("\"done\" in the middle of a sentence does not end the turn")
    func doneInTheMiddle() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 1)
        _ = detector.transcript(key: 1, segmentStart: 1.0, text: "I'm done with this")
        #expect(boundaries(feed(&detector, quiet, seconds: 1.5)).isEmpty)
    }

    @Test("A blip shorter than the minimum is ignored")
    func blipIgnored() {
        var detector = TurnEndDetector()
        var events = feed(&detector, quiet, seconds: 1)
        events += feed(&detector, speech, seconds: 0.15)  // a click
        events += feed(&detector, quiet, seconds: 3)
        #expect(!events.contains { if case .speechStarted = $0 { return true } else { return false } })
        #expect(boundaries(events).isEmpty)
        #expect(events.contains { if case .blipIgnored = $0 { return true } else { return false } })
    }

    @Test("Speech that never pauses is cut at the longest turn")
    func maxLength() {
        var detector = TurnEndDetector(settings: TurnEndSettings(maxTurnSeconds: 10))
        feed(&detector, quiet, seconds: 1)
        let events = feed(&detector, speech, seconds: 12)
        let ended = boundaries(events)
        #expect(ended.first?.reason == .maxLength)
        #expect(abs((ended.first?.audioEnd ?? 0) - 11) < 0.06)
    }

    @Test("\"stop\" fires from a partial result at once, and once for each time it is said")
    func stopFromPartial() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 0.5)
        #expect(stops(detector.transcript(key: 1, segmentStart: 1.0, text: "please st")).isEmpty)
        #expect(stops(detector.transcript(key: 1, segmentStart: 1.0, text: "please stop")) == ["stop"])
        // The same partial again, revised wording: no second stop.
        #expect(stops(detector.transcript(key: 1, segmentStart: 1.0, text: "Please stop.")).isEmpty)
        // Said a second time.
        #expect(stops(detector.transcript(key: 1, segmentStart: 1.0, text: "please stop stop")) == ["stop"])
        #expect(stops(detector.transcript(key: 2, segmentStart: 2.0, text: "cancel")) == ["cancel"])
        // The turn is still under way: stop is not the end of the turn.
        #expect(detector.isInTurn)
    }

    @Test("\"stop\" fires even before a turn has started, as when the agent is talking")
    func stopWhileIdle() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        #expect(stops(detector.transcript(key: 7, segmentStart: 0.9, text: "wait")) == ["wait"])
    }

    @Test("Words from an earlier turn are not in the next turn's transcript")
    func transcriptsStayInTheirTurn() {
        var detector = TurnEndDetector()
        feed(&detector, quiet, seconds: 1)
        feed(&detector, speech, seconds: 1)
        _ = detector.transcript(key: 100, segmentStart: 1.0, text: "open WhatsApp")
        let first = boundaries(feed(&detector, quiet, seconds: 3))
        #expect(first.first?.liveTranscript == "open WhatsApp")
        feed(&detector, speech, seconds: 1)
        _ = detector.transcript(key: 500, segmentStart: 5.0, text: "message Mum")
        let second = boundaries(feed(&detector, quiet, seconds: 3))
        #expect(second.first?.liveTranscript == "message Mum")
    }

    @Test("The noise floor is learnt, so a steady noisy room is not a turn")
    func noiseFloorAdapts() {
        var detector = TurnEndDetector()
        var events = feed(&detector, -42, seconds: 5)  // a fan
        #expect(!events.contains { if case .speechStarted = $0 { return true } else { return false } })
        events += feed(&detector, -25, seconds: 1)  // someone speaking over it
        events += feed(&detector, -42, seconds: 3)
        #expect(boundaries(events).count == 1)
    }

    @Test("A final word is taken off whole, with its punctuation")
    func removingFinalWord() {
        #expect(TurnEndDetector.removingFinalWord("done", from: "Message Mum, done.") == "Message Mum")
        #expect(TurnEndDetector.removingFinalWord("done", from: "Done") == "")
        #expect(TurnEndDetector.removingFinalWord("done", from: "it is abandoned") == "it is abandoned")
        #expect(TurnEndDetector.removingFinalWord("done", from: "scroll down") == "scroll down")
    }
}

@Suite("Turn recorder: cutting the turn out of the audio")
struct TurnRecorderCoreTests {
    /// `seconds` of a 220 Hz tone at `amplitude`, as 16 kHz samples. Amplitude 0 is silence.
    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    @Test("A spoken turn comes out as a 16 kHz mono 16-bit WAV of the right length")
    func turnAsWAV() throws {
        var core = TurnRecorderCore(settings: TurnEndSettings())
        var events = core.ingest(tone(1, amplitude: 0.001))
        events += core.ingest(tone(1, amplitude: 0.3))
        events += core.ingest(tone(3, amplitude: 0.001))
        let turns = events.compactMap { event -> (RecordedTurnShape)? in
            if case .turnFinished(let turn, let reason) = event { return RecordedTurnShape(turn: turn, reason: reason) } else { return nil }
        }
        let turn = try #require(turns.first)
        #expect(turns.count == 1)
        #expect(turn.reason == .silence)
        // 0.4 s pre-roll + 1 s of speech + 0.4 s of kept quiet.
        #expect(abs(turn.turn.durationSeconds - 1.8) < 0.06)
        let wav = turn.turn.wav
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let bits = wav[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(sampleRate == 16_000 && channels == 1 && bits == 16)
        #expect(wav.count == 44 + Int((turn.turn.durationSeconds * 16_000).rounded()) * 2)
        #expect(turn.turn.source == "mic")
    }

    @Test("Speech starts and levels are reported during a turn")
    func startAndLevels() {
        var core = TurnRecorderCore(settings: TurnEndSettings())
        var events = core.ingest(tone(1, amplitude: 0.001))
        events += core.ingest(tone(0.5, amplitude: 0.3))
        #expect(events.contains(.speechStarted))
        let levels = events.compactMap { if case .level(let level) = $0 { return level } else { return nil } }
        #expect(!levels.isEmpty)
        #expect(levels.allSatisfy { $0 > 0.3 && $0 <= 1 })
    }

    @Test("Audio arriving in odd-sized pieces is judged the same")
    func oddSizedBuffers() {
        var core = TurnRecorderCore(settings: TurnEndSettings())
        let all = tone(1, amplitude: 0.001) + tone(1, amplitude: 0.3) + tone(3, amplitude: 0.001)
        var events: [TurnRecorderEvent] = []
        var index = 0
        while index < all.count {
            let end = min(all.count, index + 1_365)
            events += core.ingest(Array(all[index..<end]))
            index = end
        }
        #expect(events.filter { if case .turnFinished = $0 { return true } else { return false } }.count == 1)
    }
}

private struct RecordedTurnShape {
    var turn: RecordedTurn
    var reason: TurnEndReason
}

import HFCore
