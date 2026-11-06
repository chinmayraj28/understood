import Foundation
import HFCore

/// A fact a rule or a model proposes to learn, before it is checked and stored.
public struct ProposedFact: Sendable, Equatable {
    public var kind: FactKind
    public var key: String
    public var value: String
    public var scope: String

    public init(kind: FactKind, key: String, value: String, scope: String = "") {
        self.kind = kind
        self.key = key
        self.value = value
        self.scope = scope
    }
}

/// The rules that decide, without any model, what must never be learned from a
/// question and answer, and the one rule that learns name choices by itself.
/// docs/MEMORY.md, Part B section 8.1.
public enum ExchangeRules {
    /// Why an exchange is never learned from.
    public enum NeverLearnReason: String, Sendable {
        case empty
        case confirmation
        case cancel
        case yesNoAnswer = "yes/no answer"
        case messageWording = "message wording"
        case secret
    }

    private static let risky = Pattern(
        #"\b(send|pay|buy|purchase|order|delete|remove|submit|post|invite|share|publish|transfer|confirm|accept)\b"#,
        caseInsensitive: true)
    private static let cancelAnswer = Pattern(#"^\s*(stop|cancel|abort|never ?mind|forget it|leave it)\b"#,
                                              caseInsensitive: true)
    private static let contentQuestion = Pattern(
        #"\b(what should (it|the message|the email|the reply|the text|i|we) (say|write)|what (do you want|would you like) (me )?to (say|write|reply)|what('s| is) the message|message (text|body|wording)|subject line|what should i write|how should i word|wording|what do you want to tell)\b"#,
        caseInsensitive: true)
    private static let yesNoQuestion = Pattern(
        #"^\s*(do|does|did|is|are|was|were|should|shall|can|could|would|will|may|want|ready|ok|okay|send|post|pay|buy|delete|submit|share|invite|confirm|go ahead)\b"#,
        caseInsensitive: true)
    private static let openQuestion = Pattern(#"^\s*(which|who|whom|whose|what|where|when|how)\b"#, caseInsensitive: true)
    private static let offersChoice = Pattern(#"\bor\b(?! not\b)"#, caseInsensitive: true)
    private static let sentenceEnd = Pattern(#"(?<=[.!?])\s+"#)
    private static let statementEnd = Pattern(#"(?<=[.!])\s+"#)
    private static let consentStart = Pattern(
        #"^\s*(yes|yeah|yep|yup|no|nope|nah|sure|ok(ay)?|go ahead|do it|don'?t|please do|absolutely|definitely|correct|right|confirm(ed)?|cancel|stop|never ?mind)\b"#,
        caseInsensitive: true)
    private static let answerWord = Pattern(#"[\w']+"#)
    private static let yesNoWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "y", "no", "nope", "nah", "n", "sure", "ok", "okay", "fine", "please",
        "correct", "right", "go", "ahead", "do", "it", "send", "don't", "dont", "not", "cancel", "stop", "confirm",
        "confirmed", "absolutely", "definitely", "thanks", "thank", "you", "that's", "thats", "that", "is",
        "alright", "never", "mind",
    ]
    static let standingWords = Pattern(
        #"\b(always|usually|normally|by default|from now on|every time|each time|in future|i prefer|i'd rather|i would rather|i like (it|my|to)|i always)\b"#,
        caseInsensitive: true)

    /// Why this exchange must never be learned from, or nil if it may be considered.
    /// The checks run in a fixed order and the first that matches wins.
    public static func neverLearnReason(question: String, answer: String, isConfirmation: Bool = false)
        -> NeverLearnReason?
    {
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .empty
        }
        // A yes to a risky step is never a standing permission.
        if isConfirmation || isConfirmationQuestion(question) { return .confirmation }
        // "Post it or save a draft?" answered "post" is permission too.
        if risky.matches(question) && risky.matches(answer) { return .confirmation }
        if cancelAnswer.matches(answer) { return .cancel }
        if isBareYesNo(answer) { return .yesNoAnswer }
        if contentQuestion.matches(question) { return .messageWording }
        if HardRules.looksSecret(question) || HardRules.looksSecret(answer) { return .secret }
        return nil
    }

    /// "yes", "yes please, send it", "no don't" → true. "Shah" → false.
    public static func isBareYesNo(_ answer: String) -> Bool {
        let words = answerWord.allMatches(answer.lowercased())
        if words.isEmpty || words.allSatisfy(yesNoWords.contains) { return true }
        return consentStart.matches(answer) && words.count <= 6
    }

    /// A question that asks permission for a risky step: "Send it?", "Ready to post this?".
    /// A question that offers a choice ("personal or work account?") or asks which, who or what is not one.
    public static func isConfirmationQuestion(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard risky.matches(trimmed) else { return false }
        let last = sentenceEnd.split(trimmed).last ?? trimmed
        if offersChoice.matches(last) { return false }
        // "Which Priya do you want to invite?" asks who, not whether: it is not a permission.
        // A yes or a risky pick to a question like this is still never learned (the yes/no
        // and risky-answer rules), and the step itself still goes through the safety gate.
        if openQuestion.matches(last) { return false }
        return yesNoQuestion.matches(last) || trimmed.hasSuffix("?")
    }

    // MARK: Name choices

    private static let leadIn = Pattern(#"^\s*(did|do|which|would|should)\b"#, caseInsensitive: true)
    private static let upToChoiceVerb = Pattern(#"^.*?\b(?:mean|want|prefer|like|choose|pick|use|it)\b\s*"#,
                                                caseInsensitive: true)
    private static let optionSeparator = Pattern(#",\s*(?:or\s+)?|\s+or\s+"#)
    private static let answerLeadIn = Pattern(#"^(the|i meant|i mean|it's|its|it is)\s+"#)
    private static let ordinals: [String: Int] = [
        "first": 0, "1st": 0, "one": 0, "second": 1, "2nd": 1, "two": 1, "third": 2, "3rd": 2, "three": 2, "last": -1,
    ]

    /// Pulls "A or B?" or "A, B or C?" out of the last sentence of a question.
    public static func optionsFromQuestion(_ question: String) -> [String] {
        var last = statementEnd.split(question.trimmingCharacters(in: .whitespacesAndNewlines)).last ?? ""
        while last.hasSuffix("?") { last.removeLast() }
        last = last.trimmingCharacters(in: .whitespaces)
        if leadIn.matches(last) {
            if let match = upToChoiceVerb.firstMatch(last) { last = match.after }
        }
        last = (last.components(separatedBy: ":").last ?? last).trimmingCharacters(in: .whitespaces)
        let pieces = optionSeparator.split(last)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
            .filter { !$0.isEmpty }
        return pieces.count >= 2 ? pieces : []
    }

    /// Which option the answer chose, or nil if it is not clear.
    public static func pickOption(answer: String, options: [String]) -> String? {
        var chosen = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = chosen.last, last == "." || last == "!" { chosen.removeLast() }
        if let match = answerLeadIn.firstMatch(chosen) { chosen = match.after }
        if let exact = options.first(where: { $0.lowercased() == chosen }) { return exact }
        let words = Pattern(#"\w+"#).allMatches(chosen)
        for word in words {
            guard let index = ordinals[word], chosen.contains("one") || chosen.split(separator: " ").count <= 2 else {
                continue
            }
            if index >= -options.count && index < options.count {
                return options[index >= 0 ? index : options.count + index]
            }
        }
        let answerTokens = TextRules.tokens(chosen)
        guard !answerTokens.isEmpty else { return nil }
        let hits = options.filter { answerTokens.isSubset(of: TextRules.tokens($0)) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// If the question was "which X?" between options that share a spoken name, the alias
    /// the answer teaches: "Priya Shah or Priya Patel?" → "Shah" teaches "Priya" → "Priya Shah".
    public static func nameChoice(question: String, answer: String, goal: String, options: [String] = [])
        -> ProposedFact?
    {
        // The options the task offered are the truth; reading them out of the question is
        // only the fallback, because questions are worded in many ways.
        let offered = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !offered.isEmpty {
            return aliasFromChoice(offered, question: question, answer: answer, goal: goal)
        }
        let parsed = optionsFromQuestion(question)
        if let proposal = aliasFromChoice(parsed, question: question, answer: answer, goal: goal) { return proposal }
        // "Which Priya do you want to invite, Priya Shah or Priya Patel?" parses as
        // ["to invite", "Priya Shah", "Priya Patel"]: drop a lead-in piece and try again.
        var remaining = parsed
        while remaining.count > 2 {
            remaining.removeFirst()
            if let proposal = aliasFromChoice(remaining, question: question, answer: answer, goal: goal) {
                return proposal
            }
        }
        return nil
    }

    /// The alias a choice between `choices` teaches, if they share a leading spoken name.
    private static func aliasFromChoice(_ choices: [String], question: String, answer: String, goal: String)
        -> ProposedFact?
    {
        guard choices.count >= 2, let chosen = pickOption(answer: answer, options: choices) else { return nil }
        let splitOptions = choices.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        var common: [String] = []
        let shortest = splitOptions.map(\.count).min() ?? 0
        for position in 0..<shortest {
            let words = Set(splitOptions.map { $0[position].lowercased() })
            guard words.count == 1 else { break }
            common.append(splitOptions[0][position])
        }
        guard !common.isEmpty, !splitOptions.allSatisfy({ $0.count == common.count }) else { return nil }
        let key = common.joined(separator: " ")
        guard TextRules.tokens(key).isSubset(of: TextRules.tokens(goal).union(TextRules.tokens(question))) else {
            return nil
        }
        return ProposedFact(kind: .alias, key: key, value: chosen, scope: "")
    }

    /// A proposal may only use what was actually said, and never the message wording.
    /// Alias and preference values must be made of words heard in the exchange, so no
    /// contact name is ever invented.
    public static func isGrounded(_ proposal: ProposedFact, said: String, goal: String) -> Bool {
        let key = proposal.key.trimmingCharacters(in: .whitespaces)
        let value = proposal.value.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, TextRules.tokens(key) != TextRules.tokens(value) else { return false }
        if MessageContent.repeatsMessage(value, goal: goal) { return false }
        if proposal.kind == .alias || proposal.kind == .preference {
            guard TextRules.tokens(value).isSubset(of: TextRules.tokens(said)) else { return false }
        }
        return HardRules.refusalReason(key: key, value: value) == nil
    }
}
