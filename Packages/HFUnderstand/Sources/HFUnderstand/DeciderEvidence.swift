import Foundation
import HFCore

// The evidence rules the decider uses before it may act without asking. Each one closes a way
// a wrong reading could become an action: recognisers out-voting the main one, a phrasebook
// pair from one recogniser being used for another's transcript, a one-word negation, and
// hints that push two recognisers into agreeing on the same hinted name.
extension Decider {
    /// Another recogniser's transcript this close to a phrasebook meaning supports it.
    public static let supportSimilarity = 0.8

    // MARK: - Fixed answers

    /// The expected answer to act on, or nil (then the turn is confirmed instead). All must hold:
    /// - two or more recognisers heard it, Scribe among them;
    /// - no recogniser heard a different expected answer;
    /// - no recogniser heard a negation the answer does not itself contain ("not Mum", "yes, don't");
    /// - when the answer was given to the recognisers as a hint, Apple's hint-free transcript agrees.
    static func trustedExpectedAnswer(_ heard: [Hypothesis], input: DecisionInput) -> String? {
        let expected = input.context.expectedAnswers
        guard !expected.isEmpty else { return nil }
        let winners = expected.filter { answer in
            let matching = heard.filter { matches($0.text, answer: answer, among: expected) }
            return matching.count >= 2 && matching.contains { $0.hearer == .scribe }
        }
        guard winners.count == 1, let answer = winners.first else { return nil }
        let answerWords = Set(SpeechText.words(answer))
        for hypothesis in heard {
            if expected.contains(where: { $0 != answer && matches(hypothesis.text, answer: $0, among: expected) }) { return nil }
            let negations = Set(SpeechText.words(hypothesis.text)).intersection(SpeechText.negationWords)
            if !negations.subtracting(answerWords).isEmpty { return nil }
        }
        if isHintBiased(answer, input: input) {
            guard let independent = independentTranscript(input),
                matches(independent, answer: answer, among: expected)
            else { return nil }
        }
        return answer
    }

    /// True when `text` is the answer itself, or just the part that tells it apart from the
    /// others: "Sam" answers "message Mum or message Sam?". Filler words are ignored ("yes please").
    static func matches(_ text: String, answer: String, among answers: [String]) -> Bool {
        let heardWords = SpeechText.contentWords(text)
        guard !heardWords.isEmpty else { return false }
        if heardWords == SpeechText.contentWords(answer) { return true }
        guard let index = answers.firstIndex(of: answer) else { return false }
        return heardWords == SpeechText.contentWords(distinguishingParts(answers)[index])
    }

    // MARK: - Agreement

    /// The agreed text when at least two recognisers, Scribe among them, heard the same content
    /// words and none heard different ones. Returns Scribe's wording. When the agreed words
    /// include a hinted name or expected answer, Apple's hint-free transcript must agree too,
    /// because the hints alone can make Scribe and Gemini agree on the wrong name.
    static func agreedText(_ heard: [Hypothesis], input: DecisionInput) -> String? {
        let usable = heard.filter { !SpeechText.words($0.text).isEmpty }
        guard usable.count >= 2, let scribe = usable.first(where: { $0.hearer == .scribe }) else { return nil }
        let scribeWords = SpeechText.contentWords(scribe.text)
        guard !scribeWords.isEmpty, usable.allSatisfy({ SpeechText.contentWords($0.text) == scribeWords }) else { return nil }
        if isHintBiased(scribe.text, input: input) {
            guard let independent = independentTranscript(input), SpeechText.contentWords(independent) == scribeWords else { return nil }
        }
        return scribe.text
    }

    /// Words the recognisers were pushed towards: capitalised words in the hints (names, apps,
    /// screen labels) and the words of any expected answer that was given as a hint.
    static func hintedWords(_ input: DecisionInput) -> Set<String> {
        let answers = Set(input.context.expectedAnswers.map(SpeechText.normalise))
        var words: Set<String> = []
        for term in input.hintedTerms {
            if answers.contains(SpeechText.normalise(term)) { words.formUnion(SpeechText.contentWords(term)) }
            for raw in term.split(separator: " ") where raw.first?.isUppercase == true {
                words.formUnion(SpeechText.words(String(raw)))
            }
        }
        return words.subtracting(SpeechText.fillerWords)
    }

    static func isHintBiased(_ text: String, input: DecisionInput) -> Bool {
        !Set(SpeechText.contentWords(text)).isDisjoint(with: hintedWords(input))
    }

    /// Apple's live transcript (heard while the person spoke, with no hints), or, for a turn from
    /// a file, Apple's own hypothesis. Nil when there is neither.
    static func independentTranscript(_ input: DecisionInput) -> String? {
        if !SpeechText.words(input.liveTranscript).isEmpty { return input.liveTranscript }
        return input.hypotheses.first { $0.hearer == .apple && !SpeechText.words($0.text).isEmpty }?.text
    }

    // MARK: - Phrasebook

    /// The phrasebook match the decider may act on, or nil. All must hold:
    /// - a recogniser's transcript matches a pair **that recogniser** stored, strongly (`isStrong`);
    /// - that transcript and the stored text have the same negations, digits and names;
    /// - every other recogniser that heard something supports the meaning: it heard the same
    ///   garble, or its own stored pair means the same, or it is close to the meaning itself.
    /// Scribe's match is tried first.
    static func trustedPhrasebookMatch(_ heard: [Hypothesis], byHearer: [HearerName: PhrasebookMatch]) -> PhrasebookMatch? {
        let ordered = heard.sorted { ($0.hearer == .scribe ? 0 : 1) < ($1.hearer == .scribe ? 0 : 1) }
        for candidate in ordered {
            guard let match = byHearer[candidate.hearer], isStrong(match) else { continue }
            let names = SpeechText.names(in: candidate.text).union(SpeechText.names(in: match.heard))
                .union(SpeechText.names(in: match.meant))
            guard SpeechText.keyWordsAgree(candidate.text, match.heard, names: names) else { continue }
            let others = heard.filter { $0.hearer != candidate.hearer }
            if others.allSatisfy({ supports($0, meaning: match, byHearer: byHearer, names: names) }) { return match }
        }
        return nil
    }

    static func supports(_ hypothesis: Hypothesis, meaning match: PhrasebookMatch, byHearer: [HearerName: PhrasebookMatch], names: Set<String>) -> Bool {
        let text = hypothesis.text
        let allNames = names.union(SpeechText.names(in: text))
        // The same garble the trusted recogniser heard.
        if SpeechText.similarity(text, match.heard) >= strongMatchSimilarity,
            SpeechText.keyWordsAgree(text, match.heard, names: allNames) { return true }
        // Its own stored pair, for the same meaning.
        if let own = byHearer[hypothesis.hearer], SpeechText.normalise(own.meant) == SpeechText.normalise(match.meant),
            own.similarity >= strongMatchSimilarity, SpeechText.keyWordsAgree(text, own.heard, names: allNames) { return true }
        // Close to the meaning itself.
        return SpeechText.similarity(text, match.meant) >= supportSimilarity
            && SpeechText.keyWordsAgree(text, match.meant, names: allNames)
    }
}
