import Testing
@testable import HFUnderstand

@Suite struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        #expect(WordErrorRate.rate(reference: "message mum", hypothesis: "message mum") == 0)
    }

    @Test func caseAndPunctuationAreIgnored() {
        #expect(WordErrorRate.rate(reference: "Message Mum.", hypothesis: "message, mum!") == 0)
        #expect(WordErrorRate.matches("Don't ask me", "dont ask me"))
    }

    @Test func oneSubstitutionInTwoWordsIsHalf() {
        let count = WordErrorRate.count(reference: "Message Mum", hypothesis: "message some")
        #expect(count == .init(errors: 1, referenceWords: 2))
        #expect(count.rate == 0.5)
    }

    @Test func insertionsAndDeletionsCount() {
        // One word dropped.
        #expect(WordErrorRate.count(reference: "the quick brown fox", hypothesis: "the brown fox").errors == 1)
        // Two words added: WER can exceed 1.
        let added = WordErrorRate.count(reference: "yes", hypothesis: "yes yes please")
        #expect(added.errors == 2)
        #expect(added.rate == 2)
    }

    @Test func emptyHypothesisIsAllDeletions() {
        #expect(WordErrorRate.rate(reference: "scroll down", hypothesis: "") == 1)
    }

    @Test func emptyReferenceDoesNotDivideByZero() {
        #expect(WordErrorRate.rate(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.rate(reference: "", hypothesis: "hello") == 1)
    }

    @Test func whitespaceCollapses() {
        #expect(WordErrorRate.normalise("  open \n  WhatsApp  ") == "open whatsapp")
    }

    @Test func digitsFoldToWords() {
        #expect(WordErrorRate.normalise("Call 2 people at 3pm") == "call two people at three pm")
        #expect(WordErrorRate.normalise("21") == "twenty one")
        #expect(WordErrorRate.normalise("100") == "one hundred")
        #expect(WordErrorRate.normalise("1905") == "one thousand nine hundred five")
        #expect(WordErrorRate.matches("seven", "7"))
    }

    @Test func countsAddUp() {
        let total = WordErrorRate.count(reference: "a b", hypothesis: "a c") + WordErrorRate.count(reference: "d e f", hypothesis: "d e f")
        #expect(total == .init(errors: 1, referenceWords: 5))
        #expect(total.rate == 0.2)
    }

    @Test func editDistanceIsSymmetricForSubstitutions() {
        #expect(WordErrorRate.editDistance(["a", "b", "c"], ["x", "b", "y"]) == 2)
        #expect(WordErrorRate.editDistance([], ["a"]) == 1)
    }
}
