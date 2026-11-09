import HFCore
import Testing

@testable import HFUnderstand

private func heard(_ scribe: String?, _ gemini: String?, _ apple: String?) -> [Hypothesis] {
    func one(_ name: HearerName, _ text: String?) -> Hypothesis {
        text.map { Hypothesis(hearer: name, text: $0, seconds: 0.1) }
            ?? Hypothesis(hearer: name, text: "", seconds: 4, failure: "timed out")
    }
    return [one(.scribe, scribe), one(.gemini, gemini), one(.apple, apple)]
}

private func decide(
    _ hypotheses: [Hypothesis], reading: Reading? = nil, match: PhrasebookMatch? = nil,
    own: [HearerName: PhrasebookMatch] = [:], expected: [String] = [], failedTries: Int = 0
) -> UnderstandingDecision {
    // `match` is Scribe's own match; `own` adds the other recognisers' own matches.
    var byHearer = own
    if let match { byHearer[.scribe] = match }
    return Decider.decide(DecisionInput(
        hypotheses: hypotheses, phrasebookMatch: match, phrasebookMatchesByHearer: byHearer, reading: reading,
        context: UnderstandingContext(pendingQuestion: expected.isEmpty ? nil : "Which?", expectedAnswers: expected),
        failedTries: failedTries))
}

@Suite("Decider: the stage 4 table")
struct DeciderTableTests {
    @Test func agreementAndHighReadingActs() {
        let decision = decide(heard("Volume up", "volume up.", "volume up"), reading: Reading(text: "volume up", confidence: .high))
        #expect(decision == .act(text: "volume up"))
    }

    @Test func strongPhrasebookMatchAndHighReadingActs() {
        let match = PhrasebookMatch(meant: "call Sam", heard: "call some", similarity: 1, timesConfirmed: 3)
        let gemini = PhrasebookMatch(meant: "call Sam", heard: "cool sum", similarity: 1, timesConfirmed: 2)
        let decision = decide(heard("call some", "cool sum", "call some"), reading: Reading(text: "call Sam", confidence: .high),
                              match: match, own: [.gemini: gemini])
        #expect(decision == .act(text: "call Sam"))
    }

    @Test func phrasebookConfirmedOnlyOnceStillAsks() {
        let match = PhrasebookMatch(meant: "call Sam", heard: "call some", similarity: 1, timesConfirmed: 1)
        let decision = decide(heard("call some", "cool sum", "call some"), reading: Reading(text: "call Sam", confidence: .high), match: match)
        #expect(decision == .confirm(question: "Call Sam?", reading: "call Sam"))
    }

    @Test func highReadingThatChangesTheAgreedWordsAsks() {
        // Both recognisers heard "call some"; Claude alone says "call Sam". Claude alone never acts.
        let decision = decide(heard("call some", "call some", nil), reading: Reading(text: "call Sam", confidence: .high))
        #expect(decision == .confirm(question: "Call Sam?", reading: "call Sam"))
    }

    @Test func disagreementOnAContentWordAsksEvenWhenHigh() {
        let decision = decide(heard("message Mum", "message Sam", "message Mum"), reading: Reading(text: "message Mum", confidence: .high))
        #expect(decision == .confirm(question: "Message Mum?", reading: "message Mum"))
    }

    @Test func disagreementOnlyOnFillerWordsStillActs() {
        let decision = decide(heard("open WhatsApp", "open the WhatsApp please", "Open WhatsApp."), reading: Reading(text: "open WhatsApp", confidence: .high))
        #expect(decision == .act(text: "open WhatsApp"))
    }

    @Test func mediumAsksOneYesNoQuestion() {
        let decision = decide(heard("message mum", "message mum", "message mum"), reading: Reading(text: "message Mum.", confidence: .medium))
        #expect(decision == .confirm(question: "Message Mum?", reading: "message Mum."))
    }

    @Test func lowWithAlternativesOffersAShortChoice() {
        let reading = Reading(text: "message Mum", confidence: .low, alternatives: ["message Sam"])
        let decision = decide(heard("message mom", "message some", nil), reading: reading)
        #expect(decision == .choose(question: "Mum or Sam?", options: ["message Mum", "message Sam"]))
    }

    @Test func threeOptionsAreListed() {
        let reading = Reading(text: "call Mum", confidence: .low, alternatives: ["call Sam", "call Tom"])
        #expect(decide(heard("call", "call", nil), reading: reading)
            == .choose(question: "Mum, Sam or Tom?", options: ["call Mum", "call Sam", "call Tom"]))
    }

    @Test func lowWithoutAlternativesAsksForThePartItMissed() {
        let decision = decide(heard("message blur", "message mrr", nil), reading: Reading(text: "message", confidence: .low))
        #expect(decision == .askAgain(question: "Message what? Say just that part."))
    }

    @Test func lowWithNothingInCommonAsksOnceMore() {
        let decision = decide(heard("blur", "mrr hmm", nil), reading: Reading(text: "blur", confidence: .low))
        #expect(decision == .askAgain(question: "Sorry, say it once more?"))
    }

    @Test func sayItAgainIsNeverAskedTwiceInARow() {
        let decision = decide(heard("blur", "mrr", nil), reading: Reading(text: "open Spotify", confidence: .low), failedTries: 1)
        #expect(decision == .confirm(question: "Open Spotify?", reading: "open Spotify"))
    }

    @Test func afterTwoFailedTriesOnlyYesNoQuestions() {
        let reading = Reading(text: "message Mum", confidence: .low, alternatives: ["message Sam"])
        #expect(decide(heard("message mom", "message some", nil), reading: reading, failedTries: 2)
            == .confirm(question: "Message Mum?", reading: "message Mum"))
    }
}

@Suite("Decider: stop, answers and failures")
struct DeciderSafetyTests {
    @Test func stopFromAnyRecogniserActsAtOnce() {
        #expect(decide(heard("open safari", "stop", "open safari")) == .act(text: "stop"))
        #expect(decide(heard("Stop!", nil, nil), expected: ["yes", "no"]) == .act(text: "stop"))
        #expect(decide(heard("cancel cancel", nil, nil), failedTries: 5) == .act(text: "cancel"))
    }

    @Test func stopInsideASentenceIsAnOrdinaryTurn() {
        let decision = decide(heard("stop the music", "stop the music", nil), reading: Reading(text: "stop the music", confidence: .medium))
        #expect(decision == .confirm(question: "Stop the music?", reading: "stop the music"))
    }

    @Test func twoRecognisersHearingAnExpectedAnswerAct() {
        #expect(decide(heard("Yes.", "yes please", "yeah"), expected: ["yes", "no"]) == .act(text: "yes"))
        #expect(decide(heard("Sam", "sam", nil), expected: ["message Mum", "message Sam"]) == .act(text: "message Sam"))
    }

    @Test func oneRecogniserHearingAnExpectedAnswerIsNotEnough() {
        let decision = decide(heard("yes", "yet", nil), reading: Reading(text: "yes", confidence: .medium), expected: ["yes", "no"])
        #expect(decision == .confirm(question: "Yes?", reading: "yes"))
    }

    @Test func everyRecogniserFailedCannotHear() {
        #expect(decide(heard(nil, nil, nil)) == .cannotHear(message: "I can't hear properly right now."))
        #expect(decide(heard("", "  ", "...")) == .cannotHear(message: "I can't hear properly right now."))
        #expect(decide([]) == .cannotHear(message: Decider.cannotHearMessage))
    }

    @Test func geminiDownStillActsOnAgreementButMediumAsks() {
        #expect(decide(heard("scroll down", nil, "scroll down"), reading: Reading(text: "scroll down", confidence: .high)) == .act(text: "scroll down"))
        #expect(decide(heard("scroll down", nil, "scroll down"), reading: Reading(text: "scroll down", confidence: .medium))
            == .confirm(question: "Scroll down?", reading: "scroll down"))
    }

    @Test func scribeDownEverythingAboveLowAsks() {
        let decision = decide(heard(nil, "scroll down", "scroll down"), reading: Reading(text: "scroll down", confidence: .high))
        #expect(decision == .confirm(question: "Scroll down?", reading: "scroll down"))
    }

    @Test func noReadingFallsBackToAgreementThenPhrasebookThenScribe() {
        #expect(decide(heard("volume up", "volume up", "Volume up.")) == .act(text: "volume up"))
        let match = PhrasebookMatch(meant: "call Sam", heard: "call some", similarity: 0.95, timesConfirmed: 2)
        let gemini = PhrasebookMatch(meant: "call Sam", heard: "cool sum", similarity: 1, timesConfirmed: 2)
        #expect(decide(heard("call some", "cool sum", nil), match: match, own: [.gemini: gemini]) == .act(text: "call Sam"))
        #expect(decide(heard("call some", "cool sum", nil)) == .confirm(question: "Call some?", reading: "call some"))
        #expect(decide(heard(nil, "cool sum", nil)) == .confirm(question: "Cool sum?", reading: "cool sum"))
    }
}

@Suite("SpeechText")
struct SpeechTextTests {
    @Test func normalisesCasePunctuationAndNumbers() {
        #expect(SpeechText.normalise("Call Sam, at TWO!") == "call sam at 2")
        #expect(SpeechText.normalise("Don’t") == "dont")
    }

    @Test func soundAlikeWordsShareAKey() {
        #expect(SpeechText.soundKey("some") == SpeechText.soundKey("sum"))
        #expect(SpeechText.soundKey("phone") == SpeechText.soundKey("fone"))
        #expect(SpeechText.soundKey("mum") != SpeechText.soundKey("sam"))
    }

    @Test func similarityRanksCloseTranscriptsHigher() {
        #expect(SpeechText.similarity("call some", "Call some.") == 1)
        let soundAlike = SpeechText.similarity("call some", "call sum")
        #expect(soundAlike > 0.8 && soundAlike < Decider.strongMatchSimilarity)
        #expect(SpeechText.similarity("call some", "open spotify") < 0.5)
    }
}
