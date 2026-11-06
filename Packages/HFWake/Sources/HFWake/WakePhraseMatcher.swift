import Foundation

/// How sure the matcher must be before it wakes the Mac.
///
/// The two mistakes cost different things. A false wake opens a paid conversation and could act
/// on a sentence nobody meant as a command. A missed wake leaves someone who cannot use their
/// hands unable to get the computer's attention at all, which is worse, so the default leans
/// towards hearing the phrase, but never wakes on the name alone in the middle of a sentence.
public enum WakeStrictness: String, Sendable, CaseIterable {
    /// Only the phrase as spelled (ignoring case, punctuation and spacing), or one of the
    /// alternative phrases. Fewest false wakes, most missed ones.
    case strict
    /// The default. The name may be misheard by a sound or so ("hands free", "hans free"), and the
    /// lead-in word may be misheard ("hay", "a") when it starts a sentence. The name on its own
    /// never wakes it: "I use hands free in the car" does nothing.
    case balanced
    /// For speech the recogniser struggles with. Wider tolerance on the name, and the lead-in may
    /// be left out when the name starts a sentence. Wakes more often by mistake.
    case lenient
}

/// What the matcher found: which phrase, and what the user said after it.
public struct WakeMatch: Sendable, Equatable {
    /// The configured phrase that matched, as configured ("Hey Handsfree").
    public let phrase: String
    /// The words of the transcript that were taken as the phrase ("hey hands free").
    public let heardAs: String
    /// Everything after the phrase ("open Spotify"), or "" when the phrase was said on its own.
    public let restOfSentence: String
}

/// Decides whether a transcript contains the wake phrase, and returns the rest of the sentence.
///
/// Pure text in, answer out: no audio, no clock, no state. That is what makes it testable, and
/// it is where most of the quality of waking lives, because a recogniser does not write the
/// phrase the way it is spelled. "Hey Handsfree" comes back as "hey hands free", "Hey, hands-free.",
/// "hay handsfree" or "a hands free".
///
/// How it decides, for a phrase such as "Hey Handsfree":
/// 1. The phrase is split into a **lead-in** ("hey", any greeting word) and a **name** ("handsfree").
///    A phrase that does not start with a greeting ("Computer", "Wake up Mac") is all name.
/// 2. The transcript is lower-cased, accents and punctuation are dropped, and it is split into words.
/// 3. At each word, the matcher looks for the lead-in, then the name. The name is compared with
///    the spaces taken out, so "hands free", "hands-free" and "handsfree" are the same thing, and
///    by **sound**: each word is turned into a rough sound key (vowels merged, "ph" as "f", doubled
///    letters merged) and the keys may differ by a small number of edits depending on strictness.
/// 4. The lead-in is "strong" when it is the configured lead-in or a spelling of it ("hay" for
///    "hey", "ok" for "okay"); a strong lead-in counts anywhere. It is "weak" when it is a likely
///    mishearing or another greeting ("a", "he", "high", "oh" for "okay", "hi"); at balanced a weak
///    lead-in counts only at the start of a sentence **and** when the name is followed by a pause
///    mark or the end of the transcript, the way a recogniser writes someone being addressed
///    ("A hands free. Open Spotify.", "High hands-free, open Safari."). So "I bought a hands free
///    kit" and "A hands-free kit is the law now" do not wake it.
/// 5. The name never spans a pause mark: "Hey Hans, free on Friday?" is not "Hey Handsfree".
public struct WakePhraseMatcher: Sendable {
    public let phrases: [String]
    public let strictness: WakeStrictness
    private let parsed: [ParsedPhrase]

    /// - Parameters:
    ///   - phrase: the main wake phrase, e.g. "Hey Handsfree".
    ///   - alternatives: other phrases that also wake it, for a user who cannot say the main one
    ///     reliably, or whose speech the recogniser often writes in a particular wrong way.
    ///   - strictness: see `WakeStrictness`.
    public init(phrase: String, alternatives: [String] = [], strictness: WakeStrictness = .balanced) {
        let all = ([phrase] + alternatives).filter { !Self.words(of: $0).isEmpty }
        self.phrases = all
        self.strictness = strictness
        self.parsed = all.compactMap(ParsedPhrase.init)
    }

    /// The earliest occurrence of any configured phrase in `transcript`, or nil.
    public func match(_ transcript: String) -> WakeMatch? {
        let tokens = Self.tokenize(transcript)
        guard !tokens.isEmpty else { return nil }
        var best: (start: Int, end: Int, phrase: ParsedPhrase)?
        for phrase in parsed {
            for start in tokens.indices {
                if let end = matchEnd(of: phrase, in: tokens, at: start) {
                    if best == nil || start < best!.start { best = (start, end, phrase) }
                    break
                }
            }
        }
        guard let best else { return nil }
        let heardAs = tokens[best.start..<best.end].map(\.normalized).joined(separator: " ")
        var rest = Self.clean(String(transcript[tokens[best.end - 1].range.upperBound...]))
        // "Hey Handsfree, hey Handsfree, open Spotify": drop the repeats.
        for _ in 0..<3 {
            let restTokens = Self.tokenize(rest)
            guard !restTokens.isEmpty,
                let end = parsed.lazy.compactMap({ self.matchEnd(of: $0, in: restTokens, at: 0) }).first
            else { break }
            rest = Self.clean(String(rest[restTokens[end - 1].range.upperBound...]))
        }
        return WakeMatch(phrase: best.phrase.original, heardAs: heardAs, restOfSentence: rest)
    }

    // MARK: Matching one phrase at one position

    /// Where the phrase ends (exclusive token index) if it starts at `start`, else nil.
    private func matchEnd(of phrase: ParsedPhrase, in tokens: [Token], at start: Int) -> Int? {
        var position = start
        /// The lead-in was only a likely mishearing, or left out: ask for a pause after the name.
        var needsPauseAfterName = false
        if let leadIn = phrase.leadIn {
            switch leadInStrength(tokens[position].normalized, leadIn: leadIn) {
            case .strong:
                position += 1
            case .weak where tokens[position].startsSentence:
                position += 1
                needsPauseAfterName = strictness == .balanced
            default:
                // Lenient only: the lead-in may be left out when the name starts a sentence.
                guard strictness == .lenient, tokens[position].startsSentence else { return nil }
                needsPauseAfterName = true
            }
            // "Hey, um, Handsfree"
            while position < tokens.count, Self.fillers.contains(tokens[position].normalized) { position += 1 }
            guard position < tokens.count else { return nil }
        }
        guard let end = nameEnd(phrase, in: tokens, at: position) else { return nil }
        if needsPauseAfterName, end < tokens.count, !tokens[end].precededByPause { return nil }
        return end
    }

    /// The name is compared with the spaces taken out, across one to a few transcript words,
    /// and the closest fit wins.
    private func nameEnd(_ phrase: ParsedPhrase, in tokens: [Token], at start: Int) -> Int? {
        let maxWords = min(tokens.count - start, phrase.nameWordCount + 2)
        guard maxWords > 0 else { return nil }
        var bestEnd: Int?
        var bestDistance = Int.max
        var compact = ""
        for count in 1...maxWords {
            // The name does not run across a pause: "Hey Hans, free on Friday?"
            if count > 1, tokens[start + count - 1].precededByPause { break }
            compact += tokens[start + count - 1].normalized
            let distance: Int
            // The sound key merges vowels, so short names ("Max", "Mix") must match letter for letter.
            let exactLettersOnly = strictness == .strict || (strictness == .balanced && phrase.nameKey.count < 5)
            switch strictness {
            case _ where exactLettersOnly:
                distance = compact == phrase.compactName ? 0 : Int.max
            case .strict, .balanced, .lenient:
                let key = Self.soundKey(compact)
                distance = Self.editDistance(key, phrase.nameKey)
            }
            if distance < bestDistance {
                bestDistance = distance
                bestEnd = start + count
            }
        }
        guard let bestEnd, bestDistance <= allowedEdits(forKeyLength: phrase.nameKey.count) else { return nil }
        return bestEnd
    }

    /// How many sound edits the name may be off by. Short names get none, so "Max" never matches
    /// "Mix"; "handsfree" (sound key "h*ndsfr*", eight long) gets one at balanced, two at lenient.
    func allowedEdits(forKeyLength length: Int) -> Int {
        switch strictness {
        case .strict: return 0
        case .balanced: return length >= 5 ? max(1, length / 6) : 0
        case .lenient: return length >= 4 ? max(1, length / 3) : (length >= 2 ? 1 : 0)
        }
    }

    private enum LeadInStrength { case strong, weak, none }

    private func leadInStrength(_ word: String, leadIn: String) -> LeadInStrength {
        if word == leadIn || Self.equivalentLeadIns[leadIn]?.contains(word) == true { return .strong }
        if strictness == .strict { return .none }
        if Self.soundSpellings[leadIn]?.contains(word) == true { return .strong }
        let wordKey = Self.soundKey(word)
        let leadKey = Self.soundKey(leadIn)
        // Another greeting ("hi", "hello" for "hey"): strong only at lenient. People do say "Hi
        // Handsfree", but "Hi, hands free calling works" is ordinary speech.
        if Self.greetings.contains(word) { return strictness == .lenient ? .strong : .weak }
        // Sounds the same but is an ordinary word ("he" for "hey"), a dropped "h" ("a", "ay"),
        // or a common mishearing of a greeting.
        if wordKey == leadKey { return .weak }
        if leadKey.hasPrefix("h"), wordKey == String(leadKey.dropFirst()) { return .weak }
        // Cut short: "okay" heard as "oh" (seen on this Mac).
        if !wordKey.isEmpty, wordKey.count < leadKey.count, leadKey.hasPrefix(wordKey) { return .weak }
        if Self.weakLeadIns.contains(word) || Self.mishearings[leadIn]?.contains(word) == true { return .weak }
        // Lenient: anything a sound away from the lead-in, still only at the start of a sentence.
        if strictness == .lenient, Self.editDistance(wordKey, leadKey) <= 1 { return .weak }
        return .none
    }

    // MARK: Vocabulary

    /// Words that, at the start of a phrase, make it a lead-in rather than part of the name.
    static let greetings: Set<String> = ["hey", "hi", "hello", "hiya", "ok", "okay", "yo", "oi", "hay"]
    /// Spellings that are the same lead-in even at strict.
    static let equivalentLeadIns: [String: Set<String>] = ["ok": ["okay"], "okay": ["ok"]]
    /// How recognisers spell the same sound. As good as the lead-in itself, except at strict.
    static let soundSpellings: [String: Set<String>] = ["hey": ["hay"], "hay": ["hey"]]
    /// Likely mishearings of a short greeting. Only trusted at the start of a sentence.
    static let weakLeadIns: Set<String> = ["a", "eh", "ay", "uh", "hae", "heh"]
    /// How Apple's recogniser wrote a lead-in on this Mac, beyond what the sound rules catch.
    /// "Hey" from a British voice came back as "Pay".
    static let mishearings: [String: Set<String>] = ["hey": ["pay"]]
    /// Hesitations that may sit between the lead-in and the name.
    static let fillers: Set<String> = ["uh", "um", "umm", "er", "erm", "ah", "hmm"]

    // MARK: Text handling

    struct Token {
        let normalized: String
        let range: Range<String.Index>
        /// First word of the transcript, or the first after a full stop, question or exclamation mark.
        let startsSentence: Bool
        /// A pause mark (comma, full stop, colon, dash...) sits between this word and the one before.
        let precededByPause: Bool
    }

    /// What a recogniser writes for a pause. A hyphen is not one: "hands-free" is one name.
    static let pauseMarks: Set<Character> = [",", ".", ";", ":", "!", "?", "\u{2026}", "\u{2013}", "\u{2014}"]

    /// Splits into words of letters and digits. Apostrophes inside a word are dropped ("hey's"
    /// becomes "heys"), everything else separates words, so "hands-free" is two words.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var wordStart: String.Index?
        var sentenceBoundary = true
        var pause = false
        var index = text.startIndex
        func finish(at end: String.Index) {
            guard let start = wordStart else { return }
            let raw = String(text[start..<end])
            let normalized = normalize(raw)
            if !normalized.isEmpty {
                tokens.append(Token(
                    normalized: normalized, range: start..<end, startsSentence: sentenceBoundary,
                    precededByPause: pause))
                sentenceBoundary = false
                pause = false
            }
            wordStart = nil
        }
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let isApostropheInWord =
                (character == "'" || character == "\u{2019}") && wordStart != nil
                && next < text.endIndex && text[next].isLetter
            // "o.k." stays one word: a full stop between single letters is not a boundary, but
            // "hey.open" is two words.
            let afterNext = next < text.endIndex ? text.index(after: next) : text.endIndex
            let isDotInAbbreviation =
                character == "." && wordStart != nil && next < text.endIndex && text[next].isLetter
                && (afterNext == text.endIndex || !text[afterNext].isLetter)
                && text[text.index(before: index)].isLetter
                && (text.index(before: index) == wordStart! || text[text.index(index, offsetBy: -2)] == ".")
            if character.isLetter || character.isNumber || isApostropheInWord || isDotInAbbreviation {
                if wordStart == nil { wordStart = index }
            } else {
                finish(at: index)
                if character == "." || character == "!" || character == "?" { sentenceBoundary = true }
                if pauseMarks.contains(character) { pause = true }
            }
            index = next
        }
        finish(at: text.endIndex)
        return tokens
    }

    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func words(of phrase: String) -> [String] { tokenize(phrase).map(\.normalized) }

    /// Drops the spaces and punctuation the recogniser puts around the rest of the sentence.
    static func clean(_ rest: String) -> String {
        var text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let edge = CharacterSet(charactersIn: ",.;:!-\u{2013}\u{2014}\u{2026}").union(.whitespacesAndNewlines)
        text = text.trimmingCharacters(in: edge)
        // A lone "?" after "Hey hands-free?" is punctuation, not something the user said.
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    /// A rough key for how a word sounds, so that spellings of the same sound compare equal and
    /// near sounds compare close. Not a real phonetic algorithm: just enough for English
    /// recogniser output. "handsfree" → "h*ndsfr*", "hey" → "h*", "hay" → "h*".
    static func soundKey(_ word: String) -> String {
        // Recognisers write numbers as digits: "Hey Hands 3" is "hey hands three".
        let spoken = word.lowercased().map { Self.digitWords[$0] ?? String($0) }.joined()
        var letters = Array(spoken.filter { $0.isLetter })
        var output: [Character] = []
        var index = 0
        while index < letters.count {
            let character = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            switch (character, next) {
            case ("p", "h"): output.append("f"); index += 2; continue
            case ("c", "k"): output.append("k"); index += 2; continue
            case ("w", "h"): output.append("w"); index += 2; continue
            case ("t", "h"): output.append("t"); index += 2; continue
            // A silent "gh" after a vowel: "high" sounds like "hi", "though" like "tho".
            case ("g", "h") where index > 0 && "aeiouy".contains(letters[index - 1]): index += 2; continue
            // An "h" after a vowel and not before one is silent: "oh", "ah", "eh".
            case ("h", let following) where index > 0 && "aeiou".contains(letters[index - 1])
                && !(following.map { "aeiouy".contains($0) } ?? false):
                index += 1; continue
            case ("q", _): output.append("k")
            case ("x", _): output.append(contentsOf: ["k", "s"])
            case ("z", _): output.append("s")
            case ("c", let following?) where "eiy".contains(following): output.append("s")
            case ("c", _): output.append("k")
            case ("y", _) where index > 0: output.append("*")
            case (let vowel, _) where "aeiou".contains(vowel): output.append("*")
            default: output.append(character)
            }
            index += 1
        }
        letters = []
        for character in output where letters.last != character { letters.append(character) }
        return String(letters)
    }

    static let digitWords: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    /// Levenshtein distance: the fewest single-character insertions, deletions or substitutions.
    static func editDistance(_ first: String, _ second: String) -> Int {
        let left = Array(first), right = Array(second)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            for rightIndex in 1...right.count {
                let substitution = previous[rightIndex - 1] + (left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1)
                current[rightIndex] = min(previous[rightIndex] + 1, current[rightIndex - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    /// A configured phrase, split into its lead-in and its name.
    private struct ParsedPhrase: Sendable {
        let original: String
        let leadIn: String?
        let compactName: String
        let nameKey: String
        let nameWordCount: Int

        init?(_ phrase: String) {
            let words = WakePhraseMatcher.words(of: phrase)
            guard !words.isEmpty else { return nil }
            original = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasLeadIn = words.count >= 2 && WakePhraseMatcher.greetings.contains(words[0])
            leadIn = hasLeadIn ? words[0] : nil
            let nameWords = hasLeadIn ? Array(words.dropFirst()) : words
            compactName = nameWords.joined()
            nameKey = WakePhraseMatcher.soundKey(compactName)
            nameWordCount = nameWords.count
        }
    }
}
