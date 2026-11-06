import CoreGraphics
import Foundation

/// A read-only copy of one accessibility element's attributes, taken in one go.
///
/// Copies, not live `AXUIElement`s, cross into the naming code: that keeps the naming
/// testable with a fake tree, and means nothing downstream can accidentally call an
/// accessibility action.
public struct AccessibilityNode: Sendable, Equatable {
    /// Raw accessibility role, such as "AXButton".
    public var role: String = ""
    public var subrole: String = ""
    /// The system's own words for the role, such as "button" (localised).
    public var roleDescription: String = ""
    public var title: String = ""
    /// AXDescription: what an icon-only button is usually named by.
    public var description: String = ""
    /// AXHelp: the tooltip.
    public var help: String = ""
    /// AXIdentifier: a developer's name for the control, such as "ChatBar_SendButton".
    public var identifier: String = ""
    public var placeholder: String = ""
    /// The text of a separate label element tied to this one (AXTitleUIElement).
    public var titleElementText: String = ""
    /// AXValue as text. The system source fills it only for roles where the value is a
    /// label (static text, a pop-up button's choice), NEVER for text the user can edit,
    /// so typed messages never reach the safety gate.
    public var value: String = ""
    /// The file a control stands for (from AXURL), as Finder's file name fields carry it.
    public var fileName: String = ""
    public var isEnabled: Bool = true
    /// Frame in screen points, origin top left.
    public var frame: CGRect = .zero
    /// A few levels of children, filled only when the element has no name of its own,
    /// so an icon button can be named by a recognisable child.
    public var children: [AccessibilityNode] = []

    public init(
        role: String = "", subrole: String = "", roleDescription: String = "", title: String = "",
        description: String = "", help: String = "", identifier: String = "", placeholder: String = "",
        titleElementText: String = "", value: String = "", isEnabled: Bool = true,
        frame: CGRect = .zero, children: [AccessibilityNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.help = help
        self.identifier = identifier
        self.placeholder = placeholder
        self.titleElementText = titleElementText
        self.value = value
        self.isEnabled = isEnabled
        self.frame = frame
        self.children = children
    }
}

/// What a hit test or a focus lookup found: the element, its nearest ancestors, and where it lives.
public struct AccessibilityHit: Sendable, Equatable {
    public var node: AccessibilityNode
    /// Parents, nearest first, at most a few. Used to name the button a piece of text sits in.
    public var ancestors: [AccessibilityNode]
    public var app: String
    public var window: String

    public init(
        node: AccessibilityNode, ancestors: [AccessibilityNode] = [], app: String, window: String,
        appBundleIdentifier: String = ""
    ) {
        self.node = node
        self.ancestors = ancestors
        self.app = app
        self.window = window
        self.appBundleIdentifier = appBundleIdentifier
    }

    /// The owning app's bundle identifier ("net.whatsapp.WhatsApp"), "" when unknown.
    /// The protected-surfaces rules match on it first, because display names are translated.
    public var appBundleIdentifier: String
}

/// Where the accessibility data comes from. The real one talks to macOS; tests use a fake.
///
/// Every method is synchronous and may block (an app that does not answer); the caller,
/// `AccessibilityLabels`, runs it off the caller's thread and bounds it with a deadline.
public protocol AccessibilitySource: Sendable {
    /// The element under a screen point (points, top-left origin), or nil.
    func hit(at point: CGPoint) -> AccessibilityHit?
    /// The element with keyboard focus in the front app, or nil.
    func focused() -> AccessibilityHit?
    /// The front app's name and its focused window's title ("" when there is none).
    func front() -> (app: String, window: String)
    /// The bundle identifier of the same app `front()` names, "" when unknown.
    func frontBundleIdentifier() -> String
    /// Controls of the front window, in reading order (top to bottom, left to right),
    /// with their app and window filled in.
    func controls(limit: Int) -> [AccessibilityHit]
    /// See `SystemAccessibilitySource.enableWebContent()`. Writes to other apps; opt-in.
    func enableWebContent() -> [String]
    /// Switches off what `enableWebContent()` switched on.
    func restoreWebContentSwitches() -> [String]
}

public extension AccessibilitySource {
    func frontBundleIdentifier() -> String { "" }
    /// Asks browsers and Electron apps to expose web pages. Only the system source does anything.
    func enableWebContent() -> [String] { [] }
    /// Undoes `enableWebContent()`. Only the system source does anything.
    func restoreWebContentSwitches() -> [String] { [] }
}
