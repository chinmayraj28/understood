import Foundation

/// How the runner reads the user's spoken reply to "Send it?".
public enum ReplyVerdict: String, Sendable, Equatable {
    /// A clear yes and nothing else. The only verdict that lets the action happen.
    case yes
    /// Any negative word: "no", "don't", even "no problem, go ahead".
    case no
    /// The user is changing something: "wait, change the time". The executor
    /// gets their words through `lastAnswer` and decides what to do.
    case correction
    /// Hesitation, a question, or extra words that might be a correction
    /// ("hmm", "send it?", "yes, to Priya Patel"). The runner asks once more.
    case unclear
}

/// The conservative word list that reads a confirmation reply. It always runs,
/// needs no network, and is the fallback when the Jev classifier is missing or slow.
///
/// A missed yes costs the user one repeat; a false yes can send a message they
/// did not want. So a negative word always wins, and a yes only counts when
/// every other word is harmless filler.
public enum ReplyJudge {
    static let negativeWords: Set<String> = [
        "no", "nope", "nah", "not", "never", "cancel", "stop", "negative", "nein", "dont", "wont",
        "cant", "isnt", "didnt", "doesnt", "shouldnt", "wouldnt", "couldnt", "arent", "wasnt",
        "havent", "hasnt", "mustnt", "neednt",
    ]
    static let correctionWords: Set<String> = [
        "wait", "hold", "hang", "change", "actually", "but", "instead", "except", "unless", "later",
        "wrong", "different", "edit", "fix",
    ]
    static let hesitationWords: Set<String> = [
        "maybe", "perhaps", "hmm", "hm", "hmmm", "um", "umm", "uh", "er", "erm", "unsure", "what",
        "why", "who", "which", "how",
    ]
    static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "yea", "ya", "sure", "ok", "okay", "alright", "correct", "right",
        "absolutely", "definitely", "affirmative", "confirm", "confirmed", "proceed", "perfect",
        "fine", "great", "approve", "approved", "certainly",
    ]
    static let yesPhrases: [String] = [
        "go ahead", "go for it", "do it", "send it", "please do", "sounds good", "of course", "all right",
    ]
    /// Words allowed around a yes without making it unclear.
    static let fillerWords: Set<String> = [
        "please", "thanks", "thank", "you", "it", "that", "this", "them", "now", "go", "ahead", "for",
        "do", "send", "the", "a", "is", "its", "thats", "all", "just", "sounds", "good", "of",
        "course", "invite", "message", "email", "very", "much", "then", "so", "oh", "well", "and",
        "book", "post", "submit", "save", "create", "delete", "pay", "share", "away", "cheers",
        "lets", "let", "us", "really", "i", "am", "im", "thing",
    ]

    /// Reads a reply with the word list alone.
    public static func wordList(_ reply: String) -> ReplyVerdict {
        let lowered = reply.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = splitWords(lowered)
        if words.isEmpty { return .unclear }
        if lowered.contains("n't") || words.contains(where: negativeWords.contains) { return .no }
        if words.contains(where: correctionWords.contains) { return .correction }
        if lowered.contains("?") || words.contains(where: hesitationWords.contains) { return .unclear }
        let padded = " " + words.joined(separator: " ") + " "
        let hasYes = words.contains(where: yesWords.contains)
            || yesPhrases.contains { padded.contains(" \($0) ") }
        let onlyHarmless = words.allSatisfy { yesWords.contains($0) || fillerWords.contains($0) }
        return hasYes && onlyHarmless ? .yes : .unclear
    }

    /// Runs of letters and apostrophes, with the apostrophes then removed ("don't" becomes "dont").
    static func splitWords(_ lowered: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        func flush() {
            let word = currentWord.replacingOccurrences(of: "'", with: "")
            if !word.isEmpty { words.append(word) }
            currentWord = ""
        }
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(scalar) || scalar == "'" {
                currentWord.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}
