import Foundation
import HFCore

/// How spoken words become lookup keys, and how two texts are compared.
/// docs/MEMORY.md, Part B section 3.
public enum TextRules {
    /// Words dropped from the front of a key: "my mum" is "mum".
    static let fillerWords: Set<String> = ["my", "the", "our", "your", "a", "an"]

    /// Words that never count when matching a goal to a fact.
    static let stopwords: Set<String> = fillerWords.union([
        "to", "of", "and", "or", "in", "on", "at", "for", "with", "is", "are", "be", "it", "me",
        "i", "please", "can", "you", "set", "up", "open", "this", "that", "what", "who", "about",
        "from", "by", "as", "do", "does", "tomorrow", "today", "now", "then", "just",
    ])

    static let maximumKeyLength = 80

    private static let possessive = Pattern(#"'s\b"#)
    private static let notWordOrSpace = Pattern(#"[^\w\s]"#)
    private static let word = Pattern(#"\w+"#)
    private static let controlCharacters = Pattern(#"[\x00-\x1f\x7f]+"#)
    private static let whitespace = Pattern(#"\s+"#)

    /// Turns a spoken key into a lookup key: "My Mum's" → "mum", "Google account" → "google_account".
    /// Also used for scopes: "WhatsApp" → "whatsapp".
    public static func normaliseKey(_ text: String) -> String {
        var working = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        working = possessive.replace(working, with: "")
        working = notWordOrSpace.replace(working, with: " ").replacingOccurrences(of: "_", with: " ")
        var words = working.split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, fillerWords.contains(words[0]) { words.removeFirst() }
        if words.count == 1, fillerWords.contains(words[0]) { words = [] }
        return String(words.joined(separator: "_").prefix(maximumKeyLength))
    }

    /// The meaningful lower-case words of a text, with a light plural strip ("contacts" → "contact").
    public static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased().replacingOccurrences(of: "_", with: " ")
        var result: Set<String> = []
        for found in word.allMatches(lowered) {
            var candidate = found
            if stopwords.contains(candidate) || candidate.count < 2 { continue }
            if candidate.count > 3, candidate.hasSuffix("s"), !candidate.hasSuffix("ss") {
                candidate.removeLast()
            }
            result.insert(candidate)
        }
        return result
    }

    /// One line, trimmed and cut to `limit` characters. Facts end up in prompts,
    /// so they never carry newlines or control characters.
    public static func cleanValue(_ text: String, limit: Int) -> String {
        let flattened = controlCharacters.replace(text, with: " ")
        let collapsed = whitespace.replace(flattened, with: " ").trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(limit))
    }

    /// Cuts a long text at the last whole word that fits, ending it with an ellipsis,
    /// so a note read on every step never ends mid-word.
    static func cutAtWord(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let room = String(text.prefix(limit - 1))
        let cut = room.lastIndex(of: " ").map { String(room[..<$0]) } ?? room
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "\u{2026}"
    }

    /// Jaccard overlap of the two texts' tokens, 0...1.
    static func overlap(_ first: String, _ second: String) -> Double {
        let firstTokens = tokens(first)
        let secondTokens = tokens(second)
        guard !firstTokens.isEmpty, !secondTokens.isEmpty else { return 0 }
        return Double(firstTokens.intersection(secondTokens).count) / Double(firstTokens.union(secondTokens).count)
    }

    /// Same meaning? Equal ignoring case for most kinds; for recipes, half the words in common is enough.
    static func sameValue(_ kind: FactKind, _ first: String, _ second: String) -> Bool {
        let firstTrimmed = first.trimmingCharacters(in: .whitespaces).lowercased()
        if firstTrimmed == second.trimmingCharacters(in: .whitespaces).lowercased() { return true }
        return kind == .recipe && overlap(first, second) >= 0.5
    }

    // MARK: Phrase matching for recipe selection

    static let dayPattern = Pattern(
        #"(?<!\w)(today|tonight|tomorrow|next week|this week|this weekend|(mon|tues|wednes|thurs|fri|satur|sun)day|\d{1,2}(st|nd|rd|th))(?!\w)"#,
        caseInsensitive: true)
    static let timePattern = Pattern(
        #"(?<!\w)(\d{1,2}(:\d{2})?\s?(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|at \d{1,2}|noon|midday|midnight|o'clock)(?!\w)"#,
        caseInsensitive: true)

    /// True if `phrase` appears in `text` as whole words, ignoring case.
    /// `{day}` and `{time}` are placeholders for a day or a clock time.
    public static func phraseMatches(_ phrase: String, in text: String) -> Bool {
        switch phrase {
        case "{day}": return dayPattern.matches(text)
        case "{time}": return timePattern.matches(text)
        default:
            let trimmed = phrase.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            return Pattern("(?<!\\w)" + escaped + "(?!\\w)", caseInsensitive: true).matches(text)
        }
    }
}

