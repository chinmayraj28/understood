import Foundation
import HFCore

/// Keeps the agent's key presses and clicks in windows it meant to use.
///
/// Why it exists: on this Mac a Return meant for Spotlight reached Oracle's Java
/// updater, which had popped up by itself, and started an installer. A window the
/// agent did not open (an updater, a permission prompt, a system dialog) can take
/// the front at any moment, and the next key press then goes to it.
///
/// The rule, in plain words:
/// - After every screenshot Claude sees, keys may go to the app in front then.
/// - The agent's own actions may bring one new app forward: a Command shortcut or a
///   Return (Spotlight opening an app, Command+Tab), or a click on a Dock item or a
///   menu. The first new app to take focus after such an action is accepted.
/// - Anything else that takes keyboard focus is a window the agent did not bring
///   forward: the key press is not made, and Claude gets a fresh screenshot.
/// - A system password prompt, an installer or an updater is never acted on at all:
///   the task stops and the user is told it needs someone's hands.
/// - Our own app (the overlay) is never a target: it means the agent cannot see
///   what is really under the pointer.
final class WindowGuard {
    /// Our own app. A target here means the lookup found the overlay, not the real control.
    static let ownAppNames: Set<String> = ["Handsfree"]

    static func isOwnApp(_ app: String) -> Bool { ownAppNames.contains(app) }

    /// True for a password prompt, an installer or an update dialog. The list is HFCore'"'"'s
    /// `ProtectedSurfaces`, shared with the quick tools and the gate so they cannot drift apart.
    static func isProtected(app: String, bundleIdentifier: String = "") -> Bool {
        ProtectedSurfaces.isProtected(bundleIdentifier: bundleIdentifier, appName: app)
    }

    /// Apps keys may go to now.
    private(set) var expectedApps: Set<String> = []
    /// True right after an action of ours that may bring a new app forward.
    private var newAppExpected = false
    /// An app that must take focus before anything is typed: Spotlight, right after cmd+space.
    private(set) var awaitedApp: String?

    /// Call when the awaited app has taken focus.
    func arrived(_ app: String) { if awaitedApp == app { awaitedApp = nil } }

    /// Call with the app in front whenever Claude is shown a fresh screenshot.
    func sawScreen(frontApp: String) {
        expectedApps = frontApp.isEmpty ? [] : [frontApp]
        newAppExpected = false
        awaitedApp = nil
    }

    /// Call after an action of ours has run, so the windows it opens are expected.
    func didAct(_ action: ComputerAction, target: UIElementInfo?) {
        switch action {
        case .key(let combo, _):
            guard let chord = KeyChord(combo) else { return }
            if chord.modifiers.contains(.command) && chord.isSpace {
                expectedApps.insert("Spotlight")
                awaitedApp = "Spotlight"
            }
            if chord.modifiers.contains(.command) || chord.isReturn { newAppExpected = true }
        case .click:
            if let target {
                if !target.app.isEmpty { expectedApps.insert(target.app) }
                if [.dockItem, .menuItem, .menuBarItem].contains(target.role) { newAppExpected = true }
            }
        default:
            break
        }
    }

    /// May a key press or typing go to `app` now? Accepts the one new app an action
    /// of ours brought forward; never a system dialog or our own overlay.
    func allowsKeys(intoApp app: String) -> Bool {
        if Self.isOwnApp(app) || Self.isProtected(app: app) { return false }
        if app.isEmpty || expectedApps.contains(app) { return true }
        if newAppExpected {
            expectedApps.insert(app)
            newAppExpected = false
            return true
        }
        return false
    }
}
