import CoreGraphics
import Foundation
import HFCore

/// Turns accessibility copies into HFCore's `UIElementInfo`: a shared role, the best
/// human-readable label, and the developer identifier kept apart.
///
/// This type builds no sentences. The one wording the gate and the user see is
/// `ScreenAction.description` in HFCore, built from the fields returned here.
///
/// Rules:
/// - The label is a human-readable name or empty. It is never an identifier and never a guess.
/// - The value of a field the user types into is never a label, so typed text never leaves here.
/// - Invisible direction marks are removed (WhatsApp wraps its words and phone numbers in them).
public enum ControlNamer {
    /// Roles a click acts on. Text or an image under the pointer is described by the nearest of these above it.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXDisclosureTriangle", "AXTab", "AXSwitch", "AXToggle", "AXDockItem",
        "AXColorWell", "AXSegmentedControl",
    ]
    /// Roles whose text the user may have typed: their value is never a label.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Roles that are only a part of a control when something actionable sits above them.
    static let partRoles: Set<String> = ["AXStaticText", "AXImage", "AXGroup", "AXUnknown", ""]

    // MARK: building the contract type

    /// The HFCore description of one node.
    public static func info(
        _ node: AccessibilityNode, app: String, window: String, appBundleIdentifier: String = ""
    ) -> UIElementInfo {
        UIElementInfo(
            role: role(of: node), label: label(of: node), identifier: identifier(of: node),
            app: clean(app), appBundleIdentifier: appBundleIdentifier, window: clean(window),
            frame: node.frame, isEnabled: node.isEnabled)
    }

    /// The HFCore description of the element in a hit, with its app's bundle identifier.
    public static func info(_ node: AccessibilityNode, hit: AccessibilityHit) -> UIElementInfo {
        info(node, app: hit.app, window: hit.window, appBundleIdentifier: hit.appBundleIdentifier)
    }

    /// The element a click acts on: the hit itself, or, when the hit is only text or an
    /// image inside a button or link (Gmail's Send is the word inside a button), that button or link.
    public static func target(of hit: AccessibilityHit) -> AccessibilityNode {
        if actionableRoles.contains(hit.node.role) || !partRoles.contains(hit.node.role) { return hit.node }
        if let owner = hit.ancestors.prefix(4).first(where: { actionableRoles.contains($0.role) }) {
            return owner
        }
        return hit.node
    }

    // MARK: role

    static let subroleMap: [String: ScreenRole] = [
        "AXSearchField": .searchField, "AXSecureTextField": .passwordField, "AXTabButton": .tab,
        "AXCloseButton": .windowControl, "AXMinimizeButton": .windowControl, "AXZoomButton": .windowControl,
        "AXFullScreenButton": .windowControl, "AXSwitch": .toggle, "AXToggle": .toggle,
    ]
    static let roleMap: [String: ScreenRole] = [
        "AXButton": .button, "AXDisclosureTriangle": .button, "AXIncrementor": .button, "AXColorWell": .button,
        "AXLink": .link,
        "AXTextField": .textField, "AXComboBox": .textField, "AXTextArea": .textArea,
        "AXMenuItem": .menuItem, "AXMenuBarItem": .menuBarItem, "AXMenuButton": .menuButton,
        "AXPopUpButton": .popUpButton, "AXCheckBox": .checkbox, "AXRadioButton": .radioButton,
        "AXTab": .tab, "AXSwitch": .toggle, "AXToggle": .toggle,
        "AXSlider": .slider, "AXValueIndicator": .slider, "AXDockItem": .dockItem,
        "AXImage": .image, "AXStaticText": .text, "AXHeading": .text,
        "AXGroup": .group, "AXSegmentedControl": .group, "AXToolbar": .group, "AXScrollArea": .group,
        "AXWebArea": .group, "AXTabGroup": .group, "AXSplitGroup": .group, "AXList": .group,
        "AXTable": .group, "AXOutline": .group, "AXSheet": .group, "AXLayoutArea": .group,
        "AXRow": .row, "AXCell": .cell,
    ]

    /// The shared role for a node. Subroles win: a secure text field is a password field,
    /// a close button is a window control.
    public static func role(of node: AccessibilityNode) -> ScreenRole {
        if let bySubrole = subroleMap[node.subrole] { return bySubrole }
        // Finder shows each file as an editable name field carrying the file's URL: it is a file in a list.
        if node.role == "AXTextField" && !node.fileName.isEmpty { return .listItem }
        // Web pages expose list items as groups with this role description.
        if node.role == "AXGroup" && clean(node.roleDescription).lowercased() == "list item" { return .listItem }
        return roleMap[node.role] ?? .other
    }

    // MARK: label

    /// The best human-readable name, or "" when there is none. In order: title, description,
    /// a linked label element, the value where the value is a name (static text, a pop-up's
    /// choice), the file name, the placeholder, a recognisable child, the help text.
    public static func label(of node: AccessibilityNode) -> String {
        let editable = editableRoles.contains(node.role) || editableRoles.contains(node.subrole)
        var candidates = [node.title, node.description, node.titleElementText]
        if !editable { candidates.append(node.value) }
        candidates += [node.fileName, node.placeholder]
        let cleanedCandidates = candidates.map { clean($0) }
        if let found = cleanedCandidates.first(where: { !$0.isEmpty }) { return found }
        if let child = childName(node.children, depth: 2) { return child }
        return clean(node.help)
    }

    /// The developer identifier when it says something ("ChatBar_SendButton"); "" for none or a
    /// generated one ("_NS:179", a UUID, a bare number), which would only add noise.
    public static func identifier(of node: AccessibilityNode) -> String {
        let identifier = clean(node.identifier)
        return looksMeaningful(identifier) ? identifier : ""
    }

    /// A recognisable child: the text or image description inside an unnamed button.
    static func childName(_ children: [AccessibilityNode], depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for child in children {
            let editable = editableRoles.contains(child.role)
            for text in [child.title, child.description, editable ? "" : child.value] {
                let cleaned = clean(text)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        for child in children {
            if let found = childName(child.children, depth: depth - 1) { return found }
        }
        return nil
    }

    static func looksMeaningful(_ identifier: String) -> Bool {
        if identifier.isEmpty || identifier.hasPrefix("_NS:") || UUID(uuidString: identifier) != nil { return false }
        return identifier.contains(where: \.isLetter) && identifier.count >= 3
    }

    // MARK: text hygiene

    /// Invisible direction marks, joiners and byte-order marks.
    static let invisible = CharacterSet(charactersIn:
        "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

    /// One line, no invisible marks, no double quotes (HFCore quotes labels), at most 80 characters.
    public static func clean(_ text: String, limit: Int = 80) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !invisible.contains(scalar) {
            scalars.append(CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : scalar)
        }
        let flat = String(scalars).replacingOccurrences(of: "\"", with: "'")
        let words = flat.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard words.count > limit else { return words }
        return String(words.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
