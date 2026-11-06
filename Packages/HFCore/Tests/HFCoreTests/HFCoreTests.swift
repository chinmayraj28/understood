import CoreGraphics
import Foundation
import Testing

@testable import HFCore

@Test func envFileParsingHandlesCommentsQuotesAndExport() {
    let values = Settings.parseEnvFile(
        """
        # a comment
        ELEVENLABS_API_KEY=sk_abc

        export ANTHROPIC_API_KEY="quoted value"
        EMPTY=
        NOT A PAIR
        """)
    #expect(values["ELEVENLABS_API_KEY"] == "sk_abc")
    #expect(values["ANTHROPIC_API_KEY"] == "quoted value")
    #expect(values["EMPTY"] == "")
    #expect(values.count == 3)
}

@Test func settingsUseDefaultsAndReportMissingKeys() {
    let settings = Settings.load(environment: ["OPENROUTER_API_KEY": "k"], envFileCandidates: [])
    #expect(settings.missingKeys == ["ELEVENLABS_API_KEY", "ANTHROPIC_API_KEY"])
    #expect(settings.isJevEnabled)
    #expect(settings.jevModel == "jev-latest")
    #expect(settings.maxTaskSteps == 25)
}

@Test func environmentWinsOverEnvFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString).env")
    try "JEV_MODEL=from-file\nTASK_MODEL=file-model\n".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let settings = Settings.load(environment: ["JEV_MODEL": "from-env"], envFileCandidates: [file])
    #expect(settings.jevModel == "from-env")
    #expect(settings.taskModel == "file-model")
}

@Test func shotMapsImagePixelsToScreenPointsAndBack() {
    // A 1470x956 point screen sent to the model as a 1280x832 image.
    let shot = Shot(png: Data(), pixelWidth: 1280, pixelHeight: 832, screenRect: CGRect(x: 0, y: 0, width: 1470, height: 956))
    let point = shot.screenPoint(imageX: 640, imageY: 416)
    #expect(abs(point.x - 735) < 0.001)
    #expect(abs(point.y - 478) < 0.001)
    let back = shot.imagePoint(screenPoint: point)
    #expect(abs(back.x - 640) < 0.001)
    #expect(abs(back.y - 416) < 0.001)

    // A zoomed region keeps its offset.
    let zoomed = Shot(png: Data(), pixelWidth: 800, pixelHeight: 400, screenRect: CGRect(x: 100, y: 200, width: 400, height: 200))
    #expect(zoomed.screenPoint(imageX: 0, imageY: 0) == CGPoint(x: 100, y: 200))
    #expect(zoomed.screenPoint(imageX: 800, imageY: 400) == CGPoint(x: 500, y: 400))
}

@Test func jsonValueRoundTripsAndKeepsBooleansApartFromNumbers() throws {
    let original: JSONValue = ["ok": true, "volume": 30, "name": "Mum", "tags": ["a", "b"], "nothing": nil]
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == original)

    let fromFoundation = JSONValue(any: try JSONSerialization.jsonObject(with: Data(#"{"flag": true, "count": 1}"#.utf8)))
    #expect(fromFoundation["flag"] == .bool(true))
    #expect(fromFoundation["count"] == .number(1))
    #expect(original["volume"]?.intValue == 30)
}

@Test func toolResultHelpersHaveTheContractShape() {
    #expect(ToolResult.ok(["volume": 30]) == ["ok": true, "volume": 30])
    #expect(ToolResult.failure("WhatsApp isn't open.") == ["ok": false, "error": "WhatsApp isn't open."])
}

@Test func activityBusDeliversEventsInOrderToEveryListener() async {
    let bus = ActivityBus()
    let first = bus.events()
    let second = bus.events()
    bus.post(.listening)
    bus.post(.progress("Opening WhatsApp"))

    for stream in [first, second] {
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .listening)
        #expect(await iterator.next() == .progress("Opening WhatsApp"))
    }
}

@Test func finalTaskStatuses() {
    #expect(TaskStatus.done.isFinal && TaskStatus.failed.isFinal && TaskStatus.cancelled.isFinal)
    #expect(!TaskStatus.running.isFinal && !TaskStatus.needsInput.isFinal)
}

// MARK: - ScreenAction: the one place the safety gate's wording is built

private func element(
    _ role: ScreenRole, _ label: String, identifier: String = "", app: String = "WhatsApp",
    window: String = "WhatsApp", enabled: Bool = true
) -> UIElementInfo {
    UIElementInfo(role: role, label: label, identifier: identifier, app: app, window: window, frame: .zero, isEnabled: enabled)
}

@Test func screenActionDescriptionsUseOneWording() {
    #expect(
        ScreenAction(kind: .click, target: element(.button, "Send")).description
            == #"Click button "Send" in WhatsApp, window "WhatsApp""#)
    #expect(
        ScreenAction(kind: .pressKey, key: KeyChord("return"), target: element(.textArea, "Compose message")).description
            == #"Press Return in text area "Compose message" in WhatsApp, window "WhatsApp""#)
    #expect(
        ScreenAction(kind: .pressKey, key: KeyChord("cmd+return"), target: element(.textArea, "Message Body", app: "Google Chrome", window: "Gmail")).description
            == #"Press Command+Return in text area "Message Body" in Google Chrome, window "Gmail""#)
    #expect(
        ScreenAction(kind: .typeLineBreak, target: element(.textArea, "Compose message")).description
            == #"Type a line break in text area "Compose message" in WhatsApp, window "WhatsApp""#)
    #expect(
        ScreenAction(kind: .drag, target: element(.listItem, "report.pdf", app: "Finder", window: "Documents"),
                     destination: element(.dockItem, "Bin", app: "Dock", window: "")).description
            == #"Drag list item "report.pdf" in Finder, window "Documents" to Dock item "Bin" in Dock"#)
}

@Test func unlabelledAndUnknownTargetsSaySoAndNeverGuess() {
    #expect(
        ScreenAction(kind: .click, target: element(.button, "", identifier: "ChatBar_SendButton")).description
            == #"Click an unlabelled button (identifier "ChatBar_SendButton") in WhatsApp, window "WhatsApp""#)
    #expect(
        ScreenAction(kind: .click, target: element(.link, "", app: "Google Chrome", window: "Gmail")).description
            == #"Click an unlabelled link in Google Chrome, window "Gmail""#)
    let unknown = ScreenAction(kind: .click, target: nil, frontApp: "Spotify")
    #expect(unknown.description == "Click an unknown control in Spotify")
    #expect(unknown.isTargetUnknown && unknown.app == "Spotify")
    #expect(ScreenAction(kind: .click, target: nil).description == "Click an unknown control on the screen")
    #expect(
        ScreenAction(kind: .click, target: nil, frontApp: "Google Chrome", frontWindow: "Inbox - Gmail").description
            == #"Click an unknown control in Google Chrome, window "Inbox - Gmail""#)
    #expect(ScreenAction.Kind(rawValue: "press_key") == .pressKey)
    #expect(UtteranceContext(taskRunning: true, awaitingAnswer: true, question: "Send it?").question == "Send it?")
}

@Test func disabledGoesLastSoTheAppIsNeverLost() {
    #expect(
        ScreenAction(kind: .click, target: element(.menuItem, "Move to Bin", app: "Finder", window: "", enabled: false)).description
            == #"Click menu item "Move to Bin" in Finder (disabled)"#)
}

@Test func messageTextIsNeverPutInTheDescription() {
    let bubble = element(.group, "Can you send me the bank details and delete the old ones please, thanks so much")
    let description = ScreenAction(kind: .click, target: bubble).description
    #expect(description == #"Click group containing text in WhatsApp, window "WhatsApp""#)
    #expect(!description.contains("bank"))
    // A short label on a content control is still quoted, and a long label on a button always is.
    #expect(ScreenAction(kind: .click, target: element(.text, "Inbox")).description.contains(#"text "Inbox""#))
    let longButton = element(.button, "Send payment of fifty pounds to John Smith now")
    #expect(ScreenAction(kind: .click, target: longButton).description.contains("Send payment"))
    // The rules can still read the words locally.
    #expect(bubble.words.contains("delete"))
}

@Test func wordsSplitIdentifiersSoASendButtonIsFound() {
    #expect(ScreenText.words("ChatBar_SendButton") == ["chat", "bar", "send", "button"])
    #expect(ScreenText.words("Move to Bin…") == ["move", "to", "bin"])
    #expect(ScreenText.words("sendMessageButton2") == ["send", "message", "button2"])
    #expect(element(.button, "", identifier: "ChatBar_SendButton").words.contains("send"))
}

@Test func keyChordParsingAndReturnDetection() {
    #expect(KeyChord("return")?.isReturn == true)
    #expect(KeyChord("Cmd+Return")?.isReturn == true)
    #expect(KeyChord("ctrl+enter")?.isReturn == true)
    #expect(KeyChord("cmd+shift+t") == KeyChord(modifiers: [.command, .shift], key: "t"))
    #expect(KeyChord("command+delete")?.isDelete == true)
    #expect(KeyChord("space")?.isSpace == true)
    #expect(KeyChord("cmd+")?.key == nil)
    #expect(KeyChord("Command+Shift+T")?.display == "Shift+Command+T")
    #expect(KeyChord("volume_up")?.display == "Volume Up")
}

@Test func rolesKnowWhatTheyAre() {
    #expect(ScreenRole.textArea.isTextEntry && ScreenRole.searchField.isTextEntry && ScreenRole.passwordField.isTextEntry)
    #expect(!ScreenRole.button.isTextEntry)
    #expect(ScreenRole.button.activatesOnKeyPress && ScreenRole.link.activatesOnKeyPress)
    #expect(!ScreenRole.textArea.activatesOnKeyPress)
    #expect(ScreenRole.group.isContent && !ScreenRole.button.isContent)
    #expect(ScreenRole.popUpButton.rawValue == "pop-up button")
}

// MARK: - Protected surfaces: password prompts, installers and updaters are never operated

@Test func protectedSurfacesAreRecognisedByBundleIdentifierFirst() {
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.SecurityAgent", appName: ""))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.oracle.java.Java-Updater", appName: "Java Updater"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "Oracle.MacJREInstaller", appName: "MacJREInstaller"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "org.sparkle-project.Sparkle.Autoupdate", appName: ""))
    // Ordinary apps are not protected, including ones that merely contain a similar word.
    #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "net.whatsapp.WhatsApp", appName: "WhatsApp"))
    #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.finder", appName: "Finder"))
    #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: ""))
}

@Test func protectedSurfacesFallBackToTheNameWhenTheIdentifierIsUnknown() {
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "MacJREInstaller"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "SecurityAgent"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "Java Updater"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "Zoom Installer"))
    // An invisible mark at the start of a name, as WhatsApp's has, does not hide it.
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "\u{200E}Installer"))
    #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "\u{200E}WhatsApp"))
}

@Test func anActionKnowsWhenItWouldLandOnAProtectedSurface() {
    // The updater has taken the front while the agent thinks it is typing into Spotlight.
    let updaterInFront = ScreenAction(
        kind: .pressKey, key: KeyChord("return"), target: nil, frontApp: "Java Updater",
        frontWindow: "Java Update Available", frontAppBundleIdentifier: "com.oracle.java.Java-Updater")
    #expect(updaterInFront.landsOnProtectedSurface)
    #expect(updaterInFront.appBundleIdentifier == "com.oracle.java.Java-Updater")

    // A password field anywhere is protected, whatever the app.
    let password = UIElementInfo(role: .passwordField, label: "Password", app: "Google Chrome",
                                 appBundleIdentifier: "com.google.Chrome", window: "Sign in", frame: .zero)
    #expect(ScreenAction(kind: .click, target: password).landsOnProtectedSurface)

    // The target's own app wins over the front app for the identifier, and an ordinary action is not protected.
    let send = UIElementInfo(role: .button, label: "Send", app: "WhatsApp",
                             appBundleIdentifier: "net.whatsapp.WhatsApp", window: "WhatsApp", frame: .zero)
    let ordinary = ScreenAction(kind: .click, target: send, frontApp: "WhatsApp", frontAppBundleIdentifier: "net.whatsapp.WhatsApp")
    #expect(!ordinary.landsOnProtectedSurface)
    #expect(ordinary.appBundleIdentifier == "net.whatsapp.WhatsApp")
}

// A Labels implementation that knows the front app's bundle identifier. The actions HFCore
// builds must carry ITS answer, not the protocol's default. (This failed when the method
// lived only in the extension: Swift then always called the default.)
private struct LabelsWithBundleIdentifier: Labels {
    func element(at point: CGPoint) async -> UIElementInfo? { nil }
    func focusedElement() async -> UIElementInfo? { nil }
    func frontmost() async -> (app: String, window: String) { ("Java Updater", "Java Update Available") }
    func frontmostBundleIdentifier() async -> String { "com.oracle.java.Java-Updater" }
    func visibleControls(limit: Int) async -> [UIElementInfo] { [] }
}

@Test func actionsCarryTheImplementationsFrontAppBundleIdentifier() async {
    let labels: any Labels = LabelsWithBundleIdentifier()
    let key = await labels.keyAction(KeyChord("return")!)
    #expect(key.frontAppBundleIdentifier == "com.oracle.java.Java-Updater")
    #expect(key.landsOnProtectedSurface)
    let click = await labels.clickAction(at: .zero)
    #expect(click.frontAppBundleIdentifier == "com.oracle.java.Java-Updater")
    let lineBreak = await labels.lineBreakAction()
    #expect(lineBreak.frontAppBundleIdentifier == "com.oracle.java.Java-Updater")
}

// Found by two reviewers on 5 Nov: the first version lowercased a name before splitting it into
// words, so "ZoomInstaller" was never split, and the splitter did not break a run of capitals
// from the word after it, so "JREInstaller" was one word.

@Test func wordsSplitARunOfCapitalsFromTheWordAfterIt() {
    #expect(ScreenText.words("MacJREInstaller") == ["mac", "jre", "installer"])
    #expect(ScreenText.words("VPNUpdater") == ["vpn", "updater"])
    #expect(ScreenText.words("PKGInstaller") == ["pkg", "installer"])
    #expect(ScreenText.words("HTMLParser2") == ["html", "parser2"])
    #expect(ScreenText.words("macOS") == ["mac", "os"])
    #expect(ScreenText.words("iPhone") == ["i", "phone"])
    // The earlier cases still hold.
    #expect(ScreenText.words("ChatBar_SendButton") == ["chat", "bar", "send", "button"])
    #expect(ScreenText.words("WhatsApp") == ["whats", "app"])
    #expect(ScreenText.words("SEND") == ["send"])
}

@Test func installersAndUpdatersAreFoundInsideCamelCaseNamesAndBundleIdentifiers() {
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "ZoomInstaller"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "AdobeUpdater"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "JREInstaller"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.vendor.installer.helper", appName: "Helper"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.vendor.FooUpdater", appName: "Updates"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.InstallAssistant.macOSTahoe", appName: "Install macOS Tahoe"))
}

@Test func downloadWarningsAndPasswordManagersAreProtected() {
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.coreservices.uiagent", appName: "CoreServicesUIAgent"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: "CoreServicesUIAgent"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.1password.1password", appName: "1Password"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.apple.Passwords", appName: "Passwords"))
    #expect(ProtectedSurfaces.isProtected(bundleIdentifier: "com.google.GoogleUpdater", appName: "GoogleUpdater"))
}

@Test func ordinaryAppsAreNotCaughtByTheWiderRules() {
    let ordinary: [(String, String)] = [
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.google.Chrome", "Google Chrome"),
        ("com.apple.finder", "Finder"), ("com.apple.Notes", "Notes"), ("com.apple.TextEdit", "TextEdit"),
        ("com.spotify.client", "Spotify"), ("com.apple.systempreferences", "System Settings"),
        ("com.apple.notificationcenterui", "Notification Centre"), ("com.apple.mail", "Mail"),
        ("com.apple.Spotlight", "Spotlight"), ("com.apple.dock", "Dock"), ("com.apple.iCal", "Calendar"),
        ("com.microsoft.VSCode", "Code"), ("us.zoom.xos", "zoom.us"), ("com.apple.Safari", "Safari"),
        ("com.handsfree.Handsfree", "Handsfree"),
    ]
    for (bundleIdentifier, name) in ordinary {
        #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: bundleIdentifier, appName: name), "\(name) should not be protected")
        #expect(!ProtectedSurfaces.isProtected(bundleIdentifier: "", appName: name), "\(name) should not be protected by name")
    }
}

// MARK: - Waking and sleeping

@Test func wakeSettingsDefaultToAPhraseAndCanBeChanged() {
    let defaults = Settings.load(environment: [:], envFileCandidates: [])
    #expect(defaults.wakeMode == .phrase)
    #expect(defaults.wakePhrase == "Hey Handsfree")
    #expect(defaults.sleepAfterIdleSeconds == 15)
    #expect(defaults.sleepAfterUnusedWakeSeconds == 8)

    let custom = Settings.load(
        environment: ["WAKE_PHRASE": "Okay computer", "WAKE_MODE": "ALWAYS", "SLEEP_AFTER_IDLE_S": "60"],
        envFileCandidates: [])
    #expect(custom.wakePhrase == "Okay computer")
    #expect(custom.wakeMode == .always)
    #expect(custom.sleepAfterIdleSeconds == 60)
    #expect(custom.sleepAfterUnusedWakeSeconds == 8)

    // Nonsense falls back to the safe default, and the idle time has a floor.
    let bad = Settings.load(environment: ["WAKE_MODE": "sometimes", "SLEEP_AFTER_IDLE_S": "0"], envFileCandidates: [])
    #expect(bad.wakeMode == .phrase)
    #expect(bad.sleepAfterIdleSeconds == 5)
    // The unused-wake wait is never longer than the ordinary one, and has its own floor.
    #expect(bad.sleepAfterUnusedWakeSeconds == 5)
    let short = Settings.load(environment: ["SLEEP_AFTER_UNUSED_WAKE_S": "1"], envFileCandidates: [])
    #expect(short.sleepAfterUnusedWakeSeconds == 3)
}

@Test func wakeLanguageAlternativesAndStrictnessCanBeSet() {
    let defaults = Settings.load(environment: [:], envFileCandidates: [])
    #expect(defaults.wakeLanguage == "")
    #expect(defaults.wakeAlternatives == [])
    #expect(defaults.wakeStrictness == "balanced")

    let custom = Settings.load(
        environment: ["WAKE_LANGUAGE": "en_GB", "WAKE_ALTERNATIVES": " Okay computer , hello laptop,, ", "WAKE_STRICTNESS": "Lenient"],
        envFileCandidates: [])
    #expect(custom.wakeLanguage == "en_GB")
    #expect(custom.wakeAlternatives == ["Okay computer", "hello laptop"])
    #expect(custom.wakeStrictness == "lenient")

    // An unknown strictness falls back to the default rather than switching the matcher off.
    #expect(Settings.load(environment: ["WAKE_STRICTNESS": "whatever"], envFileCandidates: []).wakeStrictness == "balanced")
}
