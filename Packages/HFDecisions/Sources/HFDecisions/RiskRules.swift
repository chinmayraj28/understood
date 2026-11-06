import Foundation
import HFCore

/// The fixed risk rules. They read a `ScreenAction`'s structured fields (kind, key,
/// target role, target words, enabled, app, window), never a sentence.
///
/// Two kinds of rule:
/// - `alwaysAsk`: categories that need a spoken yes whatever the classifier says.
/// - `isPlainlySafe`: a narrow set of actions that only focus, open or look,
///   decided without the network, because the gate runs before every click and key.
///
/// Everything else goes to Jev, which sees only `ScreenAction.description`.
public enum RiskRules {
    // MARK: - Context lists

    /// Apps where a stray click or Return can send a message, start a call or invite someone.
    public static let sendingApps: Set<String> = [
        "whatsapp", "messages", "mail", "slack", "discord", "telegram", "signal", "microsoft teams",
        "teams", "zoom", "zoom.us", "facetime", "microsoft outlook", "outlook", "messenger", "skype",
        "calendar", "photos",
    ]
    /// The same apps by bundle identifier, which is preferred: display names can be translated,
    /// and WhatsApp's begins with an invisible mark.
    public static let sendingBundleIdentifiers: Set<String> = [
        "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.microsoft.teams",
        "com.microsoft.teams2", "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.Outlook",
        "com.facebook.archon", "com.skype.skype", "com.apple.iCal", "com.apple.Photos",
    ]
    /// Window-title fragments that mark a web page where a click can send, pay or invite.
    public static let sendingPageWords = [
        "gmail", "inbox", "mail", "outlook", "whatsapp", "messenger", "message", "chat", "slack",
        "calendar", "meet", "linkedin", "twitter", "facebook", "instagram", "discord", "teams", "zoom",
        "bank", "pay", "checkout", "basket", "cart", "order", "transfer", "compose",
    ]
    /// Apps where a control that cannot be named can only play, show or navigate.
    /// Deliberately short: no browser, nothing that sends, deletes photos or changes security settings.
    public static let lookAndPlayApps: Set<String> = [
        "finder", "spotify", "music", "podcasts", "tv", "books", "preview", "notes", "textedit",
        "calculator", "maps", "weather", "clock", "reminders", "dictionary", "stocks", "news",
        "terminal", "iterm2",
    ]
    public static let lookAndPlayBundleIdentifiers: Set<String> = [
        "com.apple.finder", "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
        "com.apple.iBooksX", "com.apple.Preview", "com.apple.Notes", "com.apple.TextEdit", "com.apple.calculator",
        "com.apple.Maps", "com.apple.weather", "com.apple.clock", "com.apple.reminders", "com.apple.Dictionary",
        "com.apple.stocks", "com.apple.news", "com.apple.Terminal", "com.googlecode.iterm2",
    ]
    /// Folder names that a row or link only opens, so "Bin" there is not a deletion.
    public static let binFolderNames: Set<String> = [
        "bin", "trash", "deleted items", "deleted", "recently deleted", "deleted messages",
    ]
    /// Words in a field's name that mark it as a search or address field, where Return only searches.
    /// "spotlight" is deliberately absent: "Spotlight Search" is only placeholder text, which
    /// another app could show. Spotlight is recognised by its role and its own app instead.
    public static let searchFieldWords: Set<String> = [
        "search", "find", "filter", "address", "url", "location", "omnibox",
    ]
    /// Apps whose text boxes only search or launch: Return there opens the top result.
    /// Spotlight is how the screen agent opens every app (Command+Space, the name, Return),
    /// so a Return there must never be held. A message box never lives in these processes,
    /// so the rule cannot be confused with one. Matched on the focused control's own app,
    /// not the front app (with Spotlight open, the front app is still the previous one).
    public static let searchOnlyApps: Set<String> = ["spotlight", "alfred", "raycast"]
    public static let searchOnlyBundleIdentifiers: Set<String> = [
        "com.apple.Spotlight", "com.runningwithcrayons.Alfred", "com.raycast.macos",
    ]
    /// Words in a text area's name that mark it as a message box, where Return sends.
    public static let messageFieldWords: Set<String> = [
        "message", "reply", "comment", "chat", "compose", "write", "type",
    ]
    /// Roles whose click only focuses, selects or opens something to look at.
    /// "group", "image", "text" and "other" are deliberately absent: on web pages a custom
    /// button often appears as one of those.
    public static let lookingRoles: Set<ScreenRole> = [
        .textField, .textArea, .searchField, .passwordField, .tab, .menuBarItem, .row, .cell, .listItem,
        .dockItem, .popUpButton, .menuButton,
    ]
    static let navigationRoles: Set<ScreenRole> = [.row, .cell, .listItem, .link, .tab, .text]

    // MARK: - Risky words, matched on whole words (`UIElementInfo.words`)

    /// A family of risky words: exact words, word beginnings, and short phrases (consecutive words).
    public struct WordFamily: Sendable {
        public let category: String
        public let exact: Set<String>
        public let stems: [String]
        public let phrases: [[String]]

        func matches(_ words: [String]) -> Bool {
            if words.contains(where: { exact.contains($0) }) { return true }
            if words.contains(where: { word in stems.contains { word.hasPrefix($0) } }) { return true }
            return phrases.contains { phrase in
                guard words.count >= phrase.count else { return false }
                return (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
            }
        }
    }

    public static let payment = WordFamily(
        category: "payment or purchase",
        exact: ["pay", "payment", "paynow", "buy", "purchase", "checkout", "transfer", "donate", "subscribe"],
        stems: ["purchas", "donat", "subscri", "checkout"],
        phrases: [["place", "order"], ["place", "your", "order"], ["place", "the", "order"], ["order", "now"],
                  ["complete", "order"], ["complete", "your", "order"], ["check", "out"], ["book", "now"],
                  ["send", "money"], ["confirm", "payment"], ["confirm", "purchase"], ["confirm", "booking"]])
    public static let deletion = WordFamily(
        category: "deletion",
        exact: ["delete", "remove", "bin", "trash", "erase", "wipe", "discard", "empty", "uninstall", "rm"],
        stems: ["delet", "remov", "eras", "discard", "uninstall", "trash"],
        phrases: [])
    public static let sending = WordFamily(
        category: "sends to people",
        exact: ["send", "sends", "invite", "share", "post", "publish", "submit", "forward", "tweet", "call", "dial",
                "join", "accept", "decline", "confirm", "approve", "authorise", "authorize", "record", "unsubscribe"],
        stems: ["invit", "publish", "submit", "authori", "approv"],
        phrases: [["voice", "message"], ["voice", "note"], ["video", "message"]])
    public static let accountChange = WordFamily(
        category: "changes an account or membership",
        exact: ["logout", "signout", "block", "report", "unfriend", "unfollow", "reset", "restore", "deactivate"],
        stems: ["deactivat"],
        phrases: [["log", "out"], ["sign", "out"], ["leave", "group"], ["leave", "the", "group"], ["leave", "chat"],
                  ["leave", "call"], ["leave", "meeting"], ["exit", "group"], ["clear", "chat"], ["clear", "all"],
                  ["clear", "history"], ["clear", "data"], ["clear", "everything"], ["clear", "conversation"],
                  ["close", "account"], ["delete", "account"]])
    /// Installing or updating software, or agreeing to a permission. Added after a test's Return
    /// key reached Oracle's Java updater on 5 Nov 2026 and an update was installed unasked.
    /// A dedicated updater or installer app is refused outright (HFCore's `ProtectedSurfaces`);
    /// this family covers the same buttons when they appear inside an ordinary app's own window,
    /// such as a Sparkle "Install Update" sheet, where the window belongs to that app.
    public static let softwareChange = WordFamily(
        category: "installs or updates software, or grants a permission",
        exact: ["install", "reinstall", "upgrade", "update", "relaunch", "allow", "agree", "trust", "grant"],
        stems: ["install"],
        phrases: [["restart", "now"], ["restart", "to", "update"], ["update", "and", "restart"],
                  ["download", "and", "install"], ["open", "anyway"], ["always", "allow"]])
    static let calendarCommitWords: Set<String> = ["save", "done", "update", "create", "ok"]

    public static let protectedSurfaceCategory = "protected surface (a password, install or update window)"

    // MARK: - Public rules

    /// The always-ask category of this action, or nil.
    public static func alwaysAsk(_ action: ScreenAction) -> String? {
        // First, for every kind of action: a password prompt, an installer or an updater
        // (HFCore's shared `ProtectedSurfaces` list, or a password field). The screen agent
        // and the quick tools refuse these outright; this is the second line, so nothing can
        // come back safe for a click or key press there.
        if action.landsOnProtectedSurface { return protectedSurfaceCategory }
        switch action.kind {
        case .rightClick:
            return nil  // only opens a menu; choosing from it is a separate, checked click
        case .click, .doubleClick:
            return clickRisk(action.target, action)
        case .pressKey:
            return keyRisk(action)
        case .typeLineBreak:
            return lineBreakRisk(action)
        case .drag:
            return dragRisk(action)
        }
    }

    /// True only for actions that focus, open or look, with nothing risky about them.
    /// Never true when an always-ask rule applies.
    public static func isPlainlySafe(_ action: ScreenAction) -> Bool {
        guard alwaysAsk(action) == nil else { return false }
        let isLookAndPlay = appMatches(name: action.app, bundleIdentifier: action.appBundleIdentifier,
                                       names: lookAndPlayApps, bundleIdentifiers: lookAndPlayBundleIdentifiers,
                                       loosensSafety: true)
        switch action.kind {
        case .rightClick:
            return true
        case .click, .doubleClick:
            guard let target = action.target else { return isLookAndPlay }
            if !target.isEnabled { return true }  // a disabled control does nothing when clicked
            if !target.isNamed { return target.role.isTextEntry || isLookAndPlay }
            if isLongContent(target) { return false }  // its words are hidden from the rules, so Jev must look
            return lookingRoles.contains(target.role)
        case .pressKey:
            guard let key = action.key, let target = action.target else { return false }
            if key.isReturn { return key.modifiers.isEmpty && isSearchTarget(target) }
            if key.isDelete || key.isSpace { return target.role.isTextEntry }
            return false
        case .typeLineBreak:
            return action.target.map(isSearchTarget) ?? false
        case .drag:
            return false
        }
    }

    // MARK: - By kind

    static func clickRisk(_ target: UIElementInfo?, _ action: ScreenAction) -> String? {
        guard let target else {
            return isSendingContext(action) ? "an unknown control where sending is possible" : nil
        }
        if let category = wordCategory(target) { return category }
        let words = judgedWords(target)
        let place = (action.window + " " + action.app).lowercased()
        if words.contains(where: { calendarCommitWords.contains($0) }) && place.contains("calendar") {
            // Saving an event sends invitations when it has guests, and nothing here can tell.
            return "saving a calendar event, which may invite guests"
        }
        if !target.isNamed && !target.role.isTextEntry && isSendingContext(action) {
            // Clicking an unnamed text box only focuses it; anything else unnamed could be Send.
            return "an unlabelled control where sending is possible"
        }
        return nil
    }

    static func keyRisk(_ action: ScreenAction) -> String? {
        guard let key = action.key else { return "a key that could not be read" }
        let target = action.target
        if key.isReturn || key.isSpace {
            guard let target else {
                return isSendingContext(action) ? "\(key.display) where the focus is unknown and sending is possible" : nil
            }
            if target.role.activatesOnKeyPress {
                // Tab to a Send button and press Space or Return: the same as clicking it.
                return clickRisk(target, action).map { "\($0) (\(key.display) on a focused control)" }
            }
            guard key.isReturn else { return nil }  // Space in a text box or a list only types or previews
            if isSearchTarget(target) { return nil }
            if target.role.isTextEntry {
                if !key.modifiers.isEmpty { return "\(key.display) in a text box, which sends in mail and chat apps" }
                if target.role == .textField || target.role == .passwordField { return "Return in a form field, which submits it" }
                if isSendingContext(action) || judgedWords(target).contains(where: messageFieldWords.contains) {
                    return "Return in a message box, which sends it"
                }
                return nil
            }
            return isSendingContext(action) ? "Return where sending is possible" : nil
        }
        if key.isDelete {
            // Delete in a text box removes a character; anywhere else it deletes the selection.
            return target?.role.isTextEntry == true ? nil : "Delete key on a selection"
        }
        if key.modifiers.isSuperset(of: [.command, .shift]) && key.key == "d" {
            return "a shortcut that sends mail"
        }
        return nil
    }

    static func lineBreakRisk(_ action: ScreenAction) -> String? {
        guard let target = action.target else { return "a line break where the focus is unknown" }
        if isSearchTarget(target) { return nil }
        if target.role.isTextEntry { return "a line break in a text box, which sends or submits" }
        if target.role.activatesOnKeyPress {
            return clickRisk(target, action).map { "\($0) (a line break on a focused control)" }
        }
        return isSendingContext(action) ? "a line break where sending is possible" : nil
    }

    static func dragRisk(_ action: ScreenAction) -> String? {
        guard let destination = action.destination else { return "a drag whose destination is unknown" }
        if deletion.matches(judgedWords(destination)) { return "deletion (dropping onto \(destination.label))" }
        // A Dock item's label is the app's name; otherwise the destination's own app.
        if sendingApps.contains(cleanName(destination.label))
            || appMatches(name: destination.app, bundleIdentifier: destination.appBundleIdentifier,
                          names: sendingApps, bundleIdentifiers: sendingBundleIdentifiers, loosensSafety: false)
        {
            return "dropping onto an app that sends"
        }
        return wordCategory(destination)
    }

    // MARK: - Helpers

    /// The words the rules may read. A long label on a content control (a message
    /// bubble, a chat preview) is the user's text, not the control's name, so only
    /// its identifier counts; the same rule keeps that text out of the description.
    public static func judgedWords(_ element: UIElementInfo) -> [String] {
        isLongContent(element) ? ScreenText.words(element.identifier) : element.words
    }

    static func isLongContent(_ element: UIElementInfo) -> Bool {
        element.role.isContent && element.label.count > ScreenAction.longestQuotedContentLabel
    }

    /// The first risky word family the element's words fall in.
    static func wordCategory(_ element: UIElementInfo) -> String? {
        let words = judgedWords(element)
        if payment.matches(words) { return payment.category }
        let opensBinFolder = navigationRoles.contains(element.role) && binFolderNames.contains(element.label.lowercased())
        if deletion.matches(words) && !opensBinFolder { return deletion.category }
        if sending.matches(words) { return sending.category }
        if accountChange.matches(words) { return accountChange.category }
        // Only for controls that do something when pressed: the word "update" in a heading or a
        // paragraph is not a button.
        if element.role.activatesOnKeyPress && softwareChange.matches(words) { return softwareChange.category }
        return nil
    }

    static func isSearchTarget(_ element: UIElementInfo) -> Bool {
        if element.role == .searchField { return true }
        if element.role.isTextEntry
            && appMatches(name: element.app, bundleIdentifier: element.appBundleIdentifier, names: searchOnlyApps,
                          bundleIdentifiers: searchOnlyBundleIdentifiers, loosensSafety: true)
        {
            return true
        }
        return judgedWords(element).contains(where: searchFieldWords.contains)
    }

    /// An app or web page where a click or Return can reach other people or money.
    public static func isSendingContext(_ action: ScreenAction) -> Bool {
        if appMatches(name: action.app, bundleIdentifier: action.appBundleIdentifier, names: sendingApps,
                      bundleIdentifiers: sendingBundleIdentifiers, loosensSafety: false)
        {
            return true
        }
        let window = action.window.lowercased()
        return sendingPageWords.contains { window.contains($0) }
    }

    /// Whether an app is one of a list, preferring its bundle identifier.
    ///
    /// The asymmetry is deliberate. For a list that makes the gate ASK (sending apps), either the
    /// identifier or the name is enough, so a renamed or unknown build still asks. For a list that
    /// makes an action SAFE (look-and-play apps, Spotlight), a present identifier must be one we
    /// know; the name alone is trusted only when no identifier was read, so an app merely called
    /// "Finder" cannot borrow Finder's exemption.
    static func appMatches(name: String, bundleIdentifier: String, names: Set<String>,
                           bundleIdentifiers: Set<String>, loosensSafety: Bool) -> Bool {
        if !bundleIdentifier.isEmpty {
            if bundleIdentifiers.contains(bundleIdentifier) { return true }
            if loosensSafety { return false }
        }
        return names.contains(cleanName(name))
    }

    /// A display name without invisible marks or case: WhatsApp reports "\u{200E}WhatsApp".
    static func cleanName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
