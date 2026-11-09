import Foundation
import HFCore
import Testing

@testable import HFUnderstand

// One test per finding of the 9 Nov review: each is a way a wrong reading could have become an
// action without a question. Each case is the reviewer's own example.

private func hypotheses(_ scribe: String?, _ gemini: String?, _ apple: String?) -> [Hypothesis] {
    zip([HearerName.scribe, .gemini, .apple], [scribe, gemini, apple]).map { name, text in
        text.map { Hypothesis(hearer: name, text: $0, seconds: 0.1) } ?? Hypothesis(hearer: name, text: "", seconds: 4, failure: "timed out")
    }
}

private func isAct(_ decision: UnderstandingDecision) -> Bool {
    if case .act = decision { return true } else { return false }
}

@Suite("Review findings")
struct ReviewFindingsTests {
    // 1. Fixed answers: the other recognisers must not out-vote Scribe, and a negation blocks.
    @Test func aFixedAnswerNeedsScribeAndNoContradiction() {
        let yesNo = UnderstandingContext(pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"])
        #expect(!isAct(Decider.decide(DecisionInput(hypotheses: hypotheses("no", "yes", "yes"), context: yesNo))))
        #expect(!isAct(Decider.decide(DecisionInput(hypotheses: hypotheses("yes", "yes", "yes but don't send"), context: yesNo))))
        #expect(Decider.decide(DecisionInput(hypotheses: hypotheses("No.", "no", "no"), context: yesNo)) == .act(text: "no"))

        let names = UnderstandingContext(pendingQuestion: "Message Mum or message Sam?", expectedAnswers: ["message Mum", "message Sam"])
        #expect(!isAct(Decider.decide(DecisionInput(hypotheses: hypotheses("not Mum", "message Mum", "message Mum"), context: names))))
        #expect(!isAct(Decider.decide(DecisionInput(hypotheses: hypotheses("Mum", "Sam", "Mum"), context: names))))
        #expect(Decider.decide(DecisionInput(hypotheses: hypotheses("Mum", "mum", nil), context: names)) == .act(text: "message Mum"))
    }

    // 2. A phrasebook pair counts only for the recogniser that stored it, and only when nobody heard otherwise.
    @Test func aPhrasebookPairCountsOnlyForItsOwnRecogniser() throws {
        let book = try Phrasebook.inMemory()
        for _ in 0..<3 { try book.add(heard: "mess a mum", meant: "message Mum", hearer: .apple, source: .confirmation) }
        let heard = hypotheses("mess a mum", nil, nil)
        #expect(book.matchesByHearer(for: heard).isEmpty)  // Scribe never stored that pair
        #expect(book.bestMatch(for: ["mess a mum"])?.meant == "message Mum")  // still a hint for repair

        let contradicted = hypotheses("message Sam", nil, "mess a mum")
        let byHearer = book.matchesByHearer(for: contradicted)
        #expect(byHearer[.apple]?.meant == "message Mum")
        let decision = Decider.decide(DecisionInput(hypotheses: contradicted, phrasebookMatchesByHearer: byHearer))
        #expect(decision == .confirm(question: "Message Sam?", reading: "message Sam"))

        let supported = hypotheses(nil, "message mum", "mess a mum")
        #expect(Decider.decide(DecisionInput(hypotheses: supported, phrasebookMatchesByHearer: book.matchesByHearer(for: supported)))
            == .act(text: "message Mum"))
    }

    // 3. A near match that differs on a negation, a number or a name is never strong.
    @Test func negationsNumbersAndNamesMustBeIdentical() {
        let stored = "please do send the message to sam right now"
        let negated = "please do not send the message to sam right now"
        let match = PhrasebookMatch(meant: stored, heard: stored, similarity: SpeechText.similarity(negated, stored), timesConfirmed: 5)
        #expect(Decider.isStrong(match))  // close enough on spelling alone...
        let decision = Decider.decide(DecisionInput(hypotheses: hypotheses(negated, nil, nil), phrasebookMatchesByHearer: [.scribe: match]))
        #expect(decision == .confirm(question: "Please do not send the message to sam right now?", reading: negated))  // ...but never trusted

        #expect(!SpeechText.keyWordsAgree("set a timer for 2 minutes", "set a timer for 3 minutes", names: []))
        #expect(!SpeechText.keyWordsAgree("message Sam that I am running late tonight", "message Tom that I am running late tonight",
                                          names: ["sam", "tom"]))
        #expect(SpeechText.keyWordsAgree("Message mum.", "message Mum", names: ["mum"]))
    }

    // 4. Only a spoken yes, a chosen option or a correction is learned; a rejection is not.
    @Test func onlyConfirmationsAndCorrectionsAreLearned() async throws {
        let book = try Phrasebook.inMemory()
        let layer = Understander(hearers: [FakeHearer(.scribe, "call some")], repairModel: nil, phrasebook: book)
        let turn = RecordedTurn(wav: Data([1]), durationSeconds: 1, source: "test")
        let result = await layer.understand(turn, context: .init())
        await layer.learn(from: turn, result: result, outcome: .rejected)
        #expect(book.count == 0)
        await layer.learn(from: turn, result: result, outcome: .confirmed(meant: "call Sam"))
        #expect(book.count == 1)
    }

    // 5. Hints can push Scribe and Gemini into agreeing on a hinted name: Apple's hint-free transcript must agree too.
    @Test func agreementOnAHintedNameNeedsApplesHintFreeTranscript() async throws {
        let input = DecisionInput(hypotheses: hypotheses("message Priya", "message Priya.", nil), hintedTerms: ["Priya", "Sam"])
        #expect(Decider.decide(input) == .confirm(question: "Message Priya?", reading: "message Priya"))
        var withLive = input
        withLive.liveTranscript = "message priya"
        #expect(Decider.decide(withLive) == .act(text: "message Priya"))
        var unhinted = input
        unhinted.hintedTerms = []
        #expect(Decider.decide(unhinted) == .act(text: "message Priya"))

        let yesNo = UnderstandingContext(pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"])
        let hintedYes = DecisionInput(hypotheses: hypotheses("yes", "yes", "yet"), context: yesNo, hintedTerms: ["yes", "no"])
        #expect(!isAct(Decider.decide(hintedYes)))
        var appleAgrees = hintedYes
        appleAgrees.liveTranscript = "yes"
        #expect(Decider.decide(appleAgrees) == .act(text: "yes"))

        // Through the whole layer: the app's contact name is a hint, and Apple failed.
        var configuration = UnderstanderConfiguration()
        configuration.extraKeyterms = ["Priya"]
        configuration.postsActivity = false
        configuration.hearerTimeoutSeconds = 0.5
        let layer = Understander(
            hearers: [FakeHearer(.scribe, "message Priya"), FakeHearer(.gemini, "message Priya"), FakeHearer(.apple, error: SpeakableError("down"))],
            repairModel: nil, phrasebook: try Phrasebook.inMemory(), configuration: configuration)
        let result = await layer.understand(RecordedTurn(wav: Data(), durationSeconds: 1, source: "test"), context: .init())
        #expect(result.decision == .confirm(question: "Message Priya?", reading: "message Priya"))
    }

    // 6. A rejected confirmation counts as one failed try, not two.
    @Test func aRejectedConfirmationCountsOnce() async throws {
        let layer = Understander(
            hearers: [FakeHearer(.scribe, "call some", "no", "yes"), FakeHearer(.apple, "cool sum", "no", "yes")],
            repairModel: nil, phrasebook: try Phrasebook.inMemory())
        let turn = RecordedTurn(wav: Data(), durationSeconds: 1, source: "test")
        let first = await layer.understand(turn, context: .init())
        guard case .confirm(let question, _) = first.decision else { Issue.record("expected a question"); return }
        #expect(layer.consecutiveFailedTries == 1)

        let answer = UnderstandingContext(pendingQuestion: question, expectedAnswers: ["yes", "no"])
        #expect(await layer.understand(turn, context: answer).decision == .act(text: "no"))
        await layer.learn(from: turn, result: first, outcome: .rejected)
        #expect(layer.consecutiveFailedTries == 2)  // one for the question, one for the "no", none for learn

        #expect(await layer.understand(turn, context: .init(pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"])).decision == .act(text: "yes"))
        #expect(layer.consecutiveFailedTries == 0)
    }

    // 7. The folder is 0700 and the file 0600 before SQLite opens it; if that fails, nothing is stored.
    @Test func thePhrasebookIsPrivateFromTheStart() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let path = folder.appendingPathComponent("phrasebook.sqlite")
        _ = try Phrasebook(path: path)
        #expect(try files.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try files.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int == 0o600)

        #expect(throws: SpeakableError.self) { _ = try Phrasebook(path: URL(fileURLWithPath: "/System/handsfree-test/phrasebook.sqlite")) }
    }
}
