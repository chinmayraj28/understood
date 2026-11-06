//
//  PanelCopy.swift
//  Handsfree
//
//  Every sentence the panel shows, in one place. Written for a carer or a
//  family member as much as for the person using Handsfree: plain words,
//  full sentences, British spelling, and no technical terms. The wake phrase
//  is always passed in (it comes from settings), never written here.
//
//  The setup wording keeps the meaning of `SetupCheck` (the first-run check)
//  but names the panel's own buttons ("Allow Microphone"). A unit test reads
//  every string here and fails if one mentions the app's internals.
//  Pure functions. New for Handsfree.
//

import Foundation

enum PanelCopy {

    // MARK: - Header and footer

    static let appName = "Handsfree"
    static let demoBadge = "Demo"
    static let closeLabel = "Close panel"
    static let quit = "Quit Handsfree"

    static func footerMode(isAlwaysOpen: Bool) -> String {
        isAlwaysOpen ? "Always listening" : "Wakes on its phrase"
    }

    static func version(_ version: String) -> String { "Version \(version)" }

    /// The word or two beside the status icon in the header.
    static func status(_ activity: PanelSnapshot.Activity, mode: PanelSnapshot.Mode) -> String {
        if mode == .setup { return "Setup needed" }
        switch activity {
        case .asleep: return "Asleep"
        case .waking: return "Waking up"
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .speaking: return "Speaking"
        case .working: return "Working"
        case .question: return "Asked a question"
        case .waitingForYes: return "Waiting for a yes"
        case .done: return "Done"
        case .failed: return "Couldn\u{2019}t finish"
        case .stopped: return "Stopped"
        case .cancelled: return "Cancelled"
        case .notConnected: return "Not connected"
        }
    }

    // MARK: - Setup

    static let setupTitle = "Set up Handsfree"
    static let setupIntro = "These steps need someone at the Mac. The person using Handsfree cannot do them by voice."

    static func setupProgress(done: Int, total: Int) -> String { "\(done) of \(total) done" }

    static let stepDone = "Done"
    static let stepNeeded = "Needed"
    static let stepTurnedOff = "Turned off"

    static func stepTitle(_ kind: PanelSnapshot.SetupStep.Kind) -> String {
        switch kind {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .keys: return "Keys file"
        }
    }

    static func stepReason(_ kind: PanelSnapshot.SetupStep.Kind) -> String {
        switch kind {
        case .microphone: return "So it can hear what they ask."
        case .speechRecognition: return "So it can hear its wake phrase without sending anything off this Mac."
        case .accessibility: return "So it can move the pointer, click and type for them."
        case .screenRecording: return "So it can see the screen and find what to click."
        case .keys: return "So it can reach the services it uses to talk and to see."
        }
    }

    static func allowButton(_ kind: PermissionKind) -> String { "Allow \(kind.displayName)" }
    static func settingsButton(_ kind: PermissionKind) -> String { "Open \(kind.displayName) Settings" }
    static let showKeysFileButton = "Show Keys File"

    /// What to do for a permission macOS has not asked about yet.
    static func instructionsNotAsked(_ kind: PermissionKind) -> String {
        let button = allowButton(kind)
        switch kind {
        case .microphone:
            return "Click \(button), then click Allow in the box macOS shows."
        case .speechRecognition:
            return "Click \(button), then allow it in the box macOS shows. Until the wake phrase is heard, nothing they say leaves this Mac."
        case .accessibility:
            return "Click \(button), then Open System Settings in the box that appears, and switch Handsfree on. "
                + "macOS may ask for the Mac\u{2019}s password."
        case .screenRecording:
            return "Click \(button), then Open System Settings, switch Handsfree on, and choose Quit & Reopen when macOS offers it."
        }
    }

    /// What to do for a permission that was refused, or asked for and not given.
    static func instructionsTurnedOff(_ kind: PermissionKind) -> String {
        let button = settingsButton(kind)
        switch kind {
        case .microphone:
            return "The microphone was refused for Handsfree. Click \(button), switch Handsfree on in the list, "
                + "then quit Handsfree and open it again."
        case .speechRecognition:
            return "Without it Handsfree cannot hear its wake phrase. Click \(button), switch Handsfree on, "
                + "then quit Handsfree and open it again."
        case .accessibility:
            return "Click \(button) and switch Handsfree on. If Handsfree is not in the list, click the + button and choose it. "
                + "If it is already on but this still shows, switch it off and on again."
        case .screenRecording:
            return "Click \(button) and switch Handsfree on under Screen & System Audio Recording, then choose Quit & Reopen. "
                + "macOS only applies this one after Handsfree restarts."
        }
    }

    static let keysInstructions = "Handsfree reads its three keys from a small text file. Make a plain text file at the place "
        + "shown, with these three lines, pasting each key after its = sign. Then quit Handsfree and open it again."

    /// One line of the keys file as shown to the carer: "ANTHROPIC_API_KEY=…  (missing)".
    static func keysFileLine(_ name: String, isMissing: Bool) -> String {
        let line = "\(name)=\u{2026}"
        return isMissing ? line.padding(toLength: 22, withPad: " ", startingAt: 0) + "(missing)" : line
    }

    static let optionalKeyNote = "Optional: without OPENROUTER_API_KEY, \u{201C}stop\u{201D} and \u{201C}yes\u{201D} are understood "
        + "from a simple word list. Handsfree still asks before it sends or deletes anything."

    static let whereToFindTitle = "Finding Handsfree again"
    static let whereToFind = "It lives in the menu bar: a pointer with two small sound waves, sometimes hidden behind the camera notch. "
        + "To bring this panel back, open Handsfree again (double-click it in Applications)."

    // MARK: - Ready

    static let readyEyebrow = "Ready"

    static func sayPhrase(_ wakePhrase: String) -> String { "Say \u{201C}\(wakePhrase)\u{201D}" }

    static let readySubtitle = "Then say what you want, in one go. Until it hears the phrase, Handsfree is asleep "
        + "and nothing said leaves this Mac."

    static let cannotWakeSubtitle = "It will listen for this phrase again once the problem above is fixed."

    static let alwaysOpenTitle = "Listening all the time"
    static let alwaysOpenSubtitle = "Everything said near the Mac is sent to the voice service. Remove the line "
        + "WAKE_MODE=always from the keys file to use the wake phrase instead."

    static let examplesTitle = "Things to try"

    /// Three things to say, each starting with the wake phrase (or without it when always listening).
    struct Example: Equatable {
        let symbol: String
        let text: String
    }

    static func examples(wakePhrase: String, isAlwaysOpen: Bool) -> [Example] {
        let requests: [(String, String)] = [
            ("message", "message Amma that I\u{2019}m running late"),
            ("music.note", "play my liked songs on Spotify"),
            ("calendar", "open my calendar for tomorrow"),
        ]
        return requests.map { symbol, request in
            if isAlwaysOpen { return Example(symbol: symbol, text: "\u{201C}\(request.prefix(1).uppercased() + request.dropFirst())\u{201D}") }
            return Example(symbol: symbol, text: "\u{201C}\(wakePhrase), \(request)\u{201D}")
        }
    }

    static let soundsTitle = "What the chimes mean"
    static let risingChime = "A rising chime: it is listening."

    static func fallingChime(sleepAfterSeconds: Int) -> String {
        "A falling chime: it has gone back to sleep, after \(sleepAfterSeconds) seconds of quiet, or when you say \u{201C}that\u{2019}s all\u{201D}."
    }

    static let lastTaskTitle = "Last task"
    static let memoryTitle = "What it remembers"

    // MARK: - Active

    static func activityTitle(_ activity: PanelSnapshot.Activity) -> String {
        switch activity {
        case .asleep: return "Asleep"
        case .waking: return "Waking up"
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .speaking: return "Speaking"
        case .working: return "Working on it"
        case .question: return "Asked a question"
        case .waitingForYes: return "Waiting for a yes"
        case .done: return "Done"
        case .failed: return "Couldn\u{2019}t finish"
        case .stopped: return "Stopped"
        case .cancelled: return "Cancelled"
        case .notConnected: return "Not connected"
        }
    }

    static func activitySubtitle(_ activity: PanelSnapshot.Activity, sleepAfterSeconds: Int, isAlwaysOpen: Bool) -> String {
        switch activity {
        case .asleep: return "Waiting for the wake phrase."
        case .waking: return "It heard the wake phrase and is getting ready."
        case .connecting: return "Reaching the voice service."
        case .listening:
            return isAlwaysOpen
                ? "Say what you want."
                : "Say what you want. It goes back to sleep after \(sleepAfterSeconds) seconds of quiet."
        case .hearing: return "Go on, it is listening."
        case .speaking: return "Handsfree is answering."
        case .working: return "Watch the pointer: it is doing this on the screen."
        case .question: return "Say your answer."
        case .waitingForYes: return "Nothing happens without a yes."
        case .done: return "The task is finished."
        case .failed: return "The task stopped part of the way."
        case .stopped: return "Stopped, as asked. Nothing more will happen."
        case .cancelled: return "The task was cancelled."
        case .notConnected: return "Trying again by itself."
        }
    }

    static let waitingForYesEyebrow = "Waiting for your yes"
    static let questionEyebrow = "Question"
    static let yesHint = "Say \u{201C}yes\u{201D} to go ahead, or \u{201C}no\u{201D} to stop."
    static let answerHint = "Say your answer."

    static func heldAction(_ action: String) -> String { "Holding: \(action)" }

    static let taskTitle = "Task"

    static func taskStatus(_ status: PanelSnapshot.TaskCard.Status) -> String {
        switch status {
        case .running: return "Working"
        case .waitingForAnswer: return "Waiting for an answer"
        case .waitingForYes: return "Waiting for a yes"
        case .done: return "Done"
        case .failed: return "Couldn\u{2019}t finish"
        case .stopped: return "Stopped"
        }
    }

    static func stepsDone(_ count: Int) -> String {
        count == 1 ? "1 step done" : "\(count) steps done"
    }

    static func earlierSteps(_ count: Int) -> String {
        count == 1 ? "1 earlier step" : "\(count) earlier steps"
    }

    static let currentStepLabel = "Now"

    static let conversationTitle = "Conversation"
    static let emptyConversation = "Nothing said yet."
    static let you = "You"
    static func saidBy(isFromUser: Bool) -> String { isFromUser ? "You said" : "Handsfree said" }

    // MARK: - Details

    static let detailsTitle = "Listening details"
    static let detailsHide = "Hide listening details"
    static let detailsExpanded = "Shown"
    static let detailsCollapsed = "Hidden"

    // MARK: - VoiceOver only

    static let setupProgressLabel = "Setup progress"
    static func fileLocation(_ path: String) -> String { "File location: \(path)" }
    static func troubleLabel(isError: Bool, title: String, message: String) -> String {
        "\(isError ? "Problem" : "Warning"): \(title). \(message)"
    }

    static func voiceDetail(isReady: Bool?, checkedAgo: String?) -> String {
        guard let isReady else { return "Voice: not checked yet." }
        let when = checkedAgo.map { ", checked \($0)" } ?? ""
        return isReady ? "Voice: set up correctly\(when)." : "Voice: not set up correctly\(when). It will not wake until this is fixed."
    }

    static func partsDetail(real: Int, total: Int) -> String {
        real == total ? "All \(total) parts of Handsfree are working." : "\(real) of \(total) parts of Handsfree are working; the rest use safe stand-ins."
    }

    // MARK: - Trouble

    static let voiceNotSetUpTitle = "Handsfree\u{2019}s voice could not be set up"
    static let voiceNotSetUpMessage = "It cannot wake until this is fixed. It keeps trying by itself. If this stays for more than "
        + "a minute, check that the Mac is online, then quit Handsfree and open it again."

    static let notConnectedTitle = "Handsfree cannot reach its voice service"

    static func notConnectedMessage(reason: String?) -> String {
        let reasonPart = reason.map { cleanReason($0) }.map { "\($0) " } ?? ""
        return reasonPart + "Check that the Mac is online. It keeps trying by itself."
    }

    static func cannotListenTitle(wakePhrase: String) -> String {
        "Handsfree cannot listen for \u{201C}\(wakePhrase)\u{201D}"
    }

    static func cannotListenMessage(reason: String) -> String {
        cleanReason(reason) + " Quit Handsfree and open it again. If that does not help, check the microphone in System Settings."
    }

    static func phraseNotHeardTitle(wakePhrase: String) -> String {
        "It hears speech, but not \u{201C}\(wakePhrase)\u{201D}"
    }

    static func phraseNotHeardMessage(count: Int, language: String) -> String {
        let languagePart = language.isEmpty ? "" : " It listens in \(language)."
        return "Speech was heard \(count) times since it started, but never the wake phrase. Say it clearly, as one phrase, "
            + "facing the Mac.\(languagePart)"
    }

    /// A reason as one sentence ending in a full stop.
    private static func cleanReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        let capitalised = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return ".!?".contains(last) ? capitalised : capitalised + "."
    }
}
