import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HFCore
import os

/// Reads the real accessibility tree. Read-only, with one deliberate, opt-in exception:
/// `enableWebContent()` (see there). Creating this object changes nothing in any app.
///
/// Every call into another app is bounded by the accessibility messaging timeout, so an app that
/// does not answer makes a call fail after `messagingTimeout` seconds instead of hanging.
/// `AccessibilityLabels` adds a wall-clock deadline on top.
///
/// Needs the Accessibility permission for the process (or the terminal that started it).
/// Without it every call returns nothing, which the phrases report as "an unknown control".
public final class SystemAccessibilitySource: AccessibilitySource, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.handsfree", category: "HFEyes")
    private let systemWide = AXUIElementCreateSystemWide()
    /// Set by `enableWebContent()`: from then on, browsers met for the first time are switched on too.
    private var webContentEnabled = false
    private let lock = NSLock()
    private var webContentRequested: Set<pid_t> = []
    /// Apps whose switch this object turned on (it was off before), and which switch, to undo at quit.
    private var switchedOn: [pid_t: String] = [:]

    /// How many ancestors a hit carries, to find the button a piece of text sits in.
    static let ancestorDepth = 4

    /// Owners whose windows every lookup looks through (Handsfree's overlay and panels).
    public let ignored: IgnoredOwners
    private let windowList: @Sendable () -> [ScreenWindow]

    /// - Parameters:
    ///   - messagingTimeout: the longest any one call into another app may take. Default 0.25 s.
    ///     (This setting belongs to our own process; it changes nothing in other apps.)
    ///   - ignoring: owners never reported by any lookup: by default this process and the Handsfree
    ///     app (`com.handsfree.Handsfree`). The app may pass its own set.
    public init(messagingTimeout: Float = 0.25, ignoring: IgnoredOwners = .default) {
        self.ignored = ignoring
        self.windowList = { ScreenWindow.onScreen() }
        // On the system-wide element this sets the timeout for every element of this process.
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    }

    /// Asks every running Chrome-family browser and Electron app to expose its web pages to
    /// accessibility, and keeps doing so for such apps seen later. Returns "App: switch" for each
    /// app switched on.
    ///
    /// Why: these apps build a page's accessibility tree only when an assistive app asks.
    /// Measured on this Mac (5 Nov 2026): Chrome refuses `AXManualAccessibility` (error -25205)
    /// but honours `AXEnhancedUserInterface`, VoiceOver's switch, and the page's links and
    /// buttons appear about two seconds later; Electron apps take `AXManualAccessibility`.
    /// Without it every click on a web page targets an unnamed control and the gate must ask.
    ///
    /// This writes to other apps and can take up to about a second per app that does not answer,
    /// so the app calls it once at start-up OFF the main thread, and calls
    /// `restoreWebContentSwitches()` at quit. Tests never call it.
    @discardableResult
    public func enableWebContent() -> [String] {
        lock.lock()
        webContentEnabled = true
        lock.unlock()
        var switched: [String] = []
        for app in NSWorkspace.shared.runningApplications where Self.isChromiumOrElectron(app.processIdentifier) {
            if requestWebContent(AXUIElementCreateApplication(app.processIdentifier), processID: app.processIdentifier) {
                switched.append(ControlNamer.clean(app.localizedName ?? "pid \(app.processIdentifier)"))
            }
        }
        return switched
    }

    /// True when this process may read other apps' accessibility trees. Never prompts.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: AccessibilitySource

    /// The control at a point, looking through Handsfree's own windows (see `PointResolver`).
    public func hit(at point: CGPoint) -> AccessibilityHit? {
        switch found(at: point) {
        case .element(let element):
            requestWebContentIfNeeded(for: element)  // a browser launched later, once enableWebContent() ran
            return makeHit(element)
        case .window(let window):
            // A window whose app exposes nothing at this point (a password prompt): no name, but the
            // app and its bundle identifier, which is then all that identifies it.
            let app = NSRunningApplication(processIdentifier: window.processID)
            return AccessibilityHit(
                node: AccessibilityNode(frame: window.frame), app: app?.localizedName ?? window.ownerName,
                window: "", appBundleIdentifier: app?.bundleIdentifier ?? "")
        case nil:
            return nil
        }
    }

    /// What is at a point: an accessibility element, or only a window whose app did not answer.
    enum Found {
        case element(AXUIElement)
        case window(ScreenWindow)
    }

    /// What is at a point, with ignored windows looked through (see `PointResolver`).
    func found(at point: CGPoint) -> Found? {
        func hitTest(_ root: AXUIElement) -> Found? {
            var found: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &found)
            return status == .success ? found.map { .element($0) } : nil
        }
        return PointResolver.resolve(
            at: point,
            systemWideHit: { hitTest(systemWide) },
            owner: { found in
                switch found {
                case .element(let element): return Self.processID(of: element)
                case .window(let window): return window.processID
                }
            },
            isIgnored: { ignored.contains($0) },
            windows: windowList,
            // An application element limits the hit test to that application's windows.
            hitInApp: { hitTest(AXUIElementCreateApplication($0)) },
            placeholder: { .window($0) },
            frontApp: { frontApplication()?.processIdentifier })
    }

    /// The control with keyboard focus, never one of Handsfree's own.
    public func focused() -> AccessibilityHit? {
        if let element = elementAttribute(systemWide, kAXFocusedUIElementAttribute),
            !ignored.contains(Self.processID(of: element))
        {
            requestWebContentIfNeeded(for: element)
            return makeHit(element)
        }
        guard let app = frontApplication(),
            let element = elementAttribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
        else { return nil }
        return makeHit(element)
    }

    static func processID(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    public func front() -> (app: String, window: String) {
        guard let app = frontApplication() else { return ("", "") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = elementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? elementAttribute(appElement, kAXMainWindowAttribute)
        return (app.localizedName ?? "", window.map { stringAttribute($0, kAXTitleAttribute) } ?? "")
    }

    public func frontBundleIdentifier() -> String { frontApplication()?.bundleIdentifier ?? "" }

    public func controls(limit: Int) -> [AccessibilityHit] {
        guard let app = frontApplication() else { return [] }
        return controls(processID: app.processIdentifier, limit: limit, includeMenuBar: false)
    }

    // MARK: walking a window

    /// Clickable controls of an app's focused window (and optionally its menu bar), visible on
    /// screen, in reading order. Bounded by `limit`, a node budget and a time budget.
    public func controls(
        processID: pid_t, limit: Int, includeMenuBar: Bool, timeBudget: TimeInterval = 1.5
    ) -> [AccessibilityHit] {
        let appElement = AXUIElementCreateApplication(processID)
        requestWebContent(appElement, processID: processID)
        let runningApp = NSRunningApplication(processIdentifier: processID)
        let appName = runningApp?.localizedName ?? ""
        let bundleIdentifier = runningApp?.bundleIdentifier ?? ""
        guard let window = elementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? elementAttribute(appElement, kAXMainWindowAttribute)
        else { return [] }
        let windowTitle = stringAttribute(window, kAXTitleAttribute)
        let windowFrame = frame(of: window)
        let screen = CGDisplayBounds(CGMainDisplayID())

        var roots = [window]
        if includeMenuBar, let menuBar = elementAttribute(appElement, kAXMenuBarAttribute) { roots.append(menuBar) }
        var queue = roots[...]
        var results: [AccessibilityHit] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(timeBudget)
        while let element = queue.popFirst(), visited < 5000, Date() < deadline {
            visited += 1
            let attributes = read(element, extra: [kAXChildrenAttribute])
            let node = attributes.node
            let isMenu = ["AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar"].contains(node.role)
            let onScreen = node.frame.isEmpty || node.frame.intersects(screen)
            let inWindow = node.frame.isEmpty || windowFrame.isEmpty || node.frame.intersects(windowFrame)
            if !isMenu && !(onScreen && inWindow) { continue }  // off screen: skip it and its subtree
            // Menu items are listed even when disabled ("Move to Bin" with nothing selected), marked so.
            if ControlNamer.actionableRoles.contains(node.role) && (node.isEnabled || isMenu)
                && (isMenu || (!node.frame.isEmpty && node.frame.intersects(screen)))
            {
                var named = node
                if ControlNamer.label(of: node).isEmpty { named.children = childCopies(of: element, depth: 2) }
                results.append(AccessibilityHit(
                    node: named, app: appName, window: windowTitle, appBundleIdentifier: bundleIdentifier))
            }
            queue.append(contentsOf: attributes.children)
        }
        if visited >= 5000 || Date() >= deadline {
            logger.info("controls walk stopped early after \(visited) elements")
        }
        let ordered = results.sorted {
            let rowA = ($0.node.frame.minY / 8).rounded(.down), rowB = ($1.node.frame.minY / 8).rounded(.down)
            return rowA != rowB ? rowA < rowB : $0.node.frame.minX < $1.node.frame.minX
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    // MARK: building copies

    private func makeHit(_ element: AXUIElement) -> AccessibilityHit {
        var node = read(element).node
        if ControlNamer.label(of: node).isEmpty { node.children = childCopies(of: element, depth: 2) }
        var ancestors: [AccessibilityNode] = []
        var current = element
        for _ in 0..<Self.ancestorDepth {
            guard let parent = elementAttribute(current, kAXParentAttribute) else { break }
            let parentNode = read(parent).node
            if parentNode.role == "AXWindow" || parentNode.role == "AXApplication" { break }
            ancestors.append(parentNode)
            current = parent
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let window = elementAttribute(element, kAXWindowAttribute).map { stringAttribute($0, kAXTitleAttribute) } ?? ""
        return AccessibilityHit(
            node: node, ancestors: ancestors, app: runningApp?.localizedName ?? "", window: window,
            appBundleIdentifier: runningApp?.bundleIdentifier ?? "")
    }

    private func childCopies(of element: AXUIElement, depth: Int) -> [AccessibilityNode] {
        guard depth > 0 else { return [] }
        let children = (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return children.prefix(8).map { child in
            var node = read(child).node
            node.children = childCopies(of: child, depth: depth - 1)
            return node
        }
    }

    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute,
        kAXValueAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXTitleUIElementAttribute, kAXURLAttribute,
    ]
    /// Roles whose AXValue is a name rather than something the user typed.
    private static let valueIsLabel: Set<String> = ["AXStaticText", "AXPopUpButton", "AXMenuButton", "AXHeading"]

    /// One round trip for all the attributes of one element.
    private func read(_ element: AXUIElement, extra: [String] = []) -> (node: AccessibilityNode, children: [AXUIElement]) {
        let names = Self.attributeNames + extra
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard status == .success, let values = raw as? [AnyObject], values.count == names.count else {
            return (AccessibilityNode(), [])
        }
        var byName: [String: AnyObject] = [:]
        for (name, value) in zip(names, values) where !Self.isError(value) { byName[name] = value }
        func text(_ name: String) -> String { (byName[name] as? String) ?? "" }

        var node = AccessibilityNode()
        node.role = text(kAXRoleAttribute)
        node.subrole = text(kAXSubroleAttribute)
        node.roleDescription = text(kAXRoleDescriptionAttribute)
        node.title = text(kAXTitleAttribute)
        node.description = text(kAXDescriptionAttribute)
        node.help = text(kAXHelpAttribute)
        node.identifier = text(kAXIdentifierAttribute)
        node.placeholder = text(kAXPlaceholderValueAttribute)
        if Self.valueIsLabel.contains(node.role) { node.value = text(kAXValueAttribute) }
        node.isEnabled = (byName[kAXEnabledAttribute] as? Bool) ?? true
        node.frame = Self.frame(position: byName[kAXPositionAttribute], size: byName[kAXSizeAttribute])
        // Finder shows each file name in an editable text field whose value we never read;
        // the field also carries the file's URL, which names the file without any typed text.
        if let url = byName[kAXURLAttribute] as? URL, url.isFileURL { node.fileName = url.lastPathComponent }
        if let titleElement = byName[kAXTitleUIElementAttribute], CFGetTypeID(titleElement) == AXUIElementGetTypeID() {
            let label = titleElement as! AXUIElement
            node.titleElementText = stringAttribute(label, kAXValueAttribute)
            if node.titleElementText.isEmpty { node.titleElementText = stringAttribute(label, kAXTitleAttribute) }
        }
        let children = (byName[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        return (node, children)
    }

    private static func isError(_ value: AnyObject) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect {
        var origin = CGPoint.zero, extent = CGSize.zero
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            AXValueGetValue(position as! AXValue, .cgPoint, &origin),
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return .zero }
        return CGRect(origin: origin, size: extent)
    }

    private func frame(of element: AXUIElement) -> CGRect {
        Self.frame(position: copyAttribute(element, kAXPositionAttribute), size: copyAttribute(element, kAXSizeAttribute))
    }

    // MARK: small helpers

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = copyAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        (copyAttribute(element, name) as? String) ?? ""
    }

    /// The app in front. Asks the accessibility system directly: `NSWorkspace.frontmostApplication`
    /// only updates while the main run loop turns, and was measured (by HFHands) staying wrong
    /// for seconds in a command-line process.
    ///
    /// Never Handsfree itself: if our own panel has focus, the answer is the app the user was in,
    /// taken as the owner of the frontmost ordinary window that is not ours.
    ///
    /// A protected prompt comes FIRST: a visible window of a protected app (HFCore's
    /// `ProtectedSurfaces`: password and Touch ID prompts, installers, updaters) floating above
    /// ordinary windows (layer above 0) counts as the front app, even when accessibility still names
    /// another app. A password prompt may expose nothing to accessibility and never become the
    /// "active" app, yet it takes the keyboard; then this is all that identifies it.
    private func frontApplication() -> NSRunningApplication? {
        if let prompt = protectedPrompt() { return prompt }
        if let focusedApp = elementAttribute(systemWide, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedApp, &pid) == .success, !ignored.contains(pid),
                let app = NSRunningApplication(processIdentifier: pid)
            {
                return app
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication, !ignored.contains(app.processIdentifier) { return app }
        let window = windowList().first {
            $0.layer == 0 && $0.alpha > 0 && $0.ownerName != "Window Server" && !ignored.contains($0.processID)
        }
        return window.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
    }

    /// The app of a protected prompt on screen, if there is one (see `frontApplication`).
    private func protectedPrompt() -> NSRunningApplication? {
        Self.protectedPromptWindow(in: windowList(), isIgnored: { ignored.contains($0) }) { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            return (app?.bundleIdentifier ?? "", app?.localizedName ?? "")
        }
        .flatMap { NSRunningApplication(processIdentifier: $0.processID) }
    }

    /// The frontmost visible window above the ordinary layer that belongs to a protected app.
    /// Pure, for tests: `appOf` gives a process's bundle identifier and name.
    static func protectedPromptWindow(
        in windows: [ScreenWindow], isIgnored: (pid_t) -> Bool, appOf: (pid_t) -> (bundle: String, name: String)
    ) -> ScreenWindow? {
        windows.first { window in
            guard window.layer > 0, window.alpha > 0, window.frame.width >= 40, window.frame.height >= 40,
                window.ownerName != "Window Server", !isIgnored(window.processID)
            else { return false }
            let app = appOf(window.processID)
            return ProtectedSurfaces.isProtected(bundleIdentifier: app.bundle, appName: app.name.isEmpty ? window.ownerName : app.name)
        }
    }

    // MARK: web content in Chromium and Electron apps

    /// Asks a Chromium or Electron app to build its web accessibility tree, once per process.
    /// Returns true the first time it asks. The tree appears a second or two later, so a
    /// lookup straight after the first request may still see only the browser's frame.
    @discardableResult
    private func requestWebContentIfNeeded(for element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return requestWebContent(AXUIElementCreateApplication(pid), processID: pid)
    }

    @discardableResult
    private func requestWebContent(_ appElement: AXUIElement, processID: pid_t) -> Bool {
        lock.lock()
        let optedIn = webContentEnabled
        lock.unlock()
        guard optedIn, Self.isChromiumOrElectron(processID) else { return false }
        lock.lock()
        let already = webContentRequested.contains(processID)
        webContentRequested.insert(processID)
        lock.unlock()
        guard !already else { return false }
        // Electron's switch first; Chrome rejects it as unsupported and needs VoiceOver's switch.
        let manualBefore = (copyAttribute(appElement, "AXManualAccessibility") as? Bool) ?? false
        let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual == .success {
            if !manualBefore { remember(processID, "AXManualAccessibility") }
            return true
        }
        // Chrome answers this one with an error code (-25208) yet does switch on: read it back.
        let enhancedBefore = (copyAttribute(appElement, "AXEnhancedUserInterface") as? Bool) ?? false
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let enabled = (copyAttribute(appElement, "AXEnhancedUserInterface") as? Bool) ?? false
        if enabled && !enhancedBefore { remember(processID, "AXEnhancedUserInterface") }
        logger.info("asked pid \(processID) for web accessibility: manual \(manual.rawValue), enhanced \(enabled)")
        return enabled
    }

    private func remember(_ processID: pid_t, _ attribute: String) {
        lock.lock()
        switchedOn[processID] = attribute
        lock.unlock()
    }

    /// Switches web accessibility off again in every app this object switched it on in, so
    /// the user's apps are left as they were. The app calls this when it quits. The switch
    /// persists in the other app after our process exits (verified in Chrome), so without
    /// this call it stays on until that app restarts. Returns "App: attribute" for each app restored.
    @discardableResult
    public func restoreWebContentSwitches() -> [String] {
        lock.lock()
        let toRestore = switchedOn
        switchedOn = [:]
        webContentRequested = []
        webContentEnabled = false
        lock.unlock()
        var restored: [String] = []
        for (processID, attribute) in toRestore {
            guard let app = NSRunningApplication(processIdentifier: processID) else { continue }
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(processID), attribute as CFString, kCFBooleanFalse)
            restored.append("\(ControlNamer.clean(app.localizedName ?? "pid \(processID)")): \(attribute)")
        }
        return restored
    }

    static let chromiumBundleIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func isChromiumOrElectron(_ processID: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        if let bundle = app.bundleIdentifier, chromiumBundleIdentifiers.contains(bundle) { return true }
        guard let bundleURL = app.bundleURL else { return false }
        let electron = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electron.path)
    }
}
