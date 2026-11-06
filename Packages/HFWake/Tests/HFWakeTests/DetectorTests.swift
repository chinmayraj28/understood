import Testing

@testable import HFWake

@Suite struct DetectorTiming {
    let timing = WakeTiming(afterFinalBarePhrase: 0.4, quietAfterBarePhrase: 0.7, quietMidSentence: 1.3, longestWait: 6)
    func detector() -> WakeDetector { WakeDetector(matcher: WakePhraseMatcher(phrase: "Hey Handsfree"), timing: timing) }

    @Test func aBarePhraseWakesAfterAShortQuiet() {
        var detector = detector()
        #expect(detector.receive(.init(segment: 1, text: "hey", isFinal: false), at: 0) == nil)
        #expect(detector.receive(.init(segment: 1, text: "hey hands free", isFinal: false), at: 0.3) == nil)
        #expect(detector.nextDeadline == 1.0)
        #expect(detector.check(at: 0.9) == nil)
        let wake = detector.check(at: 1.0)
        #expect(wake?.restOfSentence == "")
        #expect(wake?.phraseFirstHeardAt == 0.3)
    }

    @Test func aFinalBarePhraseWakesAfterAMoment() {
        // What SpeechAnalyzer did on this Mac: a burst of guesses, then the final ~0.9 s later.
        var detector = WakeDetector(matcher: WakePhraseMatcher(phrase: "Hey Handsfree"), timing: WakeTiming())
        _ = detector.receive(.init(segment: 1, text: "Hey handsfree", isFinal: false), at: 0)
        #expect(detector.receive(.init(segment: 1, text: "Hey, hands-free.", isFinal: true), at: 0.9) == nil)
        #expect(detector.nextDeadline == 1.15)
        #expect(detector.check(at: 1.1) == nil)
        #expect(detector.check(at: 1.15)?.restOfSentence == "")
    }

    @Test func wordsInTheSameBurstAsTheFinalAreWaitedFor() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "Hey Handsfree.", isFinal: true), at: 0.9)
        _ = detector.receive(.init(segment: 2, text: "open", isFinal: false), at: 0.95)
        #expect(detector.check(at: 1.3) == nil)
        #expect(detector.receive(.init(segment: 2, text: "Open Mail.", isFinal: true), at: 1.8)?.restOfSentence == "Open Mail")
    }

    @Test func theDefaultsSuitTheMeasuredRecogniser() {
        // Fallback quiet times must be longer than SpeechAnalyzer's ~0.9 s between bursts.
        let defaults = WakeTiming()
        #expect(defaults.quietAfterBarePhrase > 1.0)
        #expect(defaults.quietMidSentence > defaults.quietAfterBarePhrase)
        #expect(defaults.afterFinalBarePhrase < 0.5)
    }

    @Test func aCompleteSentenceWakesAsSoonAsItIsFinal() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "hey hands free open", isFinal: false), at: 0)
        let wake = detector.receive(.init(segment: 1, text: "Hey Handsfree, open Spotify.", isFinal: true), at: 0.4)
        #expect(wake?.restOfSentence == "open Spotify")
    }

    @Test func revisedPartialsWakeOnce() {
        var detector = detector()
        var wakes: [String] = []
        let partials = ["hey", "hey hands", "hey hands free", "hey hands free open", "hey hands free open spot"]
        for (index, text) in partials.enumerated() {
            if let wake = detector.receive(.init(segment: 1, text: text, isFinal: false), at: Double(index) * 0.2) {
                wakes.append(wake.restOfSentence)
            }
        }
        if let wake = detector.receive(.init(segment: 1, text: "Hey handsfree, open Spotify.", isFinal: true), at: 1.1) {
            wakes.append(wake.restOfSentence)
        }
        // The same phrase, still on the screen in later transcripts, and checks after the wake.
        for text in ["Hey handsfree, open Spotify.", "hey handsfree"] {
            if let wake = detector.receive(.init(segment: 2, text: text, isFinal: true), at: 2) { wakes.append(wake.restOfSentence) }
        }
        if let wake = detector.check(at: 10) { wakes.append(wake.restOfSentence) }
        #expect(wakes == ["open Spotify"])
        #expect(detector.hasWoken)
    }

    @Test func waitsLongerMidSentenceAndKeepsWaitingWhileWordsArrive() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "hey handsfree open", isFinal: false), at: 0)
        #expect(detector.check(at: 1.0) == nil)  // longer than the bare wait, shorter than mid-sentence
        _ = detector.receive(.init(segment: 1, text: "hey handsfree open the", isFinal: false), at: 1.2)
        #expect(detector.check(at: 2.4) == nil)
        #expect(detector.check(at: 2.6)?.restOfSentence == "open the")
    }

    @Test func aRepeatedOrRepunctuatedGuessIsNotNewSpeech() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "hey handsfree", isFinal: false), at: 0)
        _ = detector.receive(.init(segment: 1, text: "hey handsfree", isFinal: false), at: 0.3)
        _ = detector.receive(.init(segment: 1, text: "Hey, handsfree.", isFinal: false), at: 0.5)
        #expect(detector.check(at: 0.7)?.restOfSentence == "")
    }

    @Test func wordsInTheNextSegmentJoinTheRest() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "Hey Handsfree.", isFinal: true), at: 0)
        _ = detector.receive(.init(segment: 2, text: "open", isFinal: false), at: 0.5)
        let wake = detector.receive(.init(segment: 2, text: "Open Spotify.", isFinal: true), at: 0.9)
        #expect(wake?.restOfSentence == "Open Spotify")
    }

    @Test func aFinalWithADifferentStartReplacesTheGuessesInsteadOfRepeatingThem() {
        var detector = detector()
        _ = detector.receive(.init(segment: 100, text: "hey handsfree open", isFinal: false), at: 0)
        let wake = detector.receive(.init(segment: 101, text: "Hey Handsfree, open Mail.", isFinal: true), at: 0.9)
        #expect(wake?.restOfSentence == "open Mail")
    }

    @Test func aPhraseSplitAcrossTwoSegmentsStillCounts() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "Hey.", isFinal: true), at: 0)
        let wake = detector.receive(.init(segment: 2, text: "Handsfree, open Mail.", isFinal: true), at: 0.8)
        #expect(wake?.restOfSentence == "open Mail")
    }

    @Test func aRevisionThatRemovesThePhraseDoesNotWake() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "hey hands free", isFinal: false), at: 0)
        _ = detector.receive(.init(segment: 1, text: "they handed three", isFinal: true), at: 0.3)
        #expect(detector.nextDeadline == nil)
        #expect(detector.check(at: 5) == nil)
    }

    @Test func wakesAtTheLatestAfterTheLongestWait() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "hey handsfree so", isFinal: false), at: 0)
        var time = 0.0
        var text = "hey handsfree so"
        while time < 5.0 {
            time += 0.5
            text += " and"
            #expect(detector.receive(.init(segment: 1, text: text, isFinal: false), at: time) == nil)
        }
        #expect(detector.check(at: 6)?.restOfSentence.hasPrefix("so and") == true)
    }

    @Test func resetAllowsTheNextWake() {
        var detector = detector()
        _ = detector.receive(.init(segment: 1, text: "Hey Handsfree open Mail", isFinal: true), at: 0)
        #expect(detector.hasWoken)
        detector.reset()
        #expect(detector.receive(.init(segment: 9, text: "Hey Handsfree open Safari", isFinal: true), at: 1)?.restOfSentence == "open Safari")
    }
}
