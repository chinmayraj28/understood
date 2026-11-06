//
//  PanelSnapshotBuilder.swift
//  Handsfree
//
//  Turns what the app knows (permissions and keys, the companion's state,
//  the session log, the listening status) into a `PanelSnapshot`. Only plain
//  values go in, so the mapping is unit tested and the review renders use the
//  same code as the real panel. Pure. New for Handsfree.
//

import Foundation
import HFCore

enum PanelSnapshotBuilder {

    /// Everything the panel is built from.
    struct Inputs {
        var facts: SetupFacts
        var companion: CompanionState
        var log: SessionLog
        var listening: ListeningStatus
        /// From settings (`WAKE_PHRASE`), never written in the panel itself.
        var wakePhrase: String
        var sleepAfterSeconds: Double
        var isAlwaysOpen: Bool
        var isDemo: Bool
        var memorySummary: String
        var partsReal: Int
        var partsTotal: Int
        var version: String
        var now: Date
    }

    /// After this much speech that was not the phrase, with no wake at all, the panel suggests how to say it.
    static let phraseNotHeardThreshold = 3

    static func make(_ inputs: Inputs) -> PanelSnapshot {
        let activity = activity(for: inputs.companion.glyph)
        let steps = setupSteps(inputs.facts)
        // The optional key gets its own note only when the keys step is not already asking for the file.
        let needsKeysFile = steps.contains { $0.kind == .keys }
        return PanelSnapshot(
            wakePhrase: inputs.wakePhrase,
            isAlwaysOpen: inputs.isAlwaysOpen,
            isDemo: inputs.isDemo,
            setupSteps: steps,
            setupNote: inputs.facts.hasOpenRouterKey || needsKeysFile ? nil : PanelCopy.optionalKeyNote,
            activity: activity,
            task: task(log: inputs.log, prompt: inputs.companion.prompt),
            transcript: inputs.log.transcript.map { PanelSnapshot.Message(id: $0.id, isFromUser: $0.speaker == .user, text: $0.text) },
            trouble: trouble(inputs, activity: activity),
            memorySummary: inputs.memorySummary.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details(inputs),
            version: inputs.version)
    }

    // MARK: - Setup

    static func setupSteps(_ facts: SetupFacts) -> [PanelSnapshot.SetupStep] {
        var steps: [PanelSnapshot.SetupStep] = [permissionStep(.microphone, facts.microphone)]
        if facts.needsSpeechRecognition { steps.append(permissionStep(.speechRecognition, facts.speechRecognition)) }
        steps.append(permissionStep(.accessibility, facts.accessibility))
        steps.append(permissionStep(.screenRecording, facts.screenRecording))

        // The keys file is a step only when a key it cannot work without is missing.
        var missing: [String] = []
        if !facts.hasElevenLabsKey { missing.append("ELEVENLABS_API_KEY") }
        if !facts.hasAnthropicKey { missing.append("ANTHROPIC_API_KEY") }
        if !missing.isEmpty {
            let lines = [
                PanelCopy.keysFileLine("ELEVENLABS_API_KEY", isMissing: !facts.hasElevenLabsKey),
                PanelCopy.keysFileLine("ANTHROPIC_API_KEY", isMissing: !facts.hasAnthropicKey),
                PanelCopy.keysFileLine("OPENROUTER_API_KEY", isMissing: !facts.hasOpenRouterKey),
            ]
            steps.append(PanelSnapshot.SetupStep(
                kind: .keys, title: PanelCopy.stepTitle(.keys), reason: PanelCopy.stepReason(.keys),
                isDone: false, stateLabel: PanelCopy.stepNeeded,
                instructions: PanelCopy.keysInstructions,
                detail: facts.keysFilePath, fileLines: lines,
                action: PanelSnapshot.Action(title: PanelCopy.showKeysFileButton, perform: .showKeysFile)))
        }
        return steps
    }

    private static func permissionStep(_ permission: PermissionKind, _ status: PermissionStatus) -> PanelSnapshot.SetupStep {
        let kind = PanelSnapshot.SetupStep.Kind(rawValue: permission.rawValue) ?? .microphone
        let stateLabel: String
        let instructions: String
        let action: PanelSnapshot.Action?
        switch status {
        case .granted:
            stateLabel = PanelCopy.stepDone
            instructions = ""
            action = nil
        case .notAsked:
            stateLabel = PanelCopy.stepNeeded
            instructions = PanelCopy.instructionsNotAsked(permission)
            action = PanelSnapshot.Action(title: PanelCopy.allowButton(permission), perform: .askMacOS(permission))
        case .notGranted:
            stateLabel = PanelCopy.stepTurnedOff
            instructions = PanelCopy.instructionsTurnedOff(permission)
            action = PanelSnapshot.Action(title: PanelCopy.settingsButton(permission), perform: .openSettings(permission))
        }
        return PanelSnapshot.SetupStep(
            kind: kind, title: PanelCopy.stepTitle(kind), reason: PanelCopy.stepReason(kind),
            isDone: status == .granted, stateLabel: stateLabel, instructions: instructions, detail: nil, action: action)
    }

    // MARK: - Activity and task

    static func activity(for glyph: CompanionState.Glyph) -> PanelSnapshot.Activity {
        switch glyph {
        case .asleep: return .asleep
        case .waking: return .waking
        case .connecting: return .connecting
        case .listening: return .listening
        case .userSpeaking: return .hearing
        case .agentSpeaking: return .speaking
        case .thinking, .moving, .clicking, .typing, .scrolling: return .working
        case .asking: return .question
        case .holding: return .waitingForYes
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        case .cancelled: return .cancelled
        case .disconnected: return .notConnected
        }
    }

    /// The current task, or else the most recent one. The companion's prompt tells a question
    /// from a held action; the log only has the latest line.
    static func task(log: SessionLog, prompt: CompanionState.Prompt?) -> PanelSnapshot.TaskCard? {
        if let current = log.currentTask {
            var status: PanelSnapshot.TaskCard.Status = .running
            var question: String?
            var held: String?
            if current.status == .needsInput {
                if let prompt, prompt.isConfirmation {
                    status = .waitingForYes
                    question = prompt.question
                    held = prompt.heldAction
                } else {
                    status = .waitingForAnswer
                    question = prompt?.question ?? current.waitingOn
                }
            }
            return PanelSnapshot.TaskCard(
                goal: current.goal, status: status, steps: current.steps, question: question, heldAction: held,
                summary: nil, isCurrent: true)
        }
        guard let last = log.recentTasks.first else { return nil }
        let status: PanelSnapshot.TaskCard.Status
        switch last.status {
        case .done: status = .done
        case .failed: status = .failed
        case .cancelled: status = .stopped
        case .running, .needsInput: status = .stopped  // ended by a newer task; it did not finish
        }
        return PanelSnapshot.TaskCard(
            goal: last.goal, status: status, steps: last.steps, question: nil, heldAction: nil,
            summary: last.summary, isCurrent: false)
    }

    // MARK: - Trouble

    static func trouble(_ inputs: Inputs, activity: PanelSnapshot.Activity) -> [PanelSnapshot.Trouble] {
        guard !inputs.isDemo else { return [] }
        var found: [PanelSnapshot.Trouble] = []
        let listening = inputs.listening

        if let agent = listening.agent, !agent.inSync {
            found.append(PanelSnapshot.Trouble(
                kind: .voiceNotSetUp, severity: .error,
                title: PanelCopy.voiceNotSetUpTitle, message: PanelCopy.voiceNotSetUpMessage, action: nil))
        }

        if activity == .notConnected || inputs.log.voiceProblem != nil {
            found.append(PanelSnapshot.Trouble(
                kind: .notConnected, severity: .error,
                title: PanelCopy.notConnectedTitle, message: PanelCopy.notConnectedMessage(reason: inputs.log.voiceProblem), action: nil))
        }

        if !inputs.isAlwaysOpen, let problem = listening.listenerProblem {
            let microphoneOff = inputs.facts.microphone != .granted
            found.append(PanelSnapshot.Trouble(
                kind: .cannotListen, severity: .error,
                title: PanelCopy.cannotListenTitle(wakePhrase: inputs.wakePhrase),
                message: PanelCopy.cannotListenMessage(reason: problem),
                action: microphoneOff ? PanelSnapshot.Action(title: PanelCopy.settingsButton(.microphone), perform: .openSettings(.microphone)) : nil))
        } else if !inputs.isAlwaysOpen, listening.wakeCount == 0,
            listening.speechWithoutPhraseCount >= phraseNotHeardThreshold
        {
            found.append(PanelSnapshot.Trouble(
                kind: .phraseNotHeard, severity: .warning,
                title: PanelCopy.phraseNotHeardTitle(wakePhrase: inputs.wakePhrase),
                message: PanelCopy.phraseNotHeardMessage(count: listening.speechWithoutPhraseCount, language: shortLanguage(listening.language)),
                action: nil))
        }
        return found
    }

    /// "English (India), en_IN (the Mac's own language…)" becomes "English (India)".
    static func shortLanguage(_ described: String) -> String {
        described.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    // MARK: - Details

    static func details(_ inputs: Inputs) -> [String] {
        let listening = inputs.listening
        let voice = PanelCopy.voiceDetail(
            isReady: listening.agent?.inSync,
            checkedAgo: listening.agent.map { ago($0.checkedAt, now: inputs.now) })
        let lines = [
            voice,
            listening.listenerLine,
            listening.languageLine,
            listening.conversationLine,
            listening.heardLine(now: inputs.now),
            inputs.partsTotal > 0 ? PanelCopy.partsDetail(real: inputs.partsReal, total: inputs.partsTotal) : "",
        ]
        return lines.filter { !$0.isEmpty }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}
