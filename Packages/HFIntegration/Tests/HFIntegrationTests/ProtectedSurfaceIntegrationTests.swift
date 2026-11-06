import CoreGraphics
import Foundation
import HFCore
import HFDecisions
import HFEyes
import HFHands
import HFScreenAgent
import HFTasks
import Testing

// HFCore's ProtectedSurfaces rule across packages: the agent never operates a
// system password or Touch ID prompt, an installer or an updater, and never types
// into a password field. On 5 Nov a Return meant for Spotlight reached Oracle's
// Java updater, which had popped up by itself, and installed an update.

/// An accessibility tree the test can change while a task runs.
final class ChangingAccessibilitySource: AccessibilitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [AccessibilityHit]
    private var focusedHit: AccessibilityHit?
    private var frontApp: (app: String, window: String)
    private var frontBundle: String

    init(hits: [AccessibilityHit], focused: AccessibilityHit?, front: (app: String, window: String), frontBundle: String = "") {
        self.hits = hits
        self.focusedHit = focused
        self.frontApp = front
        self.frontBundle = frontBundle
    }

    /// Another app takes the front and the keyboard, as an updater does when it pops up.
    func takeOver(hits newHits: [AccessibilityHit], focused: AccessibilityHit?, front: (app: String, window: String),
                  frontBundle: String = "") {
        lock.lock()
        hits = newHits + hits
        focusedHit = focused
        frontApp = front
        self.frontBundle = frontBundle
        lock.unlock()
    }

    func frontBundleIdentifier() -> String { lock.lock(); defer { lock.unlock() }; return frontBundle }

    func hit(at point: CGPoint) -> AccessibilityHit? { lock.lock(); defer { lock.unlock() }; return hits.first { $0.node.frame.contains(point) } }
    func focused() -> AccessibilityHit? { lock.lock(); defer { lock.unlock() }; return focusedHit }
    func front() -> (app: String, window: String) { lock.lock(); defer { lock.unlock() }; return frontApp }
    func controls(limit: Int) -> [AccessibilityHit] { lock.lock(); defer { lock.unlock() }; return Array(hits.prefix(limit)) }
    func enableWebContent() -> [String] { [] }
    func restoreWebContentSwitches() -> [String] { [] }
}

enum Scenery {
    static let textEditBody = axHit("AXTextArea", title: "Untitled", frame: CGRect(x: 100, y: 100, width: 1000, height: 600),
                                    app: "TextEdit", window: "Untitled")
    static let javaUpdaterInstall = axHit("AXButton", title: "Install Update", frame: CGRect(x: 600, y: 400, width: 140, height: 32),
                                          app: "Java Updater", window: "Java Update Available")
    static let installerInstall = axHit("AXButton", title: "Install", frame: CGRect(x: 900, y: 650, width: 100, height: 32),
                                        app: "Installer", window: "Install Java")
    /// As macOS reports a password field: role AXTextField, subrole AXSecureTextField.
    static let passwordField = AccessibilityHit(
        node: AccessibilityNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Password",
                                frame: CGRect(x: 500, y: 400, width: 300, height: 30)),
        app: "Safari", window: "Sign in - Bank")
}

@Suite(.serialized) struct ProtectedSurfaceIntegrationTests {

    static func agentRig(model: ScriptedModel, source: ChangingAccessibilitySource, gate: RecordingGate) -> Rig {
        let labels = AccessibilityLabels(source: source, timeout: 0.2)
        let classifiers = Classifiers(client: nil)
        return Rig(gate: gate, classifier: classifiers) { hands in
            ScreenAgent(hands: hands, eyes: FakeEyes(), labels: labels, client: model,
                        configuration: ScreenAgentConfiguration(model: "claude-sonnet-5-5", settleSeconds: 0))
        }
    }

    static func realGate() -> RecordingGate { RecordingGate(SafetyGate(classifier: Classifiers(client: nil))) }

    @Test("An updater takes the front between two key presses: the second key is never pressed")
    func updaterBetweenKeys() async throws {
        let source = ChangingAccessibilitySource(hits: [Scenery.textEditBody], focused: Scenery.textEditBody, front: ("TextEdit", "Untitled"))
        let model = ScriptedModel(turns: [
            [ScriptedModel.computer("k1", "key", ["text": "tab"]), ScriptedModel.computer("k2", "key", ["text": "Return"])],
        ])
        let gate = Self.realGate()
        let rig = Self.agentRig(model: model, source: source, gate: gate)
        rig.hands.afterAction = { action in
            if action == "key tab" {
                source.takeOver(hits: [Scenery.javaUpdaterInstall], focused: Scenery.javaUpdaterInstall,
                                front: ("Java Updater", "Java Update Available"))
            }
        }
        await rig.call("start_task", ["goal": "Indent the line in TextEdit and start a new one"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(rig.hands.actions.items.contains("key tab"))
        #expect(!rig.hands.actions.items.contains { $0.lowercased() == "key return" }, "actions: \(rig.hands.actions.items)")
        #expect(result.status == .failed)
        #expect(result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(rig.recorder.events.filter { $0.kind == .confirmation }.isEmpty, "the user must not even be asked")
        #expect(!gate.asked.items.contains { $0.contains("Java Updater") })
    }

    @Test("An updater that appears after a turn stops the task before Claude's next turn")
    func updaterBeforeNextTurn() async throws {
        let source = ChangingAccessibilitySource(hits: [Scenery.textEditBody], focused: Scenery.textEditBody, front: ("TextEdit", "Untitled"))
        let model = ScriptedModel(turns: [
            [ScriptedModel.computer("k1", "key", ["text": "tab"])],
            [ScriptedModel.computer("k2", "key", ["text": "Return"])],
        ])
        let rig = Self.agentRig(model: model, source: source, gate: Self.realGate())
        rig.hands.afterAction = { action in
            if action == "key tab" {
                source.takeOver(hits: [Scenery.javaUpdaterInstall], focused: Scenery.javaUpdaterInstall,
                                front: ("Java Updater", "Java Update Available"))
            }
        }
        await rig.call("start_task", ["goal": "Indent the line in TextEdit"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(model.requestCount == 1, "the screenshot after the first turn saw the updater; Claude was not asked again")
        #expect(rig.hands.actions.items.filter { $0.hasPrefix("key") } == ["key tab"])
    }

    @Test("An updater with a translated name is caught by its bundle identifier")
    func translatedUpdater() async throws {
        let source = ChangingAccessibilitySource(hits: [Scenery.textEditBody], focused: Scenery.textEditBody, front: ("TextEdit", "Untitled"),
                                                 frontBundle: "com.apple.TextEdit")
        let french = AccessibilityHit(
            node: AccessibilityNode(role: "AXButton", title: "Installer la mise à jour", frame: CGRect(x: 600, y: 400, width: 140, height: 32)),
            app: "Mise à jour Java", window: "Mise à jour disponible", appBundleIdentifier: "com.oracle.java.Java-Updater")
        let model = ScriptedModel(turns: [
            [ScriptedModel.computer("k1", "key", ["text": "tab"]), ScriptedModel.computer("k2", "key", ["text": "Return"])],
        ])
        let rig = Self.agentRig(model: model, source: source, gate: Self.realGate())
        rig.hands.afterAction = { action in
            if action == "key tab" {
                source.takeOver(hits: [french], focused: french, front: ("Mise à jour Java", "Mise à jour disponible"),
                                frontBundle: "com.oracle.java.Java-Updater")
            }
        }
        await rig.call("start_task", ["goal": "Indent the line in TextEdit and start a new one"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(!rig.hands.actions.items.contains { $0.lowercased() == "key return" })
    }

    @Test("A password prompt that exposes nothing to accessibility is caught by the front app's bundle identifier")
    func invisibleSecurityPrompt() async throws {
        // SecurityAgent shows no accessible controls: no focus, no name, only the front app's identity.
        let source = ChangingAccessibilitySource(hits: [], focused: nil, front: ("", ""), frontBundle: "com.apple.SecurityAgent")
        let model = ScriptedModel(turns: [[ScriptedModel.computer("k1", "key", ["text": "Return"])]])
        let rig = Self.agentRig(model: model, source: source, gate: Self.realGate())
        await rig.call("start_task", ["goal": "Open the settings"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(!rig.hands.actions.items.contains { $0.hasPrefix("key") })
    }

    @Test("Known limit: an Install Update sheet inside an ordinary app is held by the gate's word rules")
    func inAppUpdateSheet() async {
        let action = ScreenAction(kind: .click, target: UIElementInfo(
            role: .button, label: "Install Update", app: "Spotify", appBundleIdentifier: "com.spotify.client",
            window: "Software Update", frame: .zero))
        #expect(!action.landsOnProtectedSurface, "documented limit: the window belongs to Spotify")
        let decision = await SafetyGate(classifier: Classifiers(client: nil)).check(action)
        #expect(decision.label == .needsConfirmation, "\(decision.reason)")
        #expect(decision.source == .rule, "held by a fixed word rule, not only because Jev is off: \(decision.reason)")
    }

    @Test("A click whose target is in an installer is never made")
    func installerClick() async throws {
        let source = ChangingAccessibilitySource(hits: [Scenery.installerInstall], focused: nil, front: ("Installer", "Install Java"))
        let model = ScriptedModel(turns: [[ScriptedModel.computer("c1", "left_click", ["coordinate": [950, 666]])]])
        let gate = Self.realGate()
        let rig = Self.agentRig(model: model, source: source, gate: gate)
        await rig.call("start_task", ["goal": "Finish installing Java"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.status == .failed && result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(!rig.hands.actions.items.contains { $0.hasPrefix("click") })
        #expect(gate.asked.items.isEmpty, "stopped before the gate, so the user is never asked to say yes to an install")
    }

    @Test("A click on a protected window that sits behind the front app is still never made")
    func installerBehindClick() async throws {
        // The front app is fine, but the point lands on an Installer window.
        let source = ChangingAccessibilitySource(hits: [Scenery.installerInstall, Scenery.textEditBody], focused: Scenery.textEditBody,
                                                 front: ("TextEdit", "Untitled"))
        let model = ScriptedModel(turns: [[ScriptedModel.computer("c1", "left_click", ["coordinate": [950, 666]])]])
        let rig = Self.agentRig(model: model, source: source, gate: Self.realGate())
        await rig.call("start_task", ["goal": "Click the button"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(!rig.hands.actions.items.contains { $0.hasPrefix("click") })
    }

    @Test("A password field is never typed into, and the text never reaches the gate or the user")
    func passwordField() async throws {
        let source = ChangingAccessibilitySource(hits: [Scenery.passwordField], focused: Scenery.passwordField, front: ("Safari", "Sign in - Bank"))
        let model = ScriptedModel(turns: [[ScriptedModel.computer("t1", "type", ["text": "hunter2"])]])
        let gate = Self.realGate()
        let rig = Self.agentRig(model: model, source: source, gate: gate)
        await rig.call("start_task", ["goal": "Log in to my bank"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(!rig.hands.actions.items.contains { $0.hasPrefix("type") }, "actions: \(rig.hands.actions.items)")
        #expect(result.status == .failed && result.text.hasPrefix(ProtectedSurfaces.spokenRefusal), "said: \(result.text)")
        #expect(!gate.asked.items.contains { $0.contains("hunter2") })
        #expect(!rig.recorder.events.contains { $0.text.contains("hunter2") })
    }

    @Test("The gate holds every protected action as a second line, even ones that look harmless")
    func gateSecondLine() async {
        let gate = SafetyGate(classifier: Classifiers(client: nil))
        func info(_ hit: AccessibilityHit) -> UIElementInfo { ControlNamer.info(hit.node, app: hit.app, window: hit.window) }
        let cases: [(String, ScreenAction)] = [
            ("Return on the updater", ScreenAction(kind: .pressKey, key: KeyChord("return"), target: info(Scenery.javaUpdaterInstall),
                                                   frontApp: "Java Updater", frontWindow: "Java Update Available")),
            ("Tab while the updater is in front", ScreenAction(kind: .pressKey, key: KeyChord("tab"), target: nil,
                                                               frontApp: "Java Updater", frontWindow: "Java Update Available")),
            ("a text field inside the Installer", ScreenAction(kind: .click, target: UIElementInfo(
                role: .textField, label: "Name", app: "Installer", window: "Install Java", frame: .zero))),
            ("a click into a password field", ScreenAction(kind: .click, target: info(Scenery.passwordField))),
            ("a Touch ID prompt by bundle id", ScreenAction(kind: .click, target: UIElementInfo(
                role: .button, label: "Use Password", app: "", appBundleIdentifier: "com.apple.LocalAuthenticationRemoteService",
                window: "", frame: .zero))),
        ]
        for (name, action) in cases {
            #expect(action.landsOnProtectedSurface, "\(name) should be protected")
            let decision = await gate.check(action)
            #expect(decision.label == .needsConfirmation, "\(name): \(decision.reason)")
            #expect(decision.source == .rule, "\(name): held by a fixed rule, not only because Jev is off: \(decision.reason)")
        }
    }
}

// MARK: - Quick tools

/// What the app's composition root should pass to QuickTools as its guard: build the
/// ScreenAction from what really has focus or is under the point, ask the gate, allow only safe.
struct LabelsAndGateGuard: QuickActionGuarding {
    let labels: Labels
    let gate: any SafetyGating
    let asked = Log<String>()

    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict {
        let action: ScreenAction
        switch kind {
        case .pressKey: action = await labels.keyAction(key ?? KeyChord(key: "unknown"))
        case .typeLineBreak: action = await labels.lineBreakAction()
        default: action = await labels.clickAction(at: point ?? .zero, kind: kind)
        }
        asked.append(action.description)
        return await gate.check(action).label == .safe ? .allow : .refuse()
    }
}

/// The Mac as the quick tools read it: one app in front, with the keyboard somewhere in it.
struct FakeSystem: SystemReading {
    var front: FrontApp
    var focus: KeyboardFocus?
    func outputVolume() -> (percent: Double, muted: Bool)? { (50, false) }
    func displayBrightness() -> Double? { 50 }
    func frontApp() -> FrontApp? { front }
    func frontWindowFrame(pid: pid_t) -> CGRect? { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    func windowTitle(pid: pid_t) -> String { front.name }
    func appsWithWindows() -> [String] { [front.name] }
    func installedApps() -> [InstalledApp] { [] }
    func defaultBrowser() -> InstalledApp? { nil }
    func spotlightIsOpen() -> Bool { false }
    func spotlightShowsResults() -> Bool { false }
    func keyboardFocus() -> KeyboardFocus? { focus }
    func selectedText(pid: pid_t) -> String? { nil }
    func clipboardText() -> String? { nil }
    func clipboardChangeCount() -> Int { 0 }
    func screenshotFolder() -> URL { FileManager.default.temporaryDirectory }
    func newestScreenshot(since date: Date) -> URL? { nil }
    func isHostApp(_ app: FrontApp) -> Bool { false }
    func mainDisplayBounds() -> CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
}

@Suite(.serialized) struct ProtectedQuickToolIntegrationTests {

    static let whatsApp = FrontApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", pid: 501)
    static let messageBox = axHit("AXTextArea", placeholder: "Type a message", frame: CGRect(x: 400, y: 850, width: 800, height: 40),
                                  app: "WhatsApp", window: "WhatsApp")

    static func quickTools(system: FakeSystem, source: AccessibilitySource) -> ([String: ToolSpec], FakeHands, LabelsAndGateGuard) {
        let hands = FakeHands(bus: ActivityBus())
        let actionGuard = LabelsAndGateGuard(labels: AccessibilityLabels(source: source, timeout: 0.2),
                                             gate: SafetyGate(classifier: Classifiers(client: nil)))
        let tools = QuickTools.make(hands: hands, guard: actionGuard, system: system)
        return (Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }), hands, actionGuard)
    }

    @Test("\"Press enter\" with text in a WhatsApp message box is refused, not pressed")
    func enterInMessageBoxRefused() async throws {
        let source = FakeAccessibilitySource(hits: [Self.messageBox], focused: Self.messageBox, front: ("WhatsApp", "WhatsApp"))
        let system = FakeSystem(front: Self.whatsApp, focus: KeyboardFocus(appName: "WhatsApp", bundleID: Self.whatsApp.bundleID, pid: 501, role: "AXTextArea"))
        let (tools, hands, actionGuard) = Self.quickTools(system: system, source: source)
        let pressKeys = try #require(tools["press_keys"])
        let result = await pressKeys.handler(["keys": "enter"])
        #expect(result["ok"]?.boolValue == false, "result: \(result)")
        #expect(!hands.actions.items.contains { $0.hasPrefix("key") }, "pressed: \(hands.actions.items)")
        #expect(actionGuard.asked.items.contains { $0.contains("Type a message") }, "the guard judged the real focus: \(actionGuard.asked.items)")
        // A harmless key in the same place still works at once.
        let tab = await pressKeys.handler(["keys": "tab"])
        #expect(tab["ok"]?.boolValue == true, "result: \(tab)")
        #expect(hands.actions.items.contains { $0.hasPrefix("key") })
    }

    @Test("Any key is refused while an updater has the keyboard, with the shared sentence")
    func keyWhileUpdaterHasKeyboard() async throws {
        let updater = FrontApp(name: "Java Updater", bundleID: "com.oracle.java.Java-Updater", pid: 777)
        let source = FakeAccessibilitySource(hits: [Scenery.javaUpdaterInstall], focused: Scenery.javaUpdaterInstall,
                                             front: ("Java Updater", "Java Update Available"))
        let system = FakeSystem(front: updater, focus: KeyboardFocus(appName: "Java Updater", bundleID: updater.bundleID, pid: 777, role: "AXButton"))
        let (tools, hands, _) = Self.quickTools(system: system, source: source)
        for keys in ["enter", "tab", "space"] {
            let result = await tools["press_keys"]!.handler(["keys": .string(keys)])
            #expect(result["ok"]?.boolValue == false, "\(keys): \(result)")
            #expect(result["error"]?.stringValue == ProtectedSurfaces.spokenRefusal, "\(keys): \(result)")
        }
        #expect(!hands.actions.items.contains { $0.hasPrefix("key") }, "pressed: \(hands.actions.items)")
    }
}
