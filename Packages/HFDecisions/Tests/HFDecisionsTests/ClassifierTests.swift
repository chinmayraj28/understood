import Foundation
import HFCore
import Testing
@testable import HFDecisions

@Suite("Speech normalising")
struct SpeechTextTests {
    @Test(arguments: [
        ("Stop!", "stop"), ("stop... stop it", "stop it"), ("uh, wait", "wait"), ("STOP STOP STOP", "stop"),
        ("okay, please stop", "stop"), ("stop it stop it", "stop it"), ("stop stopping", "stop stopping"),
        ("I’m done", "i'm done"),
    ])
    func normalises(text: String, expected: String) {
        #expect(SpeechText.normalise(text) == expected)
    }
}

@Suite("Utterance: cancel, command or other")
struct UtteranceTests {
    @Test(arguments: ["stop", "Stop!", "stop... stop it", "uh, wait", "hang on", "never mind", "no wait, don't", "cancel that", "I said stop"])
    func exactStopPhrasesCancelWithoutTheNetwork(text: String) async {
        let decision = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: working)
        #expect(decision.label == .cancel)
        #expect(decision.source == .rule)
    }

    @Test(arguments: ["disabled", "down", "slow"])
    func stopTheMusicIsNotACancelUnderTheFallback(jev: String) async {
        let subject: Classifiers = switch jev {
        case "disabled": classifiers(nil)
        case "down": classifiers(.failing)
        default: classifiers(.slow(seconds: 1), timeoutSeconds: 0.1)
        }
        for text in ["stop the music", "pause the video", "stop the timer"] {
            let decision = await subject.classifyUtterance(text, context: working)
            #expect(decision.label == .command, "\(text): \(decision)")
            #expect(decision.source == .keywords)
        }
    }

    @Test func jevDownStillCancelsOnALaterStopClause() async {
        let decision = await classifiers(.failing).classifyUtterance("ugh, that's the wrong file, stop", context: working)
        #expect(decision.label == .cancel)
        #expect(decision.source == .keywords)
    }

    @Test(arguments: [
        "wait, wrong chat", "wait wrong chat", "Wait... that's the wrong Priya", "hold on, not that one",
        "hang on that's not right", "no no, the other one", "stop, you're in the wrong window",
        "stop that's wrong", "whoa, wrong file", "uh, wait, also add Sam", "stop it now please",
    ])
    func aLeadingBrakeCancelsWithoutJevWhileWorking(text: String) async {
        let decision = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: working)
        #expect(decision.label == .cancel, "\(text): \(decision)")
        #expect(decision.source == .rule)
    }

    @Test(arguments: [
        "wait for the page to load, then scroll", "wait until it finishes loading", "wait five seconds and then click Next",
        "wait 10 seconds", "stop the music", "stop playing the video", "hold on to that file for later",
        "waiting is fine, take your time", "no, the other Priya",
    ])
    func instructionsAboutWaitingAndStoppingSomethingElseGoToJev(text: String) async {
        let transport = utteranceSays(command: 0.9, other: 0.1)
        let decision = await classifiers(transport).classifyUtterance(text, context: working)
        #expect(decision.label != .cancel, "\(text): \(decision)")
        #expect(transport.callCount == 1, "\(text) should reach Jev")
    }

    @Test func theLeadingBrakeDoesNotApplyWhileAnAnswerIsAwaited() async {
        let decision = await classifiers(utteranceSays(answer: 0.95, other: 0.05))
            .classifyUtterance("wait, make it four o'clock", context: awaiting)
        #expect(decision.label == .other)
    }

    @Test func slowJevFallsBackQuickly() async {
        let start = ContinuousClock.now
        let decision = await classifiers(.slow(seconds: 1), timeoutSeconds: 0.15)
            .classifyUtterance("that is not right", context: working)
        #expect(decision.source == .keywords)
        #expect(decision.label == .other)
        #expect(elapsedMilliseconds(since: start) < 500)
    }

    @Test(arguments: ["Shah", "yes", "the second one", "yes send it", "no", "wait", "hang on", "no, the other Priya"])
    func anAnswerNeverCancelsWhenJevIsUnavailable(text: String) async {
        for subject in [classifiers(.failing), classifiers(nil)] {
            let decision = await subject.classifyUtterance(text, context: awaiting)
            #expect(decision.label != .cancel, "\(text): \(decision)")
        }
    }

    @Test func aPauseWordWhileAskedIsNotACancelAndNeedsNoNetwork() async {
        let decision = await classifiers(.mustNotBeCalled).classifyUtterance("hang on", context: awaiting)
        #expect(decision.label == .other)
        #expect(decision.source == .rule)
    }

    @Test func aBareNoIsNeverAnInstantCancel() async {
        // The voice agent's own "Anything else?" is not a task question, so "no" goes to Jev.
        let jevSaysAnswer = await classifiers(utteranceSays(answer: 0.9, other: 0.1)).classifyUtterance("no", context: working)
        #expect(jevSaysAnswer.label == .other)
        #expect(jevSaysAnswer.source == .jev)
        let jevDown = await classifiers(.failing).classifyUtterance("no", context: working)
        #expect(jevDown.label == .other)
        // "no no" said first is a brake, unlike a single "no".
        let repeated = await classifiers(.mustNotBeCalled).classifyUtterance("no no no", context: working)
        #expect(repeated.label == .cancel)
    }

    @Test func aBareNoWhileAwaitingIsAnAnswer() async {
        let decision = await classifiers(utteranceSays(cancel: 0.3, answer: 0.7)).classifyUtterance("no", context: awaiting)
        #expect(decision.label == .other)
    }

    @Test(arguments: ["No, don't", "don't", "cancel that", "I said no", "no don't", "never mind", "cancel", "wait"])
    func declinePhrasesWhileAskedAreAnswersWithoutTheNetwork(text: String) async {
        let whileAsked = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: awaiting)
        #expect(whileAsked.label == .other, "\(text)")
        #expect(whileAsked.source == .rule)
        let whileWorking = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: working)
        #expect(whileWorking.label == .cancel, "\(text) while working")
    }

    @Test(arguments: ["stop", "stop everything", "cancel the task", "abort", "never mind, forget it", "Stop! Stop!"])
    func endTaskPhrasesCancelEvenWhileAsked(text: String) async {
        let decision = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: awaiting)
        #expect(decision.label == .cancel, "\(text)")
        #expect(decision.source == .rule)
    }

    @Test func aCorrectionAfterNoIsNotACancelEvenWhenJevIsDown() async {
        let decision = await classifiers(.failing).classifyUtterance("no, don't, say fifteen minutes", context: awaiting)
        #expect(decision.label == .other)
    }

    @Test func everyEndTaskPhraseAlsoCancelsWhileWorking() {
        #expect(UtteranceRules.endTaskPhrases.isSubset(of: UtteranceRules.hardCancel))
    }

    @Test func hardStopStillCancelsWhileAsked() async {
        let decision = await classifiers(.mustNotBeCalled).classifyUtterance("stop", context: awaiting)
        #expect(decision.label == .cancel)
    }

    @Test func awaitingAnAnswerRaisesTheCancelBar() async {
        let justUnder = Thresholds.cancelWhileAwaiting - 0.05
        let transport = utteranceSays(cancel: justUnder, answer: 1 - justUnder)
        let whileAsked = await classifiers(transport).classifyUtterance("no, don't send it", context: awaiting)
        #expect(whileAsked.label == .other)
        let whileWorking = await classifiers(transport).classifyUtterance("no, don't send it", context: working)
        #expect(whileWorking.label == .cancel)
    }

    @Test func answerMapsToOther() async {
        let decision = await classifiers(utteranceSays(command: 0.05, answer: 0.95)).classifyUtterance("yes send it", context: awaiting)
        #expect(decision.label == .other)
        #expect(decision.source == .jev)
    }

    @Test func aRunningTaskCancelsOnAPlausibleCancel() async {
        let decision = await classifiers(utteranceSays(cancel: 0.45, command: 0.3, other: 0.25))
            .classifyUtterance("argh, not that chat", context: working)
        #expect(decision.label == .cancel)
        #expect(decision.source == .jev)
    }

    @Test func lowConfidenceFallsBackToKeywords() async {
        let decision = await classifiers(utteranceSays(cancel: 0.2, command: 0.3, answer: 0.2, other: 0.3))
            .classifyUtterance("hmm maybe the thing", context: working)
        #expect(decision.source == .keywords)
        #expect(decision.label == .other)
    }

    @Test func emptyOrFillerOnlyIsOther() async {
        for text in ["", "   ", "uh um"] {
            let decision = await classifiers(.mustNotBeCalled).classifyUtterance(text, context: working)
            #expect(decision.label == .other)
        }
    }
}

@Suite("Risk: structured on-screen actions")
struct RiskTests {
    static let neutral = click(.button, "Archive", app: "Google Chrome", window: "Inbox - Gmail")

    @Test(arguments: ["error", "network", "timeout", "low confidence", "malformed", "disabled"])
    func neverFailsOpen(jev: String) async {
        let subject: Classifiers = switch jev {
        case "error": classifiers(.failing)
        case "network": classifiers(.brokenNetwork)
        case "timeout": classifiers(.slow(seconds: 1), timeoutSeconds: 0.1)
        case "low confidence": classifiers(riskSays(safe: 0.85))
        case "malformed": classifiers(.respond(json: ["answers": [:] as [String: Any]]))
        default: classifiers(nil)
        }
        let decision = await subject.classifyRisk(Self.neutral)
        #expect(decision.label == .needsConfirmation, "\(jev): \(decision)")
    }

    @Test func confidentSafePassesAndJevSeesOnlyTheDescription() async throws {
        let transport = riskSays(safe: 0.97)
        let decision = await classifiers(transport).classifyRisk(Self.neutral)
        #expect(decision.label == .safe)
        #expect(decision.source == .jev)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.lastRequest?.httpBody))
        #expect(body["state"]?["action"] == .string(Self.neutral.description))
    }

    static let alwaysAsk: [(String, ScreenAction)] = [
        ("Send in WhatsApp", whatsAppSend),
        ("Voice message in WhatsApp", click(.button, "Voice message", app: "WhatsApp", window: "WhatsApp")),
        ("Return in the message box", ScreenAction(kind: .pressKey, key: KeyChord("return"), target: whatsAppBox)),
        ("Shift+Return in the message box", ScreenAction(kind: .pressKey, key: KeyChord("shift+return"), target: whatsAppBox)),
        ("Command+Return in Mail", press("cmd+return", .textArea, "Message Body", app: "Mail", window: "New Message")),
        ("Control+Enter in Gmail", press("ctrl+enter", .textArea, "Message Body", app: "Google Chrome", window: "Gmail")),
        ("line break in the message box", ScreenAction(kind: .typeLineBreak, target: whatsAppBox)),
        ("line break with unknown focus", lineBreak(nil, app: "Notes", window: "Notes")),
        ("line break in a form field", lineBreak(.textField, "Subject", app: "Mail", window: "New Message")),
        ("Space on a focused Send", press("space", .button, "Send", app: "WhatsApp", window: "WhatsApp")),
        ("Return on a focused Submit", press("return", .button, "Submit", app: "Google Chrome", window: "Job application")),
        ("identifier only", click(.button, identifier: "ChatBar_SendButton", app: "WhatsApp", window: "WhatsApp")),
        ("identifier only, ordinary window", click(.button, identifier: "composeSendBtn", app: "Google Chrome", window: "Acme Support")),
        ("unlabelled button in WhatsApp", click(.button, app: "WhatsApp", window: "WhatsApp")),
        ("unlabelled group in WhatsApp", click(.group, app: "WhatsApp", window: "WhatsApp")),
        ("unlabelled link in Gmail", click(.link, app: "Google Chrome", window: "Inbox - Gmail")),
        ("unlabelled image in WhatsApp Web", click(.image, app: "Google Chrome", window: "WhatsApp")),
        ("unknown control in WhatsApp", clickUnknown(in: "WhatsApp", window: "WhatsApp")),
        ("Return with unknown focus in Slack", pressWithUnknownFocus("return", in: "Slack", window: "general")),
        ("Return in a form field", press("return", .textField, "Email", app: "Google Chrome", window: "Sign up")),
        ("Delete on a selected email", press("delete", .row, "Weekly report", app: "Mail", window: "Inbox")),
        ("Command+Delete in Finder", press("cmd+delete", .listItem, "report.pdf", app: "Finder", window: "Documents")),
        ("Shift+Command+D in Mail", press("shift+cmd+d", .textArea, "Message Body", app: "Mail", window: "New Message")),
        ("drag to the Bin", drag(element(.listItem, "report.pdf", app: "Finder"), to: element(.dockItem, "Bin", app: "Dock"))),
        ("drag onto Mail", drag(element(.listItem, "invoice.pdf", app: "Finder"), to: element(.dockItem, "Mail", app: "Dock"))),
        ("drag to nowhere known", drag(element(.listItem, "report.pdf", app: "Finder"), to: nil)),
        ("Save on a calendar event", click(.button, "Save", app: "Google Chrome", window: "Google Calendar - Event details")),
        ("Empty Bin menu item", click(.menuItem, "Empty Bin…", app: "Finder")),
        ("Place your order", click(.button, "Place your order", app: "Google Chrome", window: "Checkout")),
        ("Join now", click(.button, "Join now", app: "Google Chrome", window: "Meet - Team sync")),
        ("disabled Send still asks", click(.button, "Send", app: "WhatsApp", window: "WhatsApp", enabled: false)),
        ("Log out row", click(.row, "Log out", app: "WhatsApp", window: "WhatsApp")),
    ]

    @Test(arguments: alwaysAsk)
    func fixedRulesAskEvenWhenJevSaysSafe(name: String, action: ScreenAction) async {
        let decision = await classifiers(riskSays(safe: 0.99)).classifyRisk(action)
        #expect(decision.label == .needsConfirmation, "\(name): \(action.description)")
        #expect(decision.source == .rule, "\(name)")
    }

    static let plainlySafe: [(String, ScreenAction)] = [
        ("Return in WhatsApp search", press("return", .searchField, "Search", app: "WhatsApp", window: "WhatsApp")),
        ("Return in Chrome's address bar", press("return", .textField, "Address and search bar", app: "Google Chrome", window: "New Tab")),
        ("click the message box", ScreenAction(kind: .click, target: whatsAppBox)),
        ("click an unlabelled text box", click(.textArea, app: "WhatsApp", window: "WhatsApp")),
        ("open a chat", click(.row, "Amma", app: "WhatsApp", window: "WhatsApp")),
        ("menu bar item", click(.menuBarItem, "File", app: "Finder")),
        ("unlabelled button in Finder", click(.button, app: "Finder", window: "Downloads")),
        ("unknown control in Spotify", clickUnknown(in: "Spotify")),
        ("unknown control in Terminal", clickUnknown(in: "Terminal", window: "zsh")),
        ("Delete in the message box", ScreenAction(kind: .pressKey, key: KeyChord("delete"), target: whatsAppBox)),
        ("Space in the message box", ScreenAction(kind: .pressKey, key: KeyChord("space"), target: whatsAppBox)),
        ("right-click a chat", ScreenAction(kind: .rightClick, target: element(.row, "Amma", app: "WhatsApp", window: "WhatsApp"))),
        ("line break in a search field", lineBreak(.searchField, "Search", app: "Finder", window: "Documents")),
        ("click a Dock item", click(.dockItem, "WhatsApp", app: "Dock")),
        ("click a disabled Archive", click(.button, "Archive", app: "Google Chrome", window: "Gmail", enabled: false)),
    ]

    @Test(arguments: plainlySafe)
    func plainlySafeActionsSkipTheNetwork(name: String, action: ScreenAction) async {
        let decision = await classifiers(.mustNotBeCalled).classifyRisk(action)
        #expect(decision.label == .safe, "\(name): \(action.description)")
        #expect(decision.source == .rule, "\(name)")
    }

    /// The screen agent opens every app through Spotlight. With Spotlight open the front app is
    /// still the previous one (Orca here), so the rule reads the focused control's own app.
    @Test(arguments: [
        // Exactly as HFEyes read it live on this Mac (role AXTextField, subrole AXSearchField).
        ScreenAction(kind: .pressKey, key: KeyChord("return"),
                     target: element(.searchField, "Spotlight Search", identifier: "SpotlightSearchField",
                                     app: "Spotlight", window: "Spotlight"),
                     frontApp: "Spotlight", frontWindow: "Spotlight"),
        // Fallbacks in case a later macOS or a stale front app reports it differently.
        ScreenAction(kind: .pressKey, key: KeyChord("return"),
                     target: element(.textField, app: "Spotlight"), frontApp: "Orca", frontWindow: "Orca"),
        ScreenAction(kind: .pressKey, key: KeyChord("return"),
                     target: element(.textField, "Spotlight Search", app: "Spotlight"), frontApp: "Orca"),
        ScreenAction(kind: .pressKey, key: KeyChord("return"),
                     target: element(.searchField, "Search", app: "Spotlight"), frontApp: "Orca"),
        ScreenAction(kind: .typeLineBreak, target: element(.textField, app: "Spotlight"), frontApp: "Orca"),
    ])
    func returnInSpotlightIsSafeByRule(action: ScreenAction) async {
        let decision = await classifiers(.mustNotBeCalled).classifyRisk(action)
        #expect(decision.label == .safe, "\(action.description)")
        #expect(decision.source == .rule)
    }

    @Test func spotlightIsRecognisedByRoleOrItsOwnAppNotByPlaceholderWords() {
        // Another app showing the words "Spotlight Search" in a plain text field gets no exemption.
        let lookalike = press("return", .textField, "Spotlight", app: "Notes", window: "Notes")
        #expect(!RiskRules.isPlainlySafe(lookalike))
        // The real field, as read live: role search field, identifier SpotlightSearchField, app Spotlight.
        let real = ScreenAction(kind: .pressKey, key: KeyChord("return"),
                                target: element(.searchField, "Spotlight Search", identifier: "SpotlightSearchField",
                                                app: "Spotlight", window: "Spotlight"),
                                frontApp: "Spotlight", frontWindow: "Spotlight")
        #expect(RiskRules.isPlainlySafe(real))
    }

    @Test func theOpenQuestionReachesJev() async throws {
        let transport = utteranceSays(answer: 0.99)
        let context = UtteranceContext(taskRunning: true, awaitingAnswer: true, question: "Anything else?")
        _ = await classifiers(transport).classifyUtterance("no", context: context)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.lastRequest?.httpBody))
        #expect(body["state"]?["assistant_question"] == "Anything else?")
    }

    static let protectedSurfaces: [(String, ScreenAction)] = [
        ("Return with the Java updater in front",
         ScreenAction(kind: .pressKey, key: KeyChord("return"), target: nil, frontApp: "Java Updater",
                      frontWindow: "Java Update Available", frontAppBundleIdentifier: "com.oracle.java.Java-Updater")),
        ("Return on the updater's harmless-sounding button",
         ScreenAction(kind: .pressKey, key: KeyChord("return"),
                      target: element(.button, "Later", app: "Java Updater", bundle: "com.oracle.java.Java-Updater"))),
        ("Return in Spotlight while an updater is in front",
         ScreenAction(kind: .pressKey, key: KeyChord("return"),
                      target: element(.searchField, "Spotlight Search", identifier: "SpotlightSearchField",
                                      app: "Spotlight", bundle: "com.apple.Spotlight", window: "Spotlight"),
                      frontApp: "Java Updater", frontAppBundleIdentifier: "com.oracle.java.Java-Updater")),
        ("click a button in an installer",
         click(.button, "Continue", app: "Installer", window: "Install Zoom")),
        ("click a button in an installer, by bundle",
         ScreenAction(kind: .click, target: element(.button, "Continue", app: "Installateur", bundle: "com.apple.installer"))),
        ("click a password field in a browser",
         click(.passwordField, "Password", app: "Google Chrome", window: "Sign in - Bank")),
        ("click OK on an admin password prompt", click(.button, "OK", app: "SecurityAgent")),
        ("right-click in an installer", ScreenAction(kind: .rightClick, target: element(.row, "Readme", app: "Installer"))),
    ]

    @Test(arguments: protectedSurfaces)
    func protectedSurfacesAlwaysAskByRule(name: String, action: ScreenAction) async {
        let decision = await classifiers(.mustNotBeCalled).classifyRisk(action)
        #expect(decision.label == .needsConfirmation, "\(name)")
        #expect(decision.source == .rule)
        #expect(decision.reason.contains("protected surface"), "\(name): \(decision.reason)")
        let gated = await SafetyGate(classifier: FixedRiskClassifier(.safe)).check(action)
        #expect(gated.label == .needsConfirmation && gated.reason.contains("protected surface"))
    }

    @Test func bundleIdentifiersArePreferredOverNames() {
        // WhatsApp's name starts with an invisible mark; without a bundle id the cleaned name still counts.
        #expect(RiskRules.alwaysAsk(click(.button, app: "\u{200E}WhatsApp", window: "WhatsApp")) != nil)
        // A translated name with the real bundle id is still a sending app.
        #expect(RiskRules.alwaysAsk(click(.button, app: "WhatsApp Messenger", bundle: "net.whatsapp.WhatsApp")) != nil)
        // An exemption is not borrowed by name: an app called "Finder" with another bundle id.
        #expect(RiskRules.isPlainlySafe(click(.button, app: "Finder", bundle: "com.apple.finder")))
        #expect(!RiskRules.isPlainlySafe(click(.button, app: "Finder", bundle: "com.example.finder-clone")))
        // Spotlight by bundle, even if its name were translated.
        let spotlight = ScreenAction(kind: .pressKey, key: KeyChord("return"),
                                     target: element(.textField, app: "Spotlight-Suche", bundle: "com.apple.Spotlight"))
        #expect(RiskRules.isPlainlySafe(spotlight))
    }

    @Test func returnInAWebFormFieldStillAsks() async {
        let form = press("return", .textField, "Email", app: "Google Chrome", window: "Sign up - Example")
        #expect(RiskRules.alwaysAsk(form) == "Return in a form field, which submits it")
        // A text field in an ordinary app, with Spotlight only in front, is not Spotlight's field.
        let orcaField = ScreenAction(kind: .pressKey, key: KeyChord("return"),
                                     target: element(.textField, app: "Orca", window: "Orca"), frontApp: "Spotlight")
        #expect(RiskRules.alwaysAsk(orcaField) != nil)
    }

    @Test func messageWordsInsideABubbleNeitherTripTheRulesNorReachJev() async throws {
        let bubble = click(.text, "Can you send me the invoice and delete the old one?", app: "WhatsApp", window: "WhatsApp")
        #expect(RiskRules.alwaysAsk(bubble) == nil)
        #expect(!RiskRules.isPlainlySafe(bubble))
        let transport = riskSays(safe: 0.97)
        #expect(await classifiers(transport).classifyRisk(bubble).label == .safe)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.lastRequest?.httpBody))
        let sent = try #require(body["state"]?["action"]?.stringValue)
        #expect(!sent.contains("invoice"))
        #expect(!sent.contains("delete"))
    }

    @Test func shortLabelsAreStillJudgedByTheirWords() {
        #expect(RiskRules.alwaysAsk(click(.row, "Delete chat", app: "WhatsApp", window: "WhatsApp")) == "deletion")
        #expect(RiskRules.alwaysAsk(click(.button, "Send the slides to everyone", app: "Keynote")) == "sends to people")
    }

    @Test func riskyWordsOnlyInTheWindowTitleDoNotTripTheRules() {
        #expect(RiskRules.alwaysAsk(click(.button, "Back", app: "Google Chrome", window: "Delete your account - Help")) == nil)
        #expect(RiskRules.alwaysAsk(click(.link, "Sent", app: "Google Chrome", window: "Gmail")) == nil)
    }

    @Test func openingTheBinFolderIsNotADeletion() {
        #expect(RiskRules.alwaysAsk(click(.row, "Bin", app: "Finder", window: "Recents")) == nil)
        #expect(RiskRules.alwaysAsk(click(.button, "Bin", app: "Finder")) == "deletion")
    }

    @Test func webRolesThatOftenHideButtonsAreNeverPlainlySafe() {
        for role in [ScreenRole.group, .image, .text, .other] {
            #expect(!RiskRules.isPlainlySafe(click(role, "Continue", app: "Google Chrome", window: "Secure checkout")), "\(role)")
        }
    }

    @Test func unnamedOnAnOrdinaryPageGoesToJev() async {
        let transport = riskSays(safe: 0.4)
        let decision = await classifiers(transport).classifyRisk(clickUnknown(in: "Google Chrome", window: "YouTube"))
        #expect(decision.label == .needsConfirmation)
        #expect(decision.source == .jev)
        #expect(transport.callCount == 1)
    }

    @Test func returnInATextAreaOutsideSendingAppsGoesToJev() async {
        let transport = riskSays(safe: 0.5)
        let decision = await classifiers(transport).classifyRisk(press("return", .textArea, "Body", app: "TextEdit", window: "notes.txt"))
        #expect(decision.label == .needsConfirmation)
        #expect(transport.callCount == 1)
    }

    @Test func repeatedActionsAreCached() async {
        let transport = riskSays(safe: 0.98)
        let subject = classifiers(transport)
        _ = await subject.classifyRisk(Self.neutral)
        let second = await subject.classifyRisk(Self.neutral)
        #expect(second.label == .safe)
        #expect(second.reason.hasPrefix("cached"))
        #expect(transport.callCount == 1)
    }

    @Test func identifiersWithRunsOfCapitalsAreSplit() {
        #expect(RiskRules.alwaysAsk(click(.button, identifier: "SMSSendButton", app: "Acme", window: "Acme")) == "sends to people")
    }

    @Test func identifierWordsAreReadWhenTheLabelIsEmpty() {
        #expect(RiskRules.alwaysAsk(click(.image, identifier: "SendButtonIcon", app: "Slack", window: "general")) == "sends to people")
        #expect(RiskRules.alwaysAsk(click(.button, identifier: "TrashToolbarItem", app: "Finder")) == "deletion")
    }
}

@Suite("Answer: yes, no or unclear")
struct AnswerTests {
    static let question = "Send \"running late\" to Amma?"

    @Test(arguments: ["error", "timeout", "disabled", "malformed"])
    func neverYesWhenJevIsUnavailableUnlessAnExactPhrase(jev: String) async {
        let subject: Classifiers = switch jev {
        case "error": classifiers(.failing)
        case "timeout": classifiers(.slow(seconds: 1), timeoutSeconds: 0.1)
        case "malformed": classifiers(.respond(json: ["answers": [:] as [String: Any]]))
        default: classifiers(nil)
        }
        for reply in ["yes but change the time", "yeah I suppose", "did you say yes?", "yes?", "not yes", "okay", "mm"] {
            let decision = await subject.classifyAnswer(reply, question: Self.question)
            #expect(decision.label != .yes, "\(jev): \(reply)")
        }
        #expect(await subject.classifyAnswer("yes", question: Self.question).label == .yes)
        #expect(await subject.classifyAnswer("uh... yes", question: Self.question).label == .yes)
        #expect(await subject.classifyAnswer("no", question: Self.question).label == .no)
        #expect(await subject.classifyAnswer("not yet", question: Self.question).label == .no)
    }

    @Test(arguments: ["yes but change the time", "did you say yes?", "not yes", "yes, after you fix the spelling",
                      "send it tomorrow instead", "no wait, yes", "yes?"])
    func aVetoBlocksYesEvenWhenJevIsSure(reply: String) async {
        let decision = await classifiers(answerSays(yes: 0.99, unclear: 0.01)).classifyAnswer(reply, question: Self.question)
        #expect(decision.label == .unclear, "\(reply)")
    }

    @Test func confidentYesIsYes() async {
        let decision = await classifiers(answerSays(yes: 0.97, unclear: 0.03)).classifyAnswer("yeah go for it", question: Self.question)
        #expect(decision.label == .yes)
        #expect(decision.source == .jev)
    }

    @Test func belowTheBarIsUnclearUnlessAnExactPhraseCorroborates() async {
        let unsure = answerSays(yes: 0.9, unclear: 0.1)
        #expect(await classifiers(unsure).classifyAnswer("yeah I reckon go on", question: Self.question).label == .unclear)
        #expect(await classifiers(unsure).classifyAnswer("mm, yes", question: Self.question).label == .yes)
        let weak = answerSays(yes: 0.7, unclear: 0.3)
        #expect(await classifiers(weak).classifyAnswer("yes", question: Self.question).label == .unclear)
    }

    @Test func noAtItsBarIsNo() async {
        #expect(await classifiers(answerSays(no: 0.75, unclear: 0.25)).classifyAnswer("nah", question: Self.question).label == .no)
        #expect(await classifiers(answerSays(no: 0.6, unclear: 0.4)).classifyAnswer("hold off", question: Self.question).label == .unclear)
    }

    @Test func hesitationOnlyIsUnclearWithoutTheNetwork() async {
        for reply in ["hmm", "uh", "  ", "um... er"] {
            #expect(await classifiers(.mustNotBeCalled).classifyAnswer(reply, question: Self.question).label == .unclear)
        }
    }

    @Test func theQuestionReachesJev() async throws {
        let transport = answerSays(yes: 1)
        _ = await classifiers(transport).classifyAnswer("yes", question: Self.question)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.lastRequest?.httpBody))
        #expect(body["state"]?["assistant_asked"] == .string(Self.question))
        #expect(body["state"]?["user_replied"] == "yes")
    }
}
