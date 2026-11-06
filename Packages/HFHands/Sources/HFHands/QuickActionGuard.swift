import CoreGraphics
import Foundation
import HFCore

/// The answer from a `QuickActionGuarding`: go ahead, or not and why.
public struct QuickActionVerdict: Sendable, Equatable {
    public let allowed: Bool
    /// When not allowed: one short sentence the voice agent can act on. May be empty,
    /// in which case the tool says `QuickActionGuard.needsConfirmationSentence`.
    public let spokenReason: String

    public init(allowed: Bool, spokenReason: String = "") {
        self.allowed = allowed
        self.spokenReason = spokenReason
    }

    public static let allow = QuickActionVerdict(allowed: true)
    public static func refuse(_ spokenReason: String = "") -> QuickActionVerdict {
        QuickActionVerdict(allowed: false, spokenReason: spokenReason)
    }
}

/// Decides, immediately before a quick tool does something that could commit,
/// whether it may go ahead. The app implements it with the eyes' labels and the
/// safety gate: build the `ScreenAction` from what really has keyboard focus (for
/// a key or a line break) or is under `point` (for a click) at that moment, ask
/// the gate, and allow only when it says safe.
///
/// Quick tools never perform an action that needs confirming: they refuse, and the
/// voice agent does it as a task instead, which is where confirmations are asked.
public protocol QuickActionGuarding: Sendable {
    /// - Parameters:
    ///   - kind: `.pressKey`, `.typeLineBreak`, `.click`, `.doubleClick` or `.rightClick`.
    ///   - key: the key about to be pressed, for `.pressKey`.
    ///   - point: where a click is about to land, in screen points (top-left origin).
    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict
}

/// Which quick actions can commit something, and asking the guard about them.
enum QuickActionGuard {
    static let needsConfirmationSentence = "That would need your confirmation, so I'll do it as a task instead."

    static let textRoles: Set<String> = KeyLanding.textRoles

    /// True when this key can send, submit, delete, close or discard something, so it
    /// must pass the guard. Keys that can't (arrows, Tab, Escape, letters, Command+C,
    /// the system shortcuts, volume and media keys) stay instant.
    ///
    /// - Parameter focusedRole: the focused control's accessibility role, "" if unknown.
    static func mayCommit(_ chord: KeyChord, focusedRole: String) -> Bool {
        let command = chord.modifiers.contains(.command)
        if chord.isReturn { return true }  // with any modifiers: Command+Return sends in Gmail and Outlook
        if chord.isSpace { return !command && !chord.modifiers.contains(.control) }  // Space presses a focused button
        if chord.isDelete {
            if command { return true }  // Command+Delete moves files to the Bin, deletes messages
            return !textRoles.contains(focusedRole)  // in a text field Delete only edits; elsewhere it can delete
        }
        // Close, quit and "Don't Save" (Command+D in a save sheet) can lose or discard work.
        if command, ["q", "w", "d"].contains(chord.key) { return true }
        return false
    }

    /// Asks the guard, refusing when there is none, when it says no, or when it
    /// doesn't answer in time. Returns the spoken refusal, or nil to go ahead.
    static func refusal(
        from actionGuard: QuickActionGuarding?, _ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?,
        timeout: TimeInterval
    ) async -> String? {
        guard let actionGuard else { return needsConfirmationSentence }  // no guard: never act
        let verdict = await withTaskGroup(of: QuickActionVerdict?.self) { group -> QuickActionVerdict? in
            group.addTask { await actionGuard.check(kind, key: key, at: point) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil  // too slow counts as a refusal
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let verdict, verdict.allowed else {
            let reason = verdict?.spokenReason ?? ""
            return reason.isEmpty ? needsConfirmationSentence : reason
        }
        return nil
    }
}
