import CoreGraphics
import HFCore
import Testing

@testable import HFDecisions

// Install, update and "allow" buttons inside an ordinary app's own window. A dedicated
// installer or updater app is refused outright by HFCore's ProtectedSurfaces; these are
// the same buttons where the window belongs to the app itself (a Sparkle update sheet,
// an App Store page, a browser permission bubble).

private func click(_ role: ScreenRole, _ label: String, identifier: String = "", app: String = "Spotify",
                   bundle: String = "com.spotify.client", window: String = "Software Update") -> ScreenAction {
    ScreenAction(kind: .click, target: UIElementInfo(
        role: role, label: label, identifier: identifier, app: app, appBundleIdentifier: bundle,
        window: window, frame: .zero))
}

@Test func installAndUpdateButtonsInsideAnOrdinaryAppAlwaysAsk() {
    for label in ["Install Update", "Install", "Update", "Update Now", "Install and Relaunch", "Relaunch",
                  "Restart Now", "Upgrade", "Download and Install", "Reinstall"] {
        #expect(RiskRules.alwaysAsk(click(.button, label)) == RiskRules.softwareChange.category, "\(label) should ask")
    }
    // Found by its identifier when the button has no label.
    #expect(RiskRules.alwaysAsk(click(.button, "", identifier: "InstallUpdateButton")) == RiskRules.softwareChange.category)
}

@Test func agreeingToAPermissionAlwaysAsks() {
    for label in ["Allow", "Always Allow", "Agree", "Trust", "Open Anyway"] {
        let action = click(.button, label, app: "Google Chrome", bundle: "com.google.Chrome", window: "Example")
        #expect(RiskRules.alwaysAsk(action) == RiskRules.softwareChange.category, "\(label) should ask")
    }
}

@Test func theWordsAloneDoNotMakeTextOrABrowsingControlRisky() {
    // A heading or a paragraph is not a button.
    #expect(RiskRules.alwaysAsk(click(.text, "Update available")) == nil)
    #expect(RiskRules.alwaysAsk(click(.group, "Install")) == nil)
    // Looking for updates, or opening a list of them, changes nothing.
    #expect(RiskRules.alwaysAsk(click(.menuItem, "Check for Updates…")) == nil)
    #expect(RiskRules.alwaysAsk(click(.button, "Updates", app: "App Store", bundle: "com.apple.AppStore", window: "App Store")) == nil)
    // An ordinary button is unaffected.
    #expect(RiskRules.alwaysAsk(click(.button, "Play", window: "Spotify Premium")) == nil)
}

@Test func theGateHoldsAnInstallButtonByRuleEvenWithJevOff() async {
    let decision = await SafetyGate(classifier: Classifiers(client: nil)).check(click(.button, "Install Update"))
    #expect(decision.label == .needsConfirmation)
    #expect(decision.source == .rule)
}
