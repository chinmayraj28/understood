import Testing

@testable import HFTasks

// Scenario 18 of docs/TASKS.md: how the word list reads a spoken reply.
struct ReplyJudgeTests {

    @Test("18. Word list", arguments: [
        ("yes", ReplyVerdict.yes),
        ("Yes.", .yes),
        ("yeah go for it", .yes),
        ("send it", .yes),
        ("ok send the invite", .yes),
        ("sure", .yes),
        ("no", .no),
        ("nope", .no),
        ("don't", .no),
        ("Don\u{2019}t send it", .no),
        ("dont send it", .no),
        ("no problem, go ahead", .no),  // a negative word always wins
        ("wait, change the time", .correction),
        ("yes but change the time", .correction),
        ("send it?", .unclear),
        ("hmm", .unclear),
        ("maybe", .unclear),
        ("yes, to Priya Patel", .unclear),
        ("the blue one", .unclear),
        ("", .unclear),
    ])
    func wordList(reply: String, expected: ReplyVerdict) {
        #expect(ReplyJudge.wordList(reply) == expected)
    }

    @Test func spokenTextIsOneTidyLine() {
        #expect(SpokenText.clean("  Opening\n  Chrome \t now ", limit: 100) == "Opening Chrome now")
        #expect(SpokenText.clean("abcdefghij", limit: 5) == "abcd…")
        #expect(SpokenText.soFar([]) == "It had only just started.")
        #expect(SpokenText.soFar(["a", "b.", "c", "d"]) == "So far: b; c; d.")
        #expect(SpokenText.duration(180) == "3 minutes")
        #expect(SpokenText.duration(60) == "1 minute")
        #expect(SpokenText.duration(45) == "45 seconds")
        #expect(SpokenText.fallbackQuestion(forAction: "Press Return in WhatsApp.") == "Is it OK to press Return in WhatsApp?")
    }
}
