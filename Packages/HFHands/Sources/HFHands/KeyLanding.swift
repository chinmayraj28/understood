import Foundation
import HFCore

/// Where a key a quick tool is about to press is meant to land.
enum KeyDestination: Equatable {
    /// Spotlight's search field.
    case spotlightField
    /// The app the spoken command was meant for.
    case app(FrontApp)
    /// A text field in that app: for Return after typing, or in an address bar.
    case textInput(FrontApp)
    /// A system-wide shortcut (opening Spotlight, a screenshot, switching apps):
    /// it doesn't matter which window has the keyboard, only that it isn't a
    /// password or install prompt.
    case system
}

/// Checks, at the moment of pressing, that a key will land where it is meant to.
///
/// A Return that reaches the default button of a dialog nobody expected is how
/// an assistant installs or agrees to something the user never asked for. (On
/// 5 Nov a Java updater, its installer and then a password prompt came to the
/// front during a live test.) So before every Return, Space, shortcut or piece
/// of typing, the quick tools ask the accessibility system where the keyboard
/// really is, and refuse with a spoken sentence when it isn't where intended.
/// Volume, media and brightness keys go to the system, not to a window, so
/// they need no check.
enum KeyLanding {
    /// Controls a Return or Space would press rather than type into.
    static let pressableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXLink",
        "AXDisclosureTriangle",
    ]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// The shared sentence, so the quick tools, the screen agent and the gate say the same thing.
    static let protectedSentence = ProtectedSurfaces.spokenRefusal

    /// Password and Touch ID prompts, installers and updaters, from the shared list in HFCore,
    /// so every part of the product recognises them the same way.
    static func isProtected(name: String, bundleID: String) -> Bool {
        ProtectedSurfaces.isProtected(bundleIdentifier: bundleID, appName: name)
    }

    /// Nil when the key may be pressed; otherwise the spoken reason it may not.
    static func problem(focus: KeyboardFocus?, front: FrontApp?, destination: KeyDestination) -> String? {
        if let focus, isProtected(name: focus.appName, bundleID: focus.bundleID) { return protectedSentence }
        if let front, isProtected(name: front.name, bundleID: front.bundleID) { return protectedSentence }

        switch destination {
        case .system:
            return nil

        case .spotlightField:
            // Spotlight never becomes the frontmost app, so only the accessibility
            // focus can say whether it has the keyboard; if that can't be read, don't press.
            guard let focus else { return "I couldn't confirm the keyboard was in Spotlight, so I didn't press anything." }
            let isSpotlight = focus.bundleID == "com.apple.Spotlight" || focus.appName == "Spotlight"
            let fieldOK = focus.identifier.isEmpty || focus.identifier == "SpotlightSearchField"
            let roleOK = focus.role.isEmpty || textRoles.contains(focus.role)
            guard isSpotlight, fieldOK, roleOK else {
                return "Another window took the keyboard while Spotlight was open, so I stopped."
            }
            return nil

        case .app(let target), .textInput(let target):
            if let focus {
                guard focus.pid == target.pid else { return "Another window has the keyboard, so I didn't press that." }
                if case .textInput = destination, pressableRoles.contains(focus.role) {
                    return "The keyboard is on a button, not in a text field, so I didn't press that."
                }
                return nil
            }
            // Accessibility can't say: fall back to the frontmost app.
            guard let front, front.pid == target.pid else { return "Another window has the keyboard, so I didn't press that." }
            return nil
        }
    }
}
