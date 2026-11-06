//
//  SetupCheck.swift
//  Handsfree
//
//  The first-run check: which keys and permissions are missing, and what the
//  person helping with setup should do about each one. The user of this app
//  cannot click, so every sentence here is written for a carer, a family
//  member or whoever installs it. Pure logic, unit tested.
//
//  New for Handsfree. Clicky's permission rows in CompanionPanelView.swift
//  were the model for the three permission checks; the wording is ours.
//

import Foundation

/// The three macOS permissions the app needs.
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// The System Settings page for this permission.
    var settingsURLString: String {
        switch self {
        case .microphone: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

/// Where a permission stands.
enum PermissionStatus: Equatable {
    case granted
    /// macOS has never asked; asking will show a dialog with an Allow button.
    case notAsked
    /// Refused, or asked before and not granted: only System Settings can change it now.
    case notGranted
}

/// Something the person setting up has to do.
struct SetupItem: Equatable, Identifiable {
    enum Action: Equatable {
        /// Show macOS's own permission dialog.
        case askMacOS(PermissionKind)
        /// Open the right page of System Settings.
        case openSettings(PermissionKind)
        /// Show the .env file (or its folder) in Finder.
        case showKeysFile
    }

    let id: String
    let title: String
    /// What to do, in plain words for a carer.
    let instructions: String
    /// When true the app cannot do its job until this is fixed.
    let isBlocking: Bool
    let action: Action?
    let actionTitle: String?
}

/// Everything the check needs to know, gathered by the app at launch.
struct SetupFacts: Equatable {
    var hasElevenLabsKey: Bool
    var hasAnthropicKey: Bool
    var hasOpenRouterKey: Bool
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
    var screenRecording: PermissionStatus
    /// Where the keys file is or should go, shown to the carer.
    var keysFilePath: String
}

enum SetupCheck {

    /// The items to show, blocking ones first, in the order they are best done.
    static func items(for facts: SetupFacts) -> [SetupItem] {
        var items: [SetupItem] = []

        // Permissions first: they need someone at the Mac, and macOS asks for a
        // restart of the app after Screen Recording, so do that one last.
        if let item = microphoneItem(facts.microphone) { items.append(item) }
        if let item = accessibilityItem(facts.accessibility) { items.append(item) }
        if let item = screenRecordingItem(facts.screenRecording) { items.append(item) }

        var missingRequiredKeys: [String] = []
        if !facts.hasElevenLabsKey { missingRequiredKeys.append("ELEVENLABS_API_KEY") }
        if !facts.hasAnthropicKey { missingRequiredKeys.append("ANTHROPIC_API_KEY") }
        if !missingRequiredKeys.isEmpty {
            let keyList = missingRequiredKeys.joined(separator: " and ")
            items.append(SetupItem(
                id: "keys",
                title: missingRequiredKeys.count == 1 ? "A key is missing" : "Two keys are missing",
                instructions: "Handsfree needs \(keyList) to hear and to see the screen. "
                    + "Add \(missingRequiredKeys.count == 1 ? "it" : "them") as KEY=value lines to the file \(facts.keysFilePath), "
                    + "then quit Handsfree from this panel and open it again.",
                isBlocking: true,
                action: .showKeysFile,
                actionTitle: "Show file"))
        }

        if !facts.hasOpenRouterKey {
            items.append(SetupItem(
                id: "openrouter",
                title: "Optional: OpenRouter key",
                instructions: "Without OPENROUTER_API_KEY, \u{201C}stop\u{201D} and \u{201C}yes\u{201D} are understood with a simple word list "
                    + "instead of the Jev classifier. Everything still asks before it sends or deletes anything.",
                isBlocking: false,
                action: nil,
                actionTitle: nil))
        }
        return items
    }

    /// Where to find Handsfree again, for the person helping. Shown with the setup steps.
    static let whereToFindIt = "Handsfree lives in the menu bar at the top right of the screen: a pointer arrow with two small sound waves. "
        + "On a MacBook with many menu bar icons it can be hidden behind the camera notch. To open this panel at any time, "
        + "open Handsfree again (double-click Handsfree.app in Finder)."

    /// True when nothing blocking is left.
    static func isReady(_ facts: SetupFacts) -> Bool {
        !items(for: facts).contains(where: \.isBlocking)
    }

    /// The permissions still missing, for a one-line summary ("Missing: Accessibility").
    static func missingPermissions(_ facts: SetupFacts) -> [PermissionKind] {
        var missing: [PermissionKind] = []
        if facts.microphone != .granted { missing.append(.microphone) }
        if facts.accessibility != .granted { missing.append(.accessibility) }
        if facts.screenRecording != .granted { missing.append(.screenRecording) }
        return missing
    }

    // MARK: - Wording

    private static func microphoneItem(_ status: PermissionStatus) -> SetupItem? {
        switch status {
        case .granted:
            return nil
        case .notAsked:
            return SetupItem(
                id: "microphone",
                title: "Microphone",
                instructions: "Handsfree needs the microphone to hear them. Click Ask macOS, then click Allow in the box that appears.",
                isBlocking: true, action: .askMacOS(.microphone), actionTitle: "Ask macOS")
        case .notGranted:
            return SetupItem(
                id: "microphone",
                title: "Microphone is off",
                instructions: "The microphone was refused for Handsfree. Click Open Settings, switch Handsfree on in the list, "
                    + "then quit Handsfree from this panel and open it again.",
                isBlocking: true, action: .openSettings(.microphone), actionTitle: "Open Settings")
        }
    }

    private static func accessibilityItem(_ status: PermissionStatus) -> SetupItem? {
        switch status {
        case .granted:
            return nil
        case .notAsked:
            return SetupItem(
                id: "accessibility",
                title: "Accessibility",
                instructions: "Handsfree needs Accessibility to move the pointer, click and type for them. Click Ask macOS, "
                    + "then Open System Settings in the box that appears, and switch Handsfree on. macOS may ask for the Mac\u{2019}s password.",
                isBlocking: true, action: .askMacOS(.accessibility), actionTitle: "Ask macOS")
        case .notGranted:
            return SetupItem(
                id: "accessibility",
                title: "Accessibility is off",
                instructions: "Click Open Settings and switch Handsfree on under Accessibility. If Handsfree is not in the list, "
                    + "click the + button and choose Handsfree.app. If it is already on but this still shows, switch it off and on again.",
                isBlocking: true, action: .openSettings(.accessibility), actionTitle: "Open Settings")
        }
    }

    private static func screenRecordingItem(_ status: PermissionStatus) -> SetupItem? {
        switch status {
        case .granted:
            return nil
        case .notAsked:
            return SetupItem(
                id: "screenRecording",
                title: "Screen Recording",
                instructions: "Handsfree needs to see the screen to find what to click. Click Ask macOS, then Open System Settings, "
                    + "switch Handsfree on, and choose Quit & Reopen when macOS offers it.",
                isBlocking: true, action: .askMacOS(.screenRecording), actionTitle: "Ask macOS")
        case .notGranted:
            return SetupItem(
                id: "screenRecording",
                title: "Screen Recording is off",
                instructions: "Click Open Settings and switch Handsfree on under Screen & System Audio Recording, "
                    + "then choose Quit & Reopen. macOS only applies this one after Handsfree restarts.",
                isBlocking: true, action: .openSettings(.screenRecording), actionTitle: "Open Settings")
        }
    }
}
