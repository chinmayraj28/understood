import Foundation
import HFCore

/// Everything the decider looks at for one turn.
public struct DecisionInput: Sendable, Equatable {
    /// What each recogniser heard, including failed ones (empty text, `failure` set).
    public var hypotheses: [Hypothesis]
    /// The closest phrasebook entry from any recogniser. A hint for logs and repair only.
    public var phrasebookMatch: PhrasebookMatch?
    /// Each recogniser's closest pair among the pairs it stored itself
    /// (`Phrasebook.matchesByHearer`). Only these can let the decider act.
    public var phrasebookMatchesByHearer: [HearerName: PhrasebookMatch]
    /// The keyterms the recognisers were given. Agreement on a hinted name needs Apple's
    /// hint-free transcript as well.
    public var hintedTerms: [String]
    /// What Apple's recogniser heard live, with no hints (`RecordedTurn.liveTranscript`).
    public var liveTranscript: String
    /// The repair stage's reading. Nil when repair was skipped (fast path) or failed.
    public var reading: Reading?
    public var context: UnderstandingContext
    /// How many turns in a row ended without the person being understood.
    public var failedTries: Int

    public init(
        hypotheses: [Hypothesis], phrasebookMatch: PhrasebookMatch? = nil,
        phrasebookMatchesByHearer: [HearerName: PhrasebookMatch] = [:], reading: Reading? = nil,
        context: UnderstandingContext = .init(), failedTries: Int = 0, hintedTerms: [String] = [], liveTranscript: String = ""
    ) {
        self.hypotheses = hypotheses
        self.phrasebookMatch = phrasebookMatch
        self.phrasebookMatchesByHearer = phrasebookMatchesByHearer
        self.hintedTerms = hintedTerms
        self.liveTranscript = liveTranscript
        self.reading = reading
        self.context = context
        self.failedTries = failedTries
    }
}

/// Decides, in code, whether to act on a turn or ask first. See docs/SPEECH_PLAN.md, stage 4.
///
/// Why code and not the prompt: the rule "ask when unsure" must hold when the model is wrong.
/// A person who cannot use their hands cannot undo a wrong action, so Claude's confidence is
/// never enough on its own: a reading is acted on only when the recognisers or the phrasebook
/// back it up word for word.
public enum Decider {
    /// A phrasebook entry this close to what was heard (0...1)...
    public static let strongMatchSimilarity = 0.9
    /// ...and confirmed at least this often is trusted like an agreeing recogniser. Two, so
    /// one lucky confirmation is not enough: the first time a garble is learned the person is
    /// asked once more, and from the second time on it simply works.
    public static let strongMatchConfirmations = 2
    /// After this many failed tries in a row, only yes/no questions are asked: they are the
    /// easiest to say and the most reliably heard.
    public static let yesNoOnlyAfterFailedTries = 2
    /// What is said when nothing usable was heard.
    public static let cannotHearMessage = "I can't hear properly right now."
    /// Single words that always act at once. Stopping is always safe, so it is never delayed.
    public static let stopWords: Set<String> = ["stop", "cancel"]

    /// The decision for one turn. The rules run in order; the first that applies wins.
    public static func decide(_ input: DecisionInput) -> UnderstandingDecision {
        let heard = input.hypotheses.filter { !SpeechText.words($0.text).isEmpty }
        // 1. Nothing usable from any recogniser.
        guard !heard.isEmpty else { return .cannotHear(message: cannotHearMessage) }

        // 2. "Stop" from any recogniser, or from the reading, acts immediately.
        for text in heard.map(\.text) + [input.reading?.text ?? ""] {
            if let stop = stopCommand(in: text) { return .act(text: stop) }
        }

        // 3. Answering a question with fixed answers, when the evidence is clean (see
        //    `trustedExpectedAnswer`: Scribe among the hearers, no other answer, no negation).
        if let answer = trustedExpectedAnswer(heard, input: input) {
            return .act(text: answer)
        }

        let agreed = agreedText(heard, input: input)
        let strongMatch = trustedPhrasebookMatch(heard, byHearer: input.phrasebookMatchesByHearer)
        let scribeHeard = heard.contains { $0.hearer == .scribe }
        let mayChoose = input.failedTries < yesNoOnlyAfterFailedTries
        let mayAskAgain = input.failedTries == 0  // "say it again" is asked at most once in a row

        // 4. No reading (fast path, or Claude was down): agreement or the phrasebook may act;
        //    otherwise confirm what the main recogniser heard.
        guard let reading = input.reading, !SpeechText.words(reading.text).isEmpty else {
            if let strongMatch { return .act(text: strongMatch.meant) }
            if let agreed { return .act(text: agreed) }
            let best = heard.first { $0.hearer == .scribe } ?? heard[0]
            return confirm(best.text)
        }

        // 5. A reading. High confidence acts only when the evidence says the same words, and only
        //    with the main recogniser working (with Scribe down, everything above low asks).
        let readingWords = SpeechText.contentWords(reading.text)
        let backedByAgreement = agreed.map { SpeechText.contentWords($0) == readingWords } ?? false
        let backedByPhrasebook = strongMatch.map { SpeechText.contentWords($0.meant) == readingWords } ?? false
        if reading.confidence == .high, scribeHeard, backedByAgreement || backedByPhrasebook {
            return .act(text: reading.text)
        }
        if reading.confidence >= .medium { return confirm(reading.text) }

        // 6. Low confidence: offer the likely readings, or ask for it once more, or (after
        //    repeated failures) fall back to a yes/no question about the best guess.
        let options = distinctOptions([reading.text] + reading.alternatives)
        if options.count >= 2, mayChoose {
            return .choose(question: choiceQuestion(options), options: options)
        }
        if mayAskAgain { return .askAgain(question: askAgainQuestion(heard)) }
        return confirm(reading.text)
    }

    /// True when a phrasebook match is close enough, and confirmed often enough, to be considered.
    /// The decider also checks who heard it and what else was heard (`trustedPhrasebookMatch`).
    public static func isStrong(_ match: PhrasebookMatch?) -> Bool {
        guard let match else { return false }
        return match.similarity >= strongMatchSimilarity && match.timesConfirmed >= strongMatchConfirmations
    }

    /// "stop" or "cancel" when the whole turn is just that word (repeats allowed: "stop stop").
    public static func stopCommand(in text: String) -> String? {
        let words = SpeechText.words(text)
        guard let first = words.first, stopWords.contains(first), Set(words).count == 1 else { return nil }
        return first
    }

    // MARK: - Building questions

    /// "Message Mum?": the reading with a capital and a question mark, nothing else.
    static func confirm(_ text: String) -> UnderstandingDecision {
        .confirm(question: questionForm(text), reading: text)
    }

    static func questionForm(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?,;:".contains(last) { trimmed.removeLast() }
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst() + "?"
    }

    /// "Mum or Sam?" for ["message Mum", "message Sam"]: only the words that differ are said.
    static func choiceQuestion(_ options: [String]) -> String {
        let parts = distinguishingParts(options)
        let spoken = parts.count <= 2
            ? parts.joined(separator: " or ")
            : parts.dropLast().joined(separator: ", ") + " or " + parts[parts.count - 1]
        return questionForm(spoken)
    }

    /// Each option with the words all options share at the start and the end removed. When that
    /// would leave an option empty ("call Sam" against "call Sam now"), the full options are kept.
    static func distinguishingParts(_ options: [String]) -> [String] {
        let split = options.map { $0.split(separator: " ").map(String.init) }
        guard split.count >= 2, let shortest = split.map(\.count).min() else { return options }
        let same: (Int, Bool) -> Bool = { offset, fromEnd in
            let words = split.map { SpeechText.normalise(fromEnd ? $0[$0.count - 1 - offset] : $0[offset]) }
            return Set(words).count == 1
        }
        var prefix = 0
        while prefix < shortest, same(prefix, false) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, same(suffix, true) { suffix += 1 }
        let parts = split.map { $0[prefix..<($0.count - suffix)].joined(separator: " ") }
        return parts.contains(where: \.isEmpty) ? options : parts
    }

    /// Readings that differ once normalised, most likely first, at most three.
    static func distinctOptions(_ candidates: [String]) -> [String] {
        var seen: Set<String> = [], options: [String] = []
        for candidate in candidates {
            let key = SpeechText.normalise(candidate)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            options.append(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Array(options.prefix(3))
    }

    /// "Message what? Say just that part." when every recogniser caught the same first word;
    /// otherwise a plain request to say it once more.
    static func askAgainQuestion(_ heard: [Hypothesis]) -> String {
        let firstWords = heard.map { $0.text.split(separator: " ").first.map(String.init) ?? "" }
        if heard.count >= 2, let first = firstWords.first, !first.isEmpty,
            Set(firstWords.map(SpeechText.normalise)).count == 1, !SpeechText.fillerWords.contains(SpeechText.normalise(first))
        {
            let word = first.trimmingCharacters(in: .punctuationCharacters)
            return word.prefix(1).uppercased() + word.dropFirst().lowercased() + " what? Say just that part."
        }
        return "Sorry, say it once more?"
    }
}
