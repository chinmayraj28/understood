import Foundation

/// A compiled regular expression with the few operations the rules need.
///
/// The rules in docs/MEMORY.md are written as ICU patterns, which is what
/// `NSRegularExpression` speaks, so they are used here exactly as written.
/// `NSRegularExpression` is immutable and safe to share between threads.
struct Pattern: @unchecked Sendable {
    let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        // A bad pattern is a programming error caught by the first test run.
        expression = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// True if the pattern matches anywhere in the text.
    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every match, as the matched text.
    func allMatches(_ text: String) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// The first match, with access to its named groups.
    func firstMatch(_ text: String) -> PatternMatch? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return PatternMatch(result: match, text: text)
    }

    /// Replaces every match with what `replacement` returns for it.
    func replace(_ text: String, with replacement: (PatternMatch) -> String) -> String {
        let results = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var output = text
        // Work backwards so earlier ranges stay valid.
        for result in results.reversed() {
            guard let range = Range(result.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement(PatternMatch(result: result, text: text)))
        }
        return output
    }

    /// Replaces every match with a fixed string.
    func replace(_ text: String, with fixed: String) -> String {
        replace(text) { _ in fixed }
    }

    /// Splits the text at every match, like Python's `re.split`.
    func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        for result in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(result.range, in: text) else { continue }
            pieces.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        pieces.append(String(text[start...]))
        return pieces
    }
}

/// One match of a `Pattern`.
struct PatternMatch {
    let result: NSTextCheckingResult
    let text: String

    /// The whole matched text.
    var matched: String { Range(result.range, in: text).map { String(text[$0]) } ?? "" }

    /// The text of a named group, or "" if it did not take part.
    func group(_ name: String) -> String {
        let range = result.range(withName: name)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    /// The text after the match.
    var after: String {
        guard let range = Range(result.range, in: text) else { return "" }
        return String(text[range.upperBound...])
    }
}
