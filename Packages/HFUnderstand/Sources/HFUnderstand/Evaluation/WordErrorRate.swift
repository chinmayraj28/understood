import Foundation

/// Word error rate: how many words a transcript gets wrong compared with what was said.
///
/// Both texts are first made comparable (lower case, no punctuation, single spaces, numbers
/// written as words), then the fewest word insertions, deletions and substitutions that turn the
/// reference into the hypothesis are counted. WER = errors / words in the reference.
///
/// Example: reference "Message Mum", hypothesis "message some" -> 1 error in 2 words, WER 0.5.
public enum WordErrorRate {
    /// The counts behind one comparison, so totals can be added up across many clips.
    public struct Count: Sendable, Equatable, Codable {
        public var errors: Int
        public var referenceWords: Int

        public init(errors: Int, referenceWords: Int) {
            self.errors = errors
            self.referenceWords = referenceWords
        }

        /// Errors per reference word. An empty reference counts as 0 when the hypothesis is
        /// also empty and 1 otherwise, so a clip with nothing to say cannot divide by zero.
        public var rate: Double {
            if referenceWords == 0 { return errors == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceWords)
        }

        public static func + (lhs: Count, rhs: Count) -> Count {
            Count(errors: lhs.errors + rhs.errors, referenceWords: lhs.referenceWords + rhs.referenceWords)
        }

        public static let zero = Count(errors: 0, referenceWords: 0)
    }

    /// Compares a hypothesis with the reference after normalising both.
    public static func count(reference: String, hypothesis: String) -> Count {
        let ref = words(reference)
        let hyp = words(hypothesis)
        return Count(errors: editDistance(ref, hyp), referenceWords: ref.count)
    }

    /// The word error rate of one hypothesis.
    public static func rate(reference: String, hypothesis: String) -> Double {
        count(reference: reference, hypothesis: hypothesis).rate
    }

    /// True when the two texts are the same after normalising: the "meaning" proxy used in the
    /// evaluation ("Message Mum." and "message mum" match; "message some" does not).
    public static func matches(_ a: String, _ b: String) -> Bool {
        words(a) == words(b)
    }

    /// The normalised words of a text.
    public static func words(_ text: String) -> [String] {
        normalise(text).split(separator: " ").map(String.init)
    }

    /// Lower case, apostrophes dropped ("don't" -> "dont"), other punctuation turned into
    /// spaces, whitespace collapsed, and digits written as words ("2" -> "two", "10" -> "ten").
    public static func normalise(_ text: String) -> String {
        var cleaned = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        // Split runs of digits from letters ("3pm" -> "3 pm") so numbers can be folded.
        var spaced = ""
        var previousIsDigit: Bool?
        for character in cleaned {
            if character == " " {
                spaced.append(character)
                previousIsDigit = nil
                continue
            }
            let isDigit = character.isASCII && character.isNumber
            if let previous = previousIsDigit, previous != isDigit { spaced.append(" ") }
            spaced.append(character)
            previousIsDigit = isDigit
        }
        let tokens = spaced.split(separator: " ").flatMap { token -> [String] in
            let word = String(token)
            if word.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(word) {
                return numberWords(value)
            }
            return [word]
        }
        return tokens.joined(separator: " ")
    }

    /// Simple number folding: 0 to 9999 as English words; larger numbers stay as digits.
    static func numberWords(_ value: Int) -> [String] {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                    "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        guard value >= 0, value < 10_000 else { return [String(value)] }
        if value < 20 { return [ones[value]] }
        if value < 100 {
            let rest = value % 10
            return rest == 0 ? [tens[value / 10]] : [tens[value / 10], ones[rest]]
        }
        if value < 1000 {
            let rest = value % 100
            return [ones[value / 100], "hundred"] + (rest == 0 ? [] : numberWords(rest))
        }
        let rest = value % 1000
        return numberWords(value / 1000) + ["thousand"] + (rest == 0 ? [] : numberWords(rest))
    }

    /// Levenshtein distance over words: the fewest insertions, deletions and substitutions.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
