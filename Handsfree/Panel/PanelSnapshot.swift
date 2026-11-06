//
//  PanelSnapshot.swift
//  Handsfree
//
//  Everything the menu bar panel shows, as plain values. The panel's views
//  draw a snapshot and nothing else, so every state can be built in a test
//  or drawn to a PNG without the live app. `PanelSnapshotBuilder` makes one
//  from the live model; `PanelStateCatalogue` makes the review examples.
//
//  The rules that matter are here and unit tested: which of the three
//  layouts the panel uses (setup, ready, active) and which single button is
//  the main thing to press. Pure value type. New for Handsfree.
//

import Foundation

struct PanelSnapshot: Equatable {

    /// The three layouts of the panel.
    enum Mode: Equatable {
        /// Something blocking is missing: the panel is a checklist for whoever is helping.
        case setup
        /// Set up and asleep: the wake phrase, and things to say.
        case ready
        /// Awake or working: live state, the task, the conversation.
        case active
    }

    /// A button in the panel. Every action is one the app already knows how to do.
    struct Action: Equatable {
        /// A visible text label, so Voice Control can name it ("Click Allow Microphone").
        let title: String
        let perform: SetupItem.Action
    }

    /// One row of the setup checklist.
    struct SetupStep: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case microphone, speechRecognition, accessibility, screenRecording, keys
        }

        let kind: Kind
        var id: String { kind.rawValue }
        let title: String
        /// One line on why it is needed, for a carer.
        let reason: String
        let isDone: Bool
        /// The word shown with the state: "Done", "Needed" or "Turned off". Paired with an icon.
        let stateLabel: String
        /// What to do, step by step. Shown for the next step only.
        let instructions: String
        /// A file path to show in fixed-width type, if any.
        let detail: String?
        /// What goes in that file, line by line, to show in fixed-width type (the keys step only).
        var fileLines: [String] = []
        let action: Action?
    }

    /// What Handsfree is doing right now, for the header and the status card.
    enum Activity: Equatable {
        case asleep, waking, connecting, listening, hearing, speaking, working
        case question, waitingForYes
        case done, failed, stopped, cancelled
        case notConnected
    }

    /// The task, current or most recent.
    struct TaskCard: Equatable {
        enum Status: Equatable {
            case running, waitingForAnswer, waitingForYes, done, failed, stopped
        }

        var goal: String
        var status: Status
        /// What it has done, oldest first. The last one is the current step while running.
        var steps: [String]
        /// The question it asked, or the action it wants a yes for.
        var question: String?
        /// The action held until the yes, in words ("Click “Send” in WhatsApp").
        var heldAction: String?
        /// How it ended, in a sentence.
        var summary: String?
        /// False once it has ended: then it is "the last task".
        var isCurrent: Bool
    }

    /// One line of the conversation.
    struct Message: Equatable, Identifiable {
        let id: Int
        let isFromUser: Bool
        let text: String
    }

    /// Something wrong, with what to do about it.
    struct Trouble: Equatable, Identifiable {
        enum Kind: String, Equatable {
            /// The voice service's set-up does not match the app, so no conversation opens.
            case voiceNotSetUp
            /// The voice connection dropped.
            case notConnected
            /// The wake listener cannot run.
            case cannotListen
            /// Speech is heard, but never the wake phrase.
            case phraseNotHeard
        }

        enum Severity: Equatable {
            /// It cannot work until this is fixed.
            case error
            /// It works, but something needs a look.
            case warning
        }

        let kind: Kind
        var id: String { kind.rawValue }
        let severity: Severity
        let title: String
        let message: String
        let action: Action?
    }

    var wakePhrase: String
    var isAlwaysOpen: Bool
    var isDemo: Bool
    var setupSteps: [SetupStep]
    /// A non-blocking note under the checklist (the optional key), if any.
    var setupNote: String?
    var activity: Activity
    var task: TaskCard?
    var transcript: [Message]
    var trouble: [Trouble]
    var memorySummary: String
    /// Lines for whoever is checking why it does not respond. Counts and states only.
    var details: [String]
    var version: String

    /// The largest panel text size a carer can choose (`PanelTextScale`, 1 to this).
    static let largestTextScale = 1.6

    // MARK: - Rules

    /// Which layout to show.
    var mode: Mode {
        if !isDemo && setupSteps.contains(where: { !$0.isDone }) { return .setup }
        if task?.isCurrent == true { return .active }
        switch activity {
        case .asleep:
            return .ready
        case .listening where isAlwaysOpen && transcript.isEmpty:
            return .ready
        default:
            return .active
        }
    }

    /// The first step that is not done: the one the checklist expands.
    var nextStep: SetupStep? { setupSteps.first { !$0.isDone } }

    var setupDoneCount: Int { setupSteps.filter(\.isDone).count }

    /// The one main button: the next setup step, or the fix for the most serious trouble.
    var primaryAction: Action? {
        if mode == .setup { return nextStep?.action }
        return trouble.first(where: { $0.action != nil })?.action
    }

    /// Any trouble at all: the header then says "Needs attention" rather than "Asleep" or "Working".
    var needsAttention: Bool { !trouble.isEmpty }

    /// False when a problem stops it waking at all: then the ready layout does not promise that it will.
    var canWake: Bool {
        !trouble.contains { $0.kind == .voiceNotSetUp || $0.kind == .cannotListen }
    }

    /// True while an answer is awaited: the panel shows the question in large type.
    var isAwaitingAnswer: Bool {
        activity == .waitingForYes || activity == .question
            || task?.status == .waitingForYes || task?.status == .waitingForAnswer
    }
}
