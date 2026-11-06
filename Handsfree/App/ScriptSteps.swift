//
//  ScriptSteps.swift
//  Handsfree
//
//  The pure parts of the test-only script runner (ScriptRun.swift): reading a
//  script into steps, and the rule for when its cleanup may throw a document
//  away. Unit tested (HandsfreeTests/ScriptStepsTests.swift). New for Handsfree.
//

import Foundation

struct ScriptStep: Equatable {
    let verb: String
    let argument: String
}

enum ScriptSteps {

    /// One step per line; blank lines and "#" comments are skipped. The verb is lower-cased, the
    /// argument kept as written.
    static func parse(_ text: String) -> [ScriptStep] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            return ScriptStep(
                verb: String(parts[0]).lowercased(),
                argument: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
        }
    }

    /// "TextEdit | hello from Handsfree" -> ("TextEdit", "hello from Handsfree"); nil without a "|".
    static func appAndText(_ argument: String) -> (app: String, text: String)? {
        let parts = argument.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Why the cleanup must leave the front document alone, or nil when it may close it unsaved.
    /// It may only when all hold: the app was not running before the script (so no window of the
    /// user's can be in it), and the front document holds exactly the text the script had typed
    /// (so it is the script's own document). The button it then presses must also be in a sheet of
    /// that window, which ScriptRun checks separately.
    static func refusalToDiscard(appWasRunningBefore: Bool, documentText: String?, typed: String) -> String? {
        if appWasRunningBefore {
            return "the app was already running before the script, so a document in it may be the user's; leaving everything as it is"
        }
        guard let documentText else {
            return "could not read the front document; leaving everything as it is"
        }
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean(documentText) == clean(typed) else {
            return "the front document does not hold exactly the text the script typed (\(documentText.count) characters); leaving everything as it is"
        }
        return nil
    }

    /// The titles of a save sheet's discard button.
    static let discardButtonTitles: Set<String> = ["delete", "don\u{2019}t save", "don't save"]
}
