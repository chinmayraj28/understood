import CoreGraphics
import Foundation
import HFCore
import Testing

@testable import HFEyes

/// A fake accessibility tree. `delay` makes every call block, to test the deadline.
final class FakeSource: AccessibilitySource, @unchecked Sendable {
    var hitResult: AccessibilityHit?
    var focusResult: AccessibilityHit?
    var frontResult: (app: String, window: String) = ("WhatsApp", "Amma")
    var controlsResult: [AccessibilityHit] = []
    var frontBundle = ""
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private var running = 0
    private(set) var mostAtOnce = 0
    private(set) var calls = 0

    func hit(at point: CGPoint) -> AccessibilityHit? { pause(); return hitResult }
    func focused() -> AccessibilityHit? { pause(); return focusResult }
    func front() -> (app: String, window: String) { pause(); return frontResult }
    func controls(limit: Int) -> [AccessibilityHit] { pause(); return Array(controlsResult.prefix(limit)) }
    func frontBundleIdentifier() -> String { pause(); return frontBundle }

    private func pause() {
        lock.lock()
        running += 1
        calls += 1
        mostAtOnce = max(mostAtOnce, running)
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        running -= 1
        lock.unlock()
    }
}

let lrm = "\u{200E}"

func whatsApp(_ node: AccessibilityNode, ancestors: [AccessibilityNode] = []) -> AccessibilityHit {
    AccessibilityHit(node: node, ancestors: ancestors, app: "\(lrm)WhatsApp", window: "\(lrm)WhatsApp")
}

// MARK: what comes back for real controls (attributes as the apps report them)

@Test func whatsAppSendButtonComesBackAsAButtonLabelledSend() async {
    // WhatsApp 2.26: the name is in AXDescription behind an invisible mark; seen live on 5 Nov.
    let send = AccessibilityNode(
        role: "AXButton", description: "\(lrm)Send", identifier: "ChatBar_SendButton",
        frame: CGRect(x: 1424, y: 823, width: 36, height: 36))
    let source = FakeSource()
    source.hitResult = whatsApp(send)
    let labels = AccessibilityLabels(source: source)
    let info = await labels.element(at: CGPoint(x: 1442, y: 841))
    #expect(info == UIElementInfo(
        role: .button, label: "Send", identifier: "ChatBar_SendButton", app: "WhatsApp", window: "WhatsApp",
        frame: CGRect(x: 1424, y: 823, width: 36, height: 36)))
    #expect(info?.words.contains("send") == true)
    // The one wording, built in HFCore from these fields.
    let action = await labels.clickAction(at: CGPoint(x: 1442, y: 841))
    #expect(action.description == "Click button \"Send\" in WhatsApp, window \"WhatsApp\"")
}

@Test func textInsideAButtonReturnsTheButton() async {
    // Gmail's Send: the pointer is over the word, the click goes to the button around it.
    let word = AccessibilityNode(role: "AXStaticText", value: "Send")
    let button = AccessibilityNode(role: "AXButton", title: "Send")
    let source = FakeSource()
    source.hitResult = AccessibilityHit(
        node: word, ancestors: [AccessibilityNode(role: "AXGroup"), button], app: "Google Chrome", window: "Inbox")
    let info = await AccessibilityLabels(source: source).element(at: .zero)
    #expect(info?.role == .button && info?.label == "Send")
}

@Test func focusedMessageFieldIsNamedButItsTypedTextNeverAppears() async {
    let field = AccessibilityNode(
        role: "AXTextArea", description: "\(lrm)Compose message", value: "secret words the user typed")
    let source = FakeSource()
    source.focusResult = whatsApp(field)
    let info = await AccessibilityLabels(source: source).focusedElement()
    #expect(info?.role == .textArea && info?.label == "Compose message")
    // With no other name, an editable field's value is still never used.
    let bare = ControlNamer.info(AccessibilityNode(role: "AXTextField", value: "my password"), app: "X", window: "")
    #expect(bare.label == "" && bare.role == .textField)
}

// MARK: roles: the Mac's roles and subroles onto HFCore's shared vocabulary

@Test(arguments: [
    (AccessibilityNode(role: "AXButton"), ScreenRole.button),
    (AccessibilityNode(role: "AXButton", subrole: "AXCloseButton"), .windowControl),
    (AccessibilityNode(role: "AXButton", subrole: "AXMinimizeButton"), .windowControl),
    (AccessibilityNode(role: "AXButton", subrole: "AXFullScreenButton"), .windowControl),
    (AccessibilityNode(role: "AXTextField", subrole: "AXSecureTextField"), .passwordField),
    (AccessibilityNode(role: "AXTextField", subrole: "AXSearchField"), .searchField),
    (AccessibilityNode(role: "AXTextField"), .textField),
    (AccessibilityNode(role: "AXTextArea"), .textArea),
    (AccessibilityNode(role: "AXRadioButton", subrole: "AXTabButton"), .tab),
    (AccessibilityNode(role: "AXCheckBox", subrole: "AXSwitch"), .toggle),
    (AccessibilityNode(role: "AXCheckBox"), .checkbox),
    (AccessibilityNode(role: "AXPopUpButton"), .popUpButton),
    (AccessibilityNode(role: "AXMenuButton"), .menuButton),
    (AccessibilityNode(role: "AXMenuItem"), .menuItem),
    (AccessibilityNode(role: "AXMenuBarItem"), .menuBarItem),
    (AccessibilityNode(role: "AXDockItem", subrole: "AXApplicationDockItem"), .dockItem),
    (AccessibilityNode(role: "AXLink"), .link),
    (AccessibilityNode(role: "AXStaticText"), .text),
    (AccessibilityNode(role: "AXImage"), .image),
    (AccessibilityNode(role: "AXRow"), .row),
    (AccessibilityNode(role: "AXCell"), .cell),
    (AccessibilityNode(role: "AXGroup", roleDescription: "list item"), .listItem),
    (AccessibilityNode(role: "AXSomethingNew"), .other),
])
func macRolesMapOntoTheSharedVocabulary(node: AccessibilityNode, expected: ScreenRole) {
    #expect(ControlNamer.role(of: node) == expected)
}

@Test func finderFileIsAListItemNamedByItsFileNotItsTypedValue() {
    var field = AccessibilityNode(role: "AXTextField", value: "half-typed rename")
    field.fileName = "report.pdf"
    let info = ControlNamer.info(field, app: "Finder", window: "Documents")
    #expect(info.role == .listItem && info.label == "report.pdf")
}

// MARK: labels: human-readable or empty, identifiers kept apart

@Test func iconButtonIsNamedByARecognisableChild() {
    let icon = AccessibilityNode(role: "AXButton", children: [
        AccessibilityNode(role: "AXGroup", children: [AccessibilityNode(role: "AXImage", description: "Move to Bin")]),
    ])
    #expect(ControlNamer.label(of: icon) == "Move to Bin")
}

@Test func helpTextIsALabelWhenNothingElseNamesIt() {
    let node = AccessibilityNode(role: "AXButton", help: "Double tap and hold to record, release to send")
    #expect(ControlNamer.label(of: node) == "Double tap and hold to record, release to send")
}

@Test func identifierNeverBecomesTheLabel() {
    let named = AccessibilityNode(role: "AXButton", identifier: "ChatBar_SendButton")
    let info = ControlNamer.info(named, app: "WhatsApp", window: "")
    #expect(info.label == "" && info.identifier == "ChatBar_SendButton")
    #expect(ScreenAction.phrase(for: info) == "an unlabelled button (identifier \"ChatBar_SendButton\") in WhatsApp")
    for generated in ["_NS:42", "123", UUID().uuidString] {
        #expect(ControlNamer.identifier(of: AccessibilityNode(role: "AXButton", identifier: generated)) == "")
    }
}

@Test func unlabelledControlsComeBackWithAnEmptyLabelNeverAGuess() async {
    let source = FakeSource()
    source.hitResult = whatsApp(AccessibilityNode(role: "AXButton"))
    let info = await AccessibilityLabels(source: source).element(at: .zero)
    #expect(info?.label == "" && info?.role == .button && info?.identifier == "")
    #expect(info.map { ScreenAction.phrase(for: $0) } == "an unlabelled button in WhatsApp, window \"WhatsApp\"")
}

@Test func disabledStateIsCarried() {
    let item = ControlNamer.info(AccessibilityNode(role: "AXMenuItem", title: "Move to Bin", isEnabled: false), app: "Finder", window: "")
    #expect(item.isEnabled == false && item.label == "Move to Bin")
}

// MARK: missing elements, timeouts and a frozen app

@Test func nothingUnderThePointerIsNil() async {
    let source = FakeSource()
    let labels = AccessibilityLabels(source: source)
    #expect(await labels.element(at: .zero) == nil)
    #expect(await labels.focusedElement() == nil)
    let action = await labels.clickAction(at: .zero)
    #expect(action.isTargetUnknown && action.description == "Click an unknown control in WhatsApp, window \"Amma\"")
}

@Test func aLookupThatTimesOutReturnsNilPromptly() async {
    let source = FakeSource()
    source.hitResult = whatsApp(AccessibilityNode(role: "AXButton", description: "Send"))
    source.delay = 1.0
    let labels = AccessibilityLabels(source: source, timeout: 0.1, controlsTimeout: 0.1)
    let start = Date()
    #expect(await labels.element(at: .zero) == nil)
    #expect(Date().timeIntervalSince(start) < 0.5)
}

@Test func aFrozenAppHoldsOneThreadAndLaterLookupsAreRefusedAtOnce() async throws {
    let source = FakeSource()
    source.hitResult = whatsApp(AccessibilityNode(role: "AXButton", description: "Send"))
    source.delay = 1.0
    let labels = AccessibilityLabels(source: source, timeout: 0.1, controlsTimeout: 0.1)
    #expect(await labels.element(at: .zero) == nil)  // timed out; still stuck on the worker
    let start = Date()
    for _ in 0..<20 {  // the agent retrying
        #expect(await labels.element(at: .zero) == nil)
        #expect(await labels.focusedElement() == nil)
    }
    #expect(Date().timeIntervalSince(start) < 0.3)  // refused at once, not waited for
    #expect(source.calls == 1 && source.mostAtOnce == 1)  // no pile-up of blocked threads
    let front = await labels.frontmost()
    #expect(front.app == "" && front.window == "")

    // Once the frozen call comes back, lookups work again.
    try await Task.sleep(for: .milliseconds(1100))
    source.delay = 0
    #expect(await labels.element(at: .zero)?.label == "Send")
}

@Test func lookupsArrivingTogetherQueueRatherThanFail() async {
    let source = FakeSource()
    source.hitResult = whatsApp(AccessibilityNode(role: "AXButton", description: "Send"))
    source.delay = 0.02
    let labels = AccessibilityLabels(source: source, timeout: 0.4)
    async let first = labels.element(at: .zero)
    async let second = labels.element(at: .zero)
    async let third = labels.focusedElement()
    let results = await [first?.label, second?.label]
    _ = await third
    #expect(results == ["Send", "Send"])
    #expect(source.mostAtOnce == 1)  // one worker: they ran one after another
}

@Test func frontmostIsCleaned() async {
    let source = FakeSource()
    source.frontResult = ("\(lrm)WhatsApp", "\u{202A}+44 7700 900123\u{202C}")
    let front = await AccessibilityLabels(source: source).frontmost()
    #expect(front.app == "WhatsApp" && front.window == "+44 7700 900123")
}

@Test func creatingTheLabelsWritesNothingAndFakesHaveNoWebSwitch() async {
    // The default source's init only sets this process's own messaging timeout; the web switch
    // is opt-in. A fake source has nothing to switch.
    let labels = AccessibilityLabels(source: FakeSource())
    #expect(await labels.enableWebContent().isEmpty)
    #expect(labels.restoreWebContentSwitches().isEmpty)
}

// MARK: text hygiene

@Test func labelsAreOneLineQuoteSafeAndShort() {
    #expect(ControlNamer.clean("Say \"hi\"\nnow\t ok") == "Say 'hi' now ok")
    let cleaned = ControlNamer.clean(String(repeating: "a", count: 200))
    #expect(cleaned.count == 80 && cleaned.hasSuffix("…"))
    #expect(ControlNamer.clean("\u{200E}\u{202A}Amma\u{202C}") == "Amma")
}

// MARK: visible controls

@Test func visibleControlsCarryRolesLabelsIdentifiersAndCentres() async {
    let source = FakeSource()
    source.controlsResult = [
        whatsApp(AccessibilityNode(role: "AXTextArea", description: "Compose message", identifier: "ChatBar_ComposerTextView",
                                   frame: CGRect(x: 100, y: 800, width: 600, height: 40))),
        whatsApp(AccessibilityNode(role: "AXButton", description: "Voice message", frame: CGRect(x: 720, y: 800, width: 40, height: 40))),
    ]
    let controls = await AccessibilityLabels(source: source).visibleControls(limit: 10)
    #expect(controls.map(\.label) == ["Compose message", "Voice message"])
    #expect(controls.map(\.role) == [.textArea, .button])
    #expect(controls[0].identifier == "ChatBar_ComposerTextView")
    #expect(controls[1].center == CGPoint(x: 740, y: 820))
    #expect(await AccessibilityLabels(source: source).visibleControls(limit: 1).count == 1)
}
