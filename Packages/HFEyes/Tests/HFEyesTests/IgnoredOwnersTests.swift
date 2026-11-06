import CoreGraphics
import Foundation
import HFCore
import Testing

@testable import HFEyes

/// Handsfree's overlay sits above the user's app. The labels must name the app's control beneath it.
/// Here a "hit" is just the name of the app that answered, and each fake app answers its own name.
struct FakeDesk {
    static let handsfree: pid_t = 100
    static let whatsApp: pid_t = 200
    static let finder: pid_t = 300
    static let windowServer: pid_t = 50

    var systemWide: String?  // what the ordinary system-wide hit test returns
    var windows: [ScreenWindow]
    var answering: Set<pid_t> = [whatsApp, finder]
    var front: pid_t? = whatsApp
    var asked: [pid_t] = []

    static let names: [pid_t: String] = [handsfree: "Handsfree", whatsApp: "WhatsApp", finder: "Finder"]
    static func owner(_ hit: String) -> pid_t { names.first { $0.value == hit }?.key ?? 0 }

    mutating func resolve(at point: CGPoint) -> String? {
        var asked: [pid_t] = []
        let answering = self.answering
        let result = PointResolver.resolve(
            at: point,
            systemWideHit: { systemWide },
            owner: Self.owner,
            isIgnored: { $0 == Self.handsfree },
            windows: { windows },
            hitInApp: { pid in
                asked.append(pid)
                return answering.contains(pid) ? Self.names[pid] : nil
            },
            placeholder: { "unnamed in \($0.ownerName)" },
            frontApp: { front })
        self.asked = asked
        return result
    }
}

let overlay = ScreenWindow(processID: FakeDesk.handsfree, ownerName: "Handsfree", frame: CGRect(x: 0, y: 0, width: 1470, height: 956), layer: 25)
let chatWindow = ScreenWindow(processID: FakeDesk.whatsApp, ownerName: "WhatsApp", frame: CGRect(x: 100, y: 100, width: 1200, height: 800))
let finderWindow = ScreenWindow(processID: FakeDesk.finder, ownerName: "Finder", frame: CGRect(x: 0, y: 0, width: 800, height: 600))

@Test func anIgnoredWindowOnTopIsLookedThroughToTheAppBeneath() {
    // The bug seen in the demo: the system-wide hit test found Handsfree's own window.
    var desk = FakeDesk(systemWide: "Handsfree", windows: [overlay, chatWindow, finderWindow])
    #expect(desk.resolve(at: CGPoint(x: 400, y: 300)) == "WhatsApp")
    #expect(desk.asked == [FakeDesk.whatsApp])  // the frontmost app under the point, asked first
}

@Test func theOrdinaryHitIsKeptWhenItIsNotOurs() {
    var desk = FakeDesk(systemWide: "WhatsApp", windows: [overlay, chatWindow])
    #expect(desk.resolve(at: CGPoint(x: 400, y: 300)) == "WhatsApp")
    #expect(desk.asked.isEmpty)  // no extra work in the usual case
}

@Test func onlyWindowsContainingThePointAreAsked() {
    var desk = FakeDesk(systemWide: "Handsfree", windows: [overlay, chatWindow, finderWindow])
    // (50, 50) is inside Finder's window but not WhatsApp's.
    #expect(desk.resolve(at: CGPoint(x: 50, y: 50)) == "Finder")
    #expect(desk.asked == [FakeDesk.finder])
}

@Test func aTopWindowThatExposesNothingIsNamedAsItsOwnAppNeverTheWindowBeneath() {
    // A password prompt above WhatsApp that answers nothing: the click would land on the prompt,
    // so the result must be the prompt's app, never WhatsApp beneath it.
    let prompt = ScreenWindow(processID: 400, ownerName: "SecurityAgent", frame: CGRect(x: 300, y: 200, width: 400, height: 250), layer: 1000)
    var desk = FakeDesk(systemWide: nil, windows: [prompt, chatWindow])
    #expect(desk.resolve(at: CGPoint(x: 400, y: 300)) == "unnamed in SecurityAgent")
    #expect(desk.asked == [400])  // WhatsApp was never asked
    // The same when our overlay sits above the prompt.
    desk = FakeDesk(systemWide: "Handsfree", windows: [overlay, prompt, chatWindow])
    #expect(desk.resolve(at: CGPoint(x: 400, y: 300)) == "unnamed in SecurityAgent")
}

@Test func theMenuBarStripFallsBackToTheFrontApp() {
    // The menu bar strip belongs to the window server; its items belong to the front app.
    let menuBar = ScreenWindow(processID: FakeDesk.windowServer, ownerName: "Window Server", frame: CGRect(x: 0, y: 0, width: 1470, height: 33), layer: 24)
    var desk = FakeDesk(systemWide: "Handsfree", windows: [overlay, menuBar, chatWindow])
    #expect(desk.resolve(at: CGPoint(x: 18, y: 10)) == "WhatsApp")
    #expect(desk.asked == [FakeDesk.whatsApp])  // via the front app, not the window server
}

@Test func onlyOurOwnWindowsUnderThePointGiveNilNeverOurControl() {
    var desk = FakeDesk(systemWide: "Handsfree", windows: [overlay])
    desk.front = FakeDesk.handsfree
    #expect(desk.resolve(at: CGPoint(x: 400, y: 300)) == nil)
}

@Test func invisibleWindowsAreNotCandidates() {
    var faded = chatWindow
    faded.alpha = 0
    let candidates = PointResolver.candidateProcesses(
        at: CGPoint(x: 400, y: 300), windows: [overlay, faded, finderWindow], isIgnored: { $0 == FakeDesk.handsfree })
    #expect(candidates == [FakeDesk.finder])
}

@Test func defaultIgnoredOwnersAreThisProcessAndTheHandsfreeApp() {
    let ignored = IgnoredOwners.default
    #expect(ignored.contains(getpid()))
    #expect(ignored.bundleIdentifiers == ["com.handsfree.Handsfree"])
    #expect(!IgnoredOwners().contains(getpid()))
}

// MARK: protected prompts and bundle identifiers

@Test func aProtectedPromptAboveOrdinaryWindowsIsTheFrontApp() {
    let apps: [pid_t: (bundle: String, name: String)] = [
        400: ("com.apple.SecurityAgent", "SecurityAgent"),
        200: ("net.whatsapp.WhatsApp", "\u{200E}WhatsApp"),
        500: ("com.apple.dock", "Dock"),
    ]
    let appOf: (pid_t) -> (bundle: String, name: String) = { apps[$0] ?? ("", "") }
    let prompt = ScreenWindow(processID: 400, ownerName: "SecurityAgent", frame: CGRect(x: 300, y: 200, width: 400, height: 250), layer: 1000)
    let dock = ScreenWindow(processID: 500, ownerName: "Dock", frame: CGRect(x: 0, y: 880, width: 1470, height: 76), layer: 20)
    let found = SystemAccessibilitySource.protectedPromptWindow(
        in: [dock, prompt, chatWindow], isIgnored: { _ in false }, appOf: appOf)
    #expect(found?.processID == 400)
    // No prompt: ordinary windows and the Dock never count.
    #expect(SystemAccessibilitySource.protectedPromptWindow(in: [dock, chatWindow], isIgnored: { _ in false }, appOf: appOf) == nil)
    // An ordinary-layer window of a protected app (Keychain Access left open) does not count here;
    // it is only front when accessibility says it is.
    var levelled = prompt
    levelled.layer = 0
    #expect(SystemAccessibilitySource.protectedPromptWindow(in: [levelled], isIgnored: { _ in false }, appOf: appOf) == nil)
}

@Test func elementsAndTheFrontAppCarryBundleIdentifiers() async {
    let source = FakeSource()
    source.hitResult = AccessibilityHit(
        node: AccessibilityNode(role: "AXButton", description: "Send"), app: "\u{200E}WhatsApp", window: "WhatsApp",
        appBundleIdentifier: "net.whatsapp.WhatsApp")
    source.frontBundle = "net.whatsapp.WhatsApp"
    let labels = AccessibilityLabels(source: source)
    #expect(await labels.element(at: .zero)?.appBundleIdentifier == "net.whatsapp.WhatsApp")
    #expect(await labels.frontmostBundleIdentifier() == "net.whatsapp.WhatsApp")
    let action = await labels.clickAction(at: .zero)
    #expect(!action.landsOnProtectedSurface)
    // HFCore's clickAction must reach HFEyes' implementation (a protocol requirement since 5 Nov).
    #expect(action.frontAppBundleIdentifier == "net.whatsapp.WhatsApp")
    #expect(await labels.keyAction(KeyChord(key: "return")).frontAppBundleIdentifier == "net.whatsapp.WhatsApp")
}

@Test func aPasswordPromptThatExposesNothingIsStillRecognisedAsProtected() async {
    // What the system source returns for a SecurityAgent window that answered nothing.
    let source = FakeSource()
    source.hitResult = AccessibilityHit(
        node: AccessibilityNode(frame: CGRect(x: 300, y: 200, width: 400, height: 250)), app: "SecurityAgent",
        window: "", appBundleIdentifier: "com.apple.SecurityAgent")
    source.frontResult = ("SecurityAgent", "")
    source.frontBundle = "com.apple.SecurityAgent"
    let labels = AccessibilityLabels(source: source)
    let info = await labels.element(at: CGPoint(x: 400, y: 300))
    #expect(info?.label == "" && info?.appBundleIdentifier == "com.apple.SecurityAgent")
    #expect(await labels.clickAction(at: CGPoint(x: 400, y: 300)).landsOnProtectedSurface)
    // Even with no element at all, the front app identifies it.
    source.hitResult = nil
    source.focusResult = nil
    #expect(await labels.clickAction(at: .zero).landsOnProtectedSurface)
    #expect(await labels.keyAction(KeyChord(key: "return")).landsOnProtectedSurface)
}
