import Foundation

/// Small text helpers shared by the decider and the phrasebook, so "do these two transcripts
/// say the same thing?" has one answer everywhere.
///
/// Three ideas, all deliberately simple so they can be explained in a sentence each:
/// - **Normalise:** lowercase, drop punctuation, fold "two" into "2". "Call Sam." and "call sam"
///   are the same sentence.
/// - **Content words:** the words that change the meaning. "Open the WhatsApp please" and
///   "open WhatsApp" have the same content words, so two recognisers that differ only on
///   "the" still agree.
/// - **Similarity:** an edit distance over words, where swapping one word for another costs
///   less when the two are spelled alike ("whatsap" for "whatsapp") or sound alike ("sum" for
///   "some"). 1 means identical, 0 means nothing in common.
public enum SpeechText {
    /// Number words folded into digits, because recognisers write numbers either way.
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    ]

    /// Words that rarely change what a command means. Kept short on purpose: "on" and "off"
    /// are not here, because "turn on" and "turn off" are opposites.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "please", "um", "umm", "uh", "er", "erm", "ah", "oh", "hey",
        "ok", "okay", "just", "so", "like", "and", "of", "for", "my", "can", "you", "could", "would",
    ]

    /// Words that turn a sentence into its opposite. After normalising, "don't" is "dont".
    public static let negationWords: Set<String> = ["no", "not", "dont", "never", "cancel", "nope"]

    /// True when the text contains a negation word.
    public static func containsNegation(_ text: String) -> Bool {
        words(text).contains(where: negationWords.contains)
    }

    /// Names: words written with a capital that are not the first word ("message Mum" gives
    /// "mum"), lowercased. Recognisers differ in casing, so callers pool names from every text.
    public static func names(in text: String) -> Set<String> {
        let raw = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        return Set(raw.dropFirst().filter { $0.first?.isUppercase == true }.flatMap { words(String($0)) })
    }

    /// True when the two texts have exactly the same negation words, digits and names
    /// (`names`, lowercased). One of these words is enough to flip what a sentence means
    /// ("do not send" against "do send", "2" against "3", "Sam" against "Mum"), so a near match
    /// that differs on one of them must never be trusted as the same sentence.
    public static func keyWordsAgree(_ first: String, _ second: String, names: Set<String>) -> Bool {
        func keyWords(_ text: String) -> Set<String> {
            Set(words(text).filter { negationWords.contains($0) || $0.allSatisfy(\.isNumber) || names.contains($0) })
        }
        return keyWords(first) == keyWords(second)
    }

    /// Lowercase words with punctuation removed and number words folded to digits.
    public static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "&", with: " and ")
        var cleaned = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue  // "don't" becomes "dont", so apostrophe styles never matter
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map { numberWords[String($0)] ?? String($0) }
    }

    /// The normalised sentence as one string: "Call Sam!" becomes "call sam".
    public static func normalise(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// The words that carry meaning, in order.
    public static func contentWords(_ text: String) -> [String] {
        words(text).filter { !fillerWords.contains($0) }
    }

    /// How alike two transcripts are, from 0 to 1. See the type's comment for the method.
    public static func similarity(_ first: String, _ second: String) -> Double {
        similarity(words: words(first), words(second))
    }

    /// The same measure over word lists that are already normalised.
    static func similarity(words first: [String], _ second: [String]) -> Double {
        if first.isEmpty && second.isEmpty { return 1 }
        let longest = max(first.count, second.count)
        guard longest > 0 else { return 0 }
        // Classic edit distance over words, with a cheaper substitution for near words.
        var previous = (0...second.count).map(Double.init)
        for (rowIndex, firstWord) in first.enumerated() {
            var current = [Double(rowIndex + 1)]
            for (columnIndex, secondWord) in second.enumerated() {
                let substitution = previous[columnIndex] + substitutionCost(firstWord, secondWord)
                let deletion = previous[columnIndex + 1] + 1
                let insertion = current[columnIndex] + 1
                current.append(min(substitution, deletion, insertion))
            }
            previous = current
        }
        return max(0, 1 - previous[second.count] / Double(longest))
    }

    /// 0 for the same word, 0.25 for words that sound alike, otherwise how different the
    /// spellings are (0 to 1). The sound-alike cost is kept well above zero so "son" is never
    /// treated as exactly "some": sounding alike is a hint, not proof.
    static func substitutionCost(_ first: String, _ second: String) -> Double {
        if first == second { return 0 }
        let spelling = 1 - characterSimilarity(first, second)
        let soundsAlike = first.count > 1 && second.count > 1 && soundKey(first) == soundKey(second)
        return soundsAlike ? min(spelling, 0.25) : spelling
    }

    /// 1 minus the character edit distance divided by the longer word's length.
    static func characterSimilarity(_ first: String, _ second: String) -> Double {
        let firstCharacters = Array(first), secondCharacters = Array(second)
        let longest = max(firstCharacters.count, secondCharacters.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...secondCharacters.count)
        for (rowIndex, firstCharacter) in firstCharacters.enumerated() {
            var current = [rowIndex + 1]
            for (columnIndex, secondCharacter) in secondCharacters.enumerated() {
                let cost = firstCharacter == secondCharacter ? 0 : 1
                current.append(min(previous[columnIndex] + cost, previous[columnIndex + 1] + 1, current[columnIndex] + 1))
            }
            previous = current
        }
        return 1 - Double(previous[secondCharacters.count]) / Double(longest)
    }

    /// A sound-alike key for one word: Soundex, after a few English spelling folds
    /// ("ph" sounds like "f", the "k" in "kn" is silent). "sum" and "some" both give "S500".
    /// Digits are their own key, so "2" only matches "2".
    static func soundKey(_ word: String) -> String {
        var letters = word.lowercased()
        guard let first = letters.first, first.isLetter else { return letters }
        for (spelling, sound) in [("ph", "f"), ("kn", "n"), ("wr", "r"), ("wh", "w"), ("ck", "k")] where letters.hasPrefix(spelling) {
            letters = sound + letters.dropFirst(spelling.count)
        }
        if letters.hasPrefix("c") { letters = "k" + letters.dropFirst() }
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let characters = Array(letters)
        var key = String(characters[0]).uppercased()
        var lastCode = codes[characters[0]]
        for character in characters.dropFirst() {
            let code = codes[character]
            if let code, code != lastCode { key.append(code) }
            // "h" and "w" do not separate equal codes in Soundex; vowels do.
            if character != "h" && character != "w" { lastCode = code }
            if key.count == 4 { break }
        }
        return key.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
