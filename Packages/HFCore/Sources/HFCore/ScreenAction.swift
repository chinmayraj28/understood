import CoreGraphics
import Foundation

/// A key or shortcut, parsed once so every package agrees on what it is.
public struct KeyChord: Sendable, Equatable {
    public let modifiers: Set<KeyModifier>
    /// The key's name in lower case: "return", "enter", "delete", "space", "q", "tab", "volume_up".
    public let key: String

    public init(modifiers: Set<KeyModifier> = [], key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    /// Parses names such as "return", "cmd+return", "Command+Shift+T", "ctrl+enter".
    /// Returns nil when there is no key.
    public init?(_ text: String) {
        var modifiers: Set<KeyModifier> = []
        var key: String?
        for rawPart in text.split(separator: "+", omittingEmptySubsequences: true) {
            let part = rawPart.trimmingCharacters(in: .whitespaces).lowercased()
            switch part {
            case "cmd", "command", "super", "meta", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "fn", "function": modifiers.insert(.function)
            default: key = part
            }
        }
        guard let key, !key.isEmpty else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    /// Return or Enter, with or without modifiers. Command+Return sends in Gmail and Outlook,
    /// so the modifiers do not make it safer.
    public var isReturn: Bool { ["return", "enter", "kp_enter", "keypad_enter"].contains(key) }
    public var isSpace: Bool { key == "space" || key == " " }
    public var isDelete: Bool { ["delete", "backspace", "forward_delete", "forwarddelete", "del"].contains(key) }

    /// How it is written in a description: "Command+Return".
    public var display: String {
        let order: [(KeyModifier, String)] = [
            (.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command"), (.function, "Fn"),
        ]
        let names = order.filter { modifiers.contains($0.0) }.map(\.1)
        let keyName = key.count == 1 ? key.uppercased() : key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        return (names + [keyName]).joined(separator: "+")
    }
}

/// One thing the agent is about to do to the screen that could matter: a click, a drag,
/// or a key press that can commit something.
///
/// This is what the safety gate judges. It is built in code, at the moment of the action,
/// from what is really under the pointer or holding keyboard focus, and it carries that as
/// structured fields (role, label, app) rather than a sentence. The gate's fixed rules read
/// the fields directly. The one sentence form, `description`, is built here and nowhere else,
/// so the screen agent, the eyes and the gate cannot disagree about wording.
public struct ScreenAction: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case click
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case drag
        case pressKey = "press_key"
        case typeLineBreak = "type_line_break"  // typing a newline, which sends in chat apps
    }

    public let kind: Kind
    /// The key, for `.pressKey`.
    public let key: KeyChord?
    /// What is under the pointer (click, drag start) or has keyboard focus (key, line break).
    /// Nil when it could not be determined: the gate treats that as unknown, never as safe.
    public let target: UIElementInfo?
    /// Where a drag ends.
    public let destination: UIElementInfo?
    /// The app and window in front, used when the target is unknown.
    public let frontApp: String
    public let frontWindow: String
    /// The bundle identifier of the app in front. Empty when unknown.
    public let frontAppBundleIdentifier: String

    public init(
        kind: Kind, key: KeyChord? = nil, target: UIElementInfo?, destination: UIElementInfo? = nil,
        frontApp: String = "", frontWindow: String = "", frontAppBundleIdentifier: String = ""
    ) {
        self.kind = kind
        self.key = key
        self.target = target
        self.destination = destination
        self.frontApp = frontApp
        self.frontWindow = frontWindow
        self.frontAppBundleIdentifier = frontAppBundleIdentifier
    }

    /// The app the action lands in.
    public var app: String { target?.app.isEmpty == false ? target!.app : frontApp }
    public var window: String { target?.window.isEmpty == false ? target!.window : frontWindow }
    /// The bundle identifier of the app the action lands in. Empty when unknown.
    public var appBundleIdentifier: String {
        target?.appBundleIdentifier.isEmpty == false ? target!.appBundleIdentifier : frontAppBundleIdentifier
    }

    /// True when the action would land on something the agent must never operate: a system
    /// password or Touch ID prompt, an installer or a software updater. Checked for the target's
    /// app and for the app in front, because such a window can take the keyboard without being clicked.
    public var landsOnProtectedSurface: Bool {
        ProtectedSurfaces.isProtected(bundleIdentifier: appBundleIdentifier, appName: app)
            || ProtectedSurfaces.isProtected(bundleIdentifier: frontAppBundleIdentifier, appName: frontApp)
            || target?.role == .passwordField
    }

    /// True when we could not find out what the action lands on.
    public var isTargetUnknown: Bool { target == nil }

    /// The single sentence form, for the classifier, the audit log and the fallback spoken question:
    ///
    ///     Click button "Send" in WhatsApp, window "WhatsApp"
    ///     Click an unlabelled button (identifier "ChatBar_SendButton") in WhatsApp, window "WhatsApp"
    ///     Press Return in text area "Compose message" in WhatsApp, window "WhatsApp"
    ///     Press Command+Delete in list item "report.pdf" in Finder, window "Documents"
    ///     Type a line break in text area "Compose message" in WhatsApp, window "WhatsApp"
    ///     Click an unknown control in Spotify, window "Spotify Premium"
    ///
    /// Long text inside content such as a message bubble is left out, so the words of the
    /// user's private messages are never sent to the classifier.
    public var description: String {
        switch kind {
        case .click: return "Click \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow))"
        case .doubleClick: return "Double-click \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow))"
        case .rightClick: return "Right-click \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow))"
        case .drag:
            return "Drag \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow)) to \(Self.phrase(for: destination, frontApp: frontApp, frontWindow: frontWindow))"
        case .pressKey:
            return "Press \(key?.display ?? "a key") in \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow))"
        case .typeLineBreak:
            return "Type a line break in \(Self.phrase(for: target, frontApp: frontApp, frontWindow: frontWindow))"
        }
    }

    /// The longest label of a content control (a message bubble, a paragraph) that is quoted in a description.
    public static let longestQuotedContentLabel = 30

    /// `button "Send" in WhatsApp, window "WhatsApp"`, or the unlabelled or unknown form.
    public static func phrase(for element: UIElementInfo?, frontApp: String = "", frontWindow: String = "") -> String {
        guard let element else {
            guard !frontApp.isEmpty else { return "an unknown control on the screen" }
            // Name the window too, so the classifier can tell an unknown control in Gmail from one on YouTube.
            return frontWindow.isEmpty
                ? "an unknown control in \(frontApp)"
                : "an unknown control in \(frontApp), window \"\(frontWindow)\""
        }
        var text: String
        if element.label.isEmpty {
            text = "an unlabelled \(element.role.rawValue)"
            if !element.identifier.isEmpty { text += " (identifier \"\(element.identifier)\")" }
        } else if element.role.isContent && element.label.count > longestQuotedContentLabel {
            // A message bubble or a paragraph: say what it is, not what it says.
            text = "\(element.role.rawValue) containing text"
        } else {
            text = "\(element.role.rawValue) \"\(element.label)\""
        }
        if !element.app.isEmpty { text += " in \(element.app)" }
        if !element.window.isEmpty { text += ", window \"\(element.window)\"" }
        if !element.isEnabled { text += " (disabled)" }
        return text
    }
}

public enum ScreenText {
    /// Splits a label or identifier into lowercased words. It breaks on anything that is not a
    /// letter or digit, on camel-case humps, and where a run of capitals meets a new word:
    ///
    ///     "ChatBar_SendButton"  ->  ["chat", "bar", "send", "button"]
    ///     "MacJREInstaller"     ->  ["mac", "jre", "installer"]
    ///
    /// Pass the text in its original case: lowercasing it first hides the humps.
    public static func words(_ text: String) -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var current = ""
        func endWord() {
            if !current.isEmpty { words.append(current.lowercased()) }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                endWord()
                continue
            }
            if character.isUppercase, index > 0, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // "chatBar": a capital after a lower-case letter or digit starts a word.
                let afterLowercase = previous.isLowercase || previous.isNumber
                // "JREInstaller": the last capital of a run starts a word when a lower-case letter follows.
                let endsCapitalRun = previous.isUppercase && (next?.isLowercase ?? false)
                if afterLowercase || endsCapitalRun { endWord() }
            }
            current.append(character)
        }
        endWord()
        return words
    }
}
