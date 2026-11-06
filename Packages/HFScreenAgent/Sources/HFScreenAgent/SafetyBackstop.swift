import CoreGraphics
import Foundation
import HFCore

/// What the safety gate is asked about one action.
struct SafetyQuestion: Equatable {
    /// What the gate judges: the action and what is really under the pointer or
    /// holding keyboard focus, as structured fields. Its `description` is the one
    /// sentence form (built in HFCore). It never contains typed text.
    let action: ScreenAction
    /// What the user hears if the gate wants a yes, when we know who and what:
    /// `Send "running late" to Amma?`. Nil lets the runner word it.
    let spokenQuestion: String?
    /// True when the action would send something to someone (Send, Return in a
    /// message box). Such actions are refused outright while the open chat is
    /// known to be the wrong one.
    let isSend: Bool
}

/// The safety backstop: decides, in code, which actions must pass the safety
/// gate before they happen, and builds what the gate sees from the
/// accessibility tree at that moment.
///
/// It does not decide what is risky (the gate does that). It decides what the
/// gate must SEE: every click, every drag, every Return or Enter, Space on a
/// focused button, typed text that contains a newline, and the shortcuts that
/// can send, delete or quit without a click. Points are screen points.
///
/// Clicks must be looked up when the pointer has ARRIVED (the agent glides
/// first): in WhatsApp the spot of the voice-message button becomes Send once
/// text is typed.
final class SafetyBackstop {
    private let labels: Labels
    /// The last text typed and the app it went into, so a following Send can be
    /// read back to the user ("Send "running late" to Amma?"). It goes into the
    /// spoken question only, never into what the gate judges.
    private var lastTyped: (text: String, app: String)?
    /// Who the next send goes to, as Claude read it in the open chat's header
    /// (`prepare_send`). Needed because some apps' window titles name no one:
    /// WhatsApp's window is always titled just "WhatsApp".
    private var recipient: String?
    /// Set while the open chat is known to be the wrong one; every send is refused.
    private(set) var wrongChat: String?

    init(labels: Labels) { self.labels = labels }

    /// The question for the gate, or nil when the action needs no check
    /// (looking, moving the pointer, scrolling, waiting, typing on one line).
    func question(for action: ComputerAction) async -> SafetyQuestion? {
        switch action {
        case .click(let button, let count, let point, _):
            guard let point else { return nil }
            let kind: ScreenAction.Kind = button == .right ? .rightClick : (count == 2 ? .doubleClick : .click)
            let screenAction = await labels.clickAction(at: point, kind: kind)
            let isSend = Self.looksLikeSend(screenAction.target)
            return SafetyQuestion(action: screenAction, spokenQuestion: isSend ? await sendQuestion() : nil, isSend: isSend)

        case .drag(let start, let end):
            let front = await labels.frontmost()
            let screenAction = ScreenAction(
                kind: .drag, target: await labels.element(at: start), destination: await labels.element(at: end),
                frontApp: front.app, frontWindow: front.window
            )
            return SafetyQuestion(action: screenAction, spokenQuestion: nil, isSend: false)

        case .key(let combo, _):
            guard let chord = KeyChord(combo) else { return nil }
            return await keyQuestion(chord)

        case .type(let text):
            guard text.contains(where: \.isNewline) else { return nil }
            let screenAction = await labels.lineBreakAction()
            let isSend = Self.isMessageBox(screenAction.target)
            return SafetyQuestion(action: screenAction, spokenQuestion: isSend ? await sendQuestion(pending: text) : nil, isSend: isSend)

        case .screenshot, .zoom, .move, .scroll, .wait, .cursorPosition:
            return nil
        }
    }

    // MARK: - Keys

    private func keyQuestion(_ chord: KeyChord) async -> SafetyQuestion? {
        let command = chord.modifiers.contains(.command)
        let needsCheck: Bool
        if chord.isReturn {
            needsCheck = true  // sends in chat apps, submits forms; Command+Return sends in Gmail
        } else if chord.isDelete {
            if command {
                needsCheck = true  // Move to Bin, delete the selected item
            } else {
                // A plain Delete inside a text field only deletes characters. Anywhere
                // else (a list of emails, a file in Finder) it can delete the selection.
                let focusRole = await labels.focusedElement()?.role
                needsCheck = !(focusRole?.isTextEntry ?? false)
            }
        } else if chord.isSpace, chord.modifiers.isEmpty {
            // Space on a focused button presses it, the same as a click.
            needsCheck = await labels.focusedElement()?.role.activatesOnKeyPress ?? false
        } else if command && chord.key == "q" {
            needsCheck = true  // quits the app, may lose unsaved work
        } else if command && chord.modifiers.contains(.shift) && chord.key == "d" {
            needsCheck = true  // Send in Apple Mail
        } else {
            needsCheck = false
        }
        guard needsCheck else { return nil }

        let screenAction = await labels.keyAction(chord)
        let isSend = (chord.isReturn && Self.isMessageBox(screenAction.target))
            || (command && chord.modifiers.contains(.shift) && chord.key == "d")
        return SafetyQuestion(action: screenAction, spokenQuestion: isSend ? await sendQuestion() : nil, isSend: isSend)
    }

    // MARK: - Typed text and the recipient

    /// Call after text was typed, so a later Send can be read back.
    func recordTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let focused = await labels.focusedElement()
        // Text typed into a search box (Spotlight, a browser's search) is a query,
        // not a message, so it is never read back as "Send ...?".
        lastTyped = Self.isMessageBox(focused) ? (trimmed, focused?.app ?? "") : nil
    }

    /// Call after an action that sent something went ahead, so the same text is not read back twice.
    func forgetTyped() {
        lastTyped = nil
        recipient = nil
    }

    /// Records who the next send goes to, and checks it against who Claude meant.
    /// Returns nil when they match, or a sentence for Claude when the open chat is
    /// the wrong one, in which case sends are refused until a matching call.
    func prepareSend(headerName: String, expectedName: String) -> String? {
        if expectedName.isEmpty || Self.namesMatch(headerName, expectedName) {
            recipient = headerName
            wrongChat = nil
            return nil
        }
        recipient = nil
        wrongChat = "The open chat is \"\(headerName)\", not \"\(expectedName)\""
        return wrongChat
    }

    /// "Amma" matches "amma" and "Amma ❤️"; "Priya Shah" does not match "Priya Patel".
    static func namesMatch(_ first: String, _ second: String) -> Bool {
        // Phone numbers: WhatsApp shows "+44 7700 900123" with spaces and invisible marks,
        // and a person may say "07700 900123". Compare the last ten digits only.
        let firstDigits = first.filter { $0.isASCII && $0.isNumber }, secondDigits = second.filter { $0.isASCII && $0.isNumber }
        if firstDigits.count >= 7 && secondDigits.count >= 7 {
            let length = min(10, firstDigits.count, secondDigits.count)
            return firstDigits.suffix(length) == secondDigits.suffix(length)
        }
        func simple(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber || $0 == " " }
                .split(separator: " ").joined(separator: " ")
        }
        let first = simple(first), second = simple(second)
        guard !first.isEmpty, !second.isEmpty else { return false }
        return first == second || first.hasPrefix(second + " ") || second.hasPrefix(first + " ")
    }

    // MARK: - Wording

    /// `Send "running late" to Amma?`, built from the text the agent itself typed
    /// (not Claude's account of it) and the name read off the chat header.
    private func sendQuestion(pending: String? = nil) async -> String? {
        let focused = await labels.focusedElement()
        let place = (app: focused?.app ?? "", window: focused?.window ?? "")
        let text: String
        if let pending {
            text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let lastTyped, lastTyped.app == place.app || place.app.isEmpty {
            text = lastTyped.text
        } else {
            return nil
        }
        guard !text.isEmpty else { return nil }
        let snippet = text.count > 60 ? String(text.prefix(57)) + "..." : text
        // Who: the name Claude read in the chat header, or else a window title that
        // names someone. A title that is just the app ("WhatsApp") names no one.
        let windowNamesSomeone = !place.window.isEmpty && !place.window.localizedCaseInsensitiveContains(place.app)
        if let recipient, !recipient.isEmpty { return "Send \"\(snippet)\" to \(Speech.recipient(recipient))?" }
        if windowNamesSomeone { return "Send \"\(snippet)\" to \(place.window)?" }
        let app = place.app.isEmpty ? lastTyped?.app ?? "" : place.app
        return app.isEmpty ? "Send \"\(snippet)\"?" : "Send \"\(snippet)\" in \(app)?"
    }

    /// A box a message is written in: text entry that is not a search box.
    static func isMessageBox(_ element: UIElementInfo?) -> Bool {
        guard let element else { return false }
        return element.role.isTextEntry && element.role != .searchField && element.role != .passwordField
            && !element.words.contains("search")
    }

    /// A target whose label or identifier says it sends: "Send", "ChatBar_SendButton", "Reply", "Post".
    static func looksLikeSend(_ element: UIElementInfo?) -> Bool {
        guard let element else { return false }
        return !Set(element.words).isDisjoint(with: ["send", "post", "reply", "submit", "share"])
    }
}
