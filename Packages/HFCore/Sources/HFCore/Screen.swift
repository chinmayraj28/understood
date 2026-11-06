import CoreGraphics
import Foundation

// The agent uses the laptop the way a person does: it looks at the screen and
// uses the real pointer and keyboard. These three protocols are its hands, its
// eyes and its ability to read a control's name.
//
// Every point and rectangle that crosses a module boundary is in SCREEN POINTS
// on the main display, with the origin at the TOP LEFT. Only the eyes know
// about image pixels.

public enum MouseButton: String, Sendable { case left, right, middle }

public enum KeyModifier: String, Sendable, CaseIterable { case command, shift, option, control, function }

/// Thrown by the hands when `halt()` was called while an action was in flight.
public struct Halted: Error, Sendable { public init() {} }

/// HANDS: the real pointer and keyboard. Implemented by HFHands.
///
/// Every call acts on the user's real Mac, visibly. The pointer glides to its
/// target; it does not teleport. Calls run one at a time.
public protocol Hands: Sendable {
    /// Sets the stop flag. Any action in flight throws `Halted` at its next small
    /// step (between pointer movements, between typed characters), leaving no
    /// button or modifier held down. This is the user's only brake.
    func halt()
    /// Clears the stop flag so the next task can act.
    func resume()
    var isHalted: Bool { get }

    var pointerPosition: CGPoint { get }

    /// Glides the pointer to a point. A nil duration picks one from the distance.
    func move(to point: CGPoint, duration: TimeInterval?) async throws
    /// Glides to the point, then clicks.
    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws
    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws
    /// Scrolls by lines. Positive `dy` scrolls down, positive `dx` scrolls right.
    /// When `at` is given the pointer glides there first.
    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws
    /// Presses a key or shortcut by name: "cmd+space", "return", "escape",
    /// "cmd+shift+t", "volume_up", "play_pause". HFHands documents every name.
    func key(_ combo: String) async throws
    /// Types text as real key events. Handles any Unicode. Throws if the text
    /// contains a newline and `allowReturn` is false, because Return sends in chat apps.
    func typeText(_ text: String, allowReturn: Bool) async throws
}

public extension Hands {
    func click(at point: CGPoint) async throws {
        try await click(at: point, button: .left, count: 1, modifiers: [])
    }
    func typeText(_ text: String) async throws { try await typeText(text, allowReturn: false) }
}

/// A screenshot prepared for the model.
public struct Shot: Sendable {
    /// The image to send to the model.
    public let png: Data
    /// Size of that image in pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The part of the screen the image shows, in screen points.
    public let screenRect: CGRect

    public init(png: Data, pixelWidth: Int, pixelHeight: Int, screenRect: CGRect) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.screenRect = screenRect
    }

    /// Converts a coordinate the model gave in image pixels to a screen point.
    public func screenPoint(imageX: Double, imageY: Double) -> CGPoint {
        CGPoint(
            x: screenRect.minX + imageX / Double(pixelWidth) * screenRect.width,
            y: screenRect.minY + imageY / Double(pixelHeight) * screenRect.height
        )
    }

    /// The reverse: where a screen point falls in the image.
    public func imagePoint(screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (screenPoint.x - screenRect.minX) / screenRect.width * Double(pixelWidth),
            y: (screenPoint.y - screenRect.minY) / screenRect.height * Double(pixelHeight)
        )
    }
}

/// EYES: screenshots of the main display. Implemented by HFEyes.
public protocol Eyes: Sendable {
    /// The size of the main display in screen points.
    var screenSize: CGSize { get }
    /// A screenshot of the whole main display, scaled so its long edge is at most `maxLongEdge` pixels.
    func grab(maxLongEdge: Int) async throws -> Shot
    /// A screenshot of one region (in screen points) at higher detail, to read small text.
    func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot
}

/// The kinds of control the agent can meet, in one shared vocabulary.
///
/// HFEyes maps the Mac's accessibility roles onto these, and the safety gate's
/// rules switch on them. Keeping the list here is what stops the two packages
/// drifting apart ("pop-up button" in one, "pop up button" in the other).
public enum ScreenRole: String, Sendable, CaseIterable, Codable {
    case button
    case link
    case textField = "text field"
    case textArea = "text area"
    case searchField = "search field"
    case passwordField = "password field"
    case menuItem = "menu item"
    case menuButton = "menu button"
    case popUpButton = "pop-up button"
    case checkbox
    case radioButton = "radio button"
    case toggle = "switch"
    case tab
    case slider
    case windowControl = "window control"  // close, minimise, zoom
    case dockItem = "Dock item"
    case menuBarItem = "menu bar item"
    case image
    case text
    case group
    case listItem = "list item"
    case row
    case cell
    case other = "control"  // anything else

    /// Somewhere text is typed.
    public var isTextEntry: Bool {
        self == .textField || self == .textArea || self == .searchField || self == .passwordField
    }

    /// Pressing Space or Return while this has keyboard focus activates it, the same as a click.
    public var activatesOnKeyPress: Bool {
        switch self {
        case .button, .link, .menuItem, .menuButton, .popUpButton, .checkbox, .radioButton, .toggle, .tab:
            return true
        default:
            return false
        }
    }

    /// Usually holds content (a message bubble, a paragraph, a photo), not a command.
    public var isContent: Bool {
        switch self {
        case .text, .group, .image, .listItem, .row, .cell, .other: return true
        default: return false
        }
    }
}

/// One control on screen, as the accessibility tree describes it.
public struct UIElementInfo: Sendable, Equatable {
    public let role: ScreenRole
    /// The best human-readable name: title, description, placeholder or help text. Empty when it has none.
    public let label: String
    /// The developer's identifier for the control, when it has one: "ChatBar_SendButton". Empty otherwise.
    /// Never shown to the user, but the safety rules read it, because an icon-only Send button
    /// often has no label and a telling identifier.
    public let identifier: String
    /// The app's display name, for people: "WhatsApp". It can be translated and can carry invisible marks.
    public let app: String
    /// The app's bundle identifier, for rules: "net.whatsapp.WhatsApp". Empty when unknown.
    /// Rules that must recognise a particular app match on this, never on the display name.
    public let appBundleIdentifier: String
    public let window: String
    public let frame: CGRect
    public let isEnabled: Bool

    public init(
        role: ScreenRole, label: String, identifier: String = "", app: String, appBundleIdentifier: String = "",
        window: String, frame: CGRect, isEnabled: Bool = true
    ) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.app = app
        self.appBundleIdentifier = appBundleIdentifier
        self.window = window
        self.frame = frame
        self.isEnabled = isEnabled
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    public var isNamed: Bool { !label.isEmpty }

    /// The lowercased words of the label and the identifier, for rules to match on:
    /// "ChatBar_SendButton" gives ["chat", "bar", "send", "button"].
    public var words: [String] { ScreenText.words(label) + ScreenText.words(identifier) }
}

/// LABELS: read-only lookups in the accessibility tree. Implemented by HFEyes.
///
/// It never clicks, types or changes anything. What it returns is what the safety
/// gate judges before every click and every key press that can commit something,
/// so a Send button must come back as a button labelled "Send", and a control
/// that cannot be named must come back with an empty label, never a guess.
/// The wording the gate and the user see is built in one place: `ScreenAction`.
public protocol Labels: Sendable {
    func element(at point: CGPoint) async -> UIElementInfo?
    func focusedElement() async -> UIElementInfo?
    /// The app and window in front.
    func frontmost() async -> (app: String, window: String)
    /// The bundle identifier of the app that holds the keyboard ("" when unknown).
    /// This is a requirement of the protocol, not only an extension method, so that the
    /// implementation's answer is the one `clickAction` and `keyAction` use.
    func frontmostBundleIdentifier() async -> String
    /// The visible, clickable controls of the front window, for grounding a click on a named control.
    func visibleControls(limit: Int) async -> [UIElementInfo]
}

public extension Labels {
    /// The default for implementations that cannot read it: "unknown".
    func frontmostBundleIdentifier() async -> String { "" }

    /// The action "click here", described from what is really under the point right now.
    /// Call this when the pointer has arrived, never before the glide: a spot can change
    /// from "Voice message" to "Send" in between.
    func clickAction(at point: CGPoint, kind: ScreenAction.Kind = .click) async -> ScreenAction {
        let front = await frontmost()
        return ScreenAction(
            kind: kind, target: await element(at: point), frontApp: front.app, frontWindow: front.window,
            frontAppBundleIdentifier: await frontmostBundleIdentifier())
    }

    /// The action "press this key", described from what really has keyboard focus right now.
    func keyAction(_ chord: KeyChord) async -> ScreenAction {
        let front = await frontmost()
        return ScreenAction(
            kind: .pressKey, key: chord, target: await focusedElement(), frontApp: front.app, frontWindow: front.window,
            frontAppBundleIdentifier: await frontmostBundleIdentifier())
    }

    /// The action "type a line break", which sends in chat apps.
    func lineBreakAction() async -> ScreenAction {
        let front = await frontmost()
        return ScreenAction(
            kind: .typeLineBreak, target: await focusedElement(), frontApp: front.app, frontWindow: front.window,
            frontAppBundleIdentifier: await frontmostBundleIdentifier())
    }
}
