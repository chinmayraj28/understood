import Foundation

/// Everything the runner says out loud passes through here, so it is always one
/// tidy line: no newlines, no runs of spaces, and never longer than a limit.
enum SpokenText {
    /// Collapses all whitespace (including newlines) to single spaces, trims the
    /// ends, and caps the length with a trailing ellipsis.
    static func clean(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(max(0, limit - 1))
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "So far: Opening WhatsApp; Searching for Amma." from the last three
    /// progress lines, or "It had only just started." when there are none.
    static func soFar(_ progressLog: [String]) -> String {
        let recent = progressLog.suffix(3).map { line in
            var trimmed = line
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }
        guard !recent.isEmpty else { return "It had only just started." }
        return "So far: " + recent.joined(separator: "; ") + "."
    }

    /// "3 minutes" for whole minutes, otherwise "45 seconds".
    static func duration(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(Int(seconds)) seconds"
    }

    /// The question the user hears when the executor gave no wording of its own:
    /// `Click button "Send" in WhatsApp` becomes `Is it OK to click button "Send" in WhatsApp?`.
    static func fallbackQuestion(forAction action: String) -> String {
        var body = action.trimmingCharacters(in: .whitespaces)
        while let last = body.last, ".!?,;:".contains(last) || last.isWhitespace { body.removeLast() }
        guard let first = body.first else { return "Is it OK to go ahead?" }
        body = first.lowercased() + body.dropFirst()
        return "Is it OK to \(body)?"
    }
}
