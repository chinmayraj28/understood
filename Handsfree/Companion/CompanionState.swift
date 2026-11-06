//
//  CompanionState.swift
//  Handsfree
//
//  What the companion beside the pointer is showing, worked out from the
//  ActivityBus events every package posts. Pure value type with an injected
//  clock: no AppKit, no timers, so every rule here is unit tested.
//
//  New for Handsfree. Clicky's equivalent was a four-case voice state
//  (idle, listening, processing, responding) inside CompanionManager.swift;
//  ours has to show an agent that acts, so it tracks the voice, what the hands
//  are doing, a held action waiting for a yes, and a target on screen.
//

import CoreGraphics
import Foundation
import HFCore

/// How long each thing stays on screen. One place, so the feel can be tuned.
/// The user cannot dismiss anything by hand, so every item here ends by itself.
enum CompanionTiming {
    /// The sentence we heard, shown back so the user knows it was understood.
    static let heardCaptionSeconds = 4.0
    /// A progress line such as "Opening WhatsApp". Usually replaced sooner by the next one.
    static let progressCaptionSeconds = 10.0
    static let resultCaptionSeconds = 6.0
    static let stoppedSeconds = 3.0
    static let finishedSeconds = 4.5
    static let disconnectedCaptionSeconds = 8.0
    static let reconnectedCaptionSeconds = 2.5
    /// No new microphone level for this long means the user has stopped talking.
    static let userSpeakingSilenceSeconds = 0.7
    static let clickRippleSeconds = 1.1
    /// A target that was travelled to but not clicked stays this long after arrival.
    static let arrivedTargetLingerSeconds = 0.8
    static let clickingSeconds = 0.6
    static let typingQuietSeconds = 1.2
    static let scrollQuietSeconds = 0.9
    /// A question or held action stays until it is answered; this is only a backstop
    /// in case the task runner never says so (it gives up on a question after 120 s).
    static let promptBackstopSeconds = 180.0

    /// How long a spoken sentence stays as a caption: reading speed plus a pause, clamped.
    static func spokenCaptionSeconds(for text: String) -> Double {
        let readingSeconds = Double(text.count) / 14.0
        return min(max(readingSeconds + 1.5, 2.5), 10.0)
    }
}

struct CompanionState: Equatable {

    // MARK: - Types

    /// The voice connection, from HFVoice's events.
    enum VoiceStatus: Equatable {
        case connecting
        case listening
        case userSpeaking
        case agentSpeaking
        case disconnected
    }

    /// What the agent itself is doing, from the hands, the screen agent and the task runner.
    enum Activity: Equatable {
        case idle
        case thinking
        case moving
        case clicking
        case typing
        case scrolling
        /// An action is held until the user says yes.
        case holding
        /// A question is waiting for the user's answer.
        case asking
        /// The user said stop.
        case stopped
        case finished(TaskStatus)
    }

    /// The one symbol drawn beside the pointer. Worked out from voice and activity
    /// by `glyph`, in a fixed priority order.
    enum Glyph: Equatable {
        case connecting, listening, userSpeaking, agentSpeaking
        case thinking, moving, clicking, typing, scrolling
        case holding, asking
        case stopped, done, failed, cancelled
        case disconnected
    }

    /// The colour family of a caption.
    enum Tone: Equatable {
        case heard  // what the user said
        case spoken  // what the agent said
        case progress  // what the agent is doing
        case success
        case problem
        case stop
        case muted
    }

    struct Caption: Equatable {
        var text: String
        var tone: Tone
        var expiresAt: Date
    }

    /// A question, or a held action waiting for a yes, shown as a card until it is resolved.
    struct Prompt: Equatable {
        /// What the user is asked, e.g. `Send "running late" to Amma?`.
        var question: String?
        /// The action being held, e.g. `Click button "Send" in WhatsApp, window "Amma"`.
        /// When set, this prompt is a confirmation: nothing happens without a yes.
        var heldAction: String?
        var since: Date
        var expiresAt: Date

        var isConfirmation: Bool { heldAction != nil }
    }

    /// A ring on the screen where the pointer is going, has clicked, or is holding.
    struct TargetMarker: Equatable {
        enum Phase: Equatable {
            /// The pointer is gliding here; the ring closes in as it arrives.
            case approaching
            /// A click landed here; a halo ripples out.
            case clicked
            /// The pointer is here and the click is held until the user says yes.
            case held
        }

        /// Screen points, origin at the top left of the main display (HFCore's convention).
        var point: CGPoint
        var phase: Phase
        var phaseStartedAt: Date
        /// For `.approaching`: how long the glide takes.
        var travelSeconds: Double
        var expiresAt: Date?
    }

    // MARK: - State

    var voice: VoiceStatus = .connecting
    /// 0...1, for the waveform.
    var voiceLevel: Double = 0
    var lastVoiceLevelAt: Date?
    var voiceExpiresAt: Date?

    var activity: Activity = .idle
    var activityExpiresAt: Date?

    var caption: Caption?
    var prompt: Prompt?
    var target: TargetMarker?
    /// The goal of the task in progress, if any.
    var currentGoal: String?

    // MARK: - Derived

    /// The symbol beside the pointer. Earlier rules win.
    var glyph: Glyph {
        if activity == .stopped { return .stopped }
        // The user talking always shows, so they can see they are heard,
        // including while a confirmation is waiting for their answer.
        if voice == .userSpeaking { return .userSpeaking }
        if activity == .holding { return .holding }
        if activity == .asking { return .asking }
        if voice == .disconnected { return .disconnected }
        switch activity {
        case .thinking: return .thinking
        case .moving: return .moving
        case .clicking: return .clicking
        case .typing: return .typing
        case .scrolling: return .scrolling
        case .finished(.done): return .done
        case .finished(.failed): return .failed
        case .finished(.cancelled): return .cancelled
        default: break
        }
        if voice == .agentSpeaking { return .agentSpeaking }
        if voice == .connecting { return .connecting }
        return .listening
    }

    /// When nothing is happening the companion shrinks to a small calm dot.
    var isResting: Bool { glyph == .listening && caption == nil && prompt == nil }

    // MARK: - Events

    /// Folds one event into the state.
    mutating func apply(_ event: ActivityEvent, now: Date) {
        switch event {
        case .listening:
            let wasDisconnected = voice == .disconnected
            voice = .listening
            voiceLevel = 0
            voiceExpiresAt = nil
            if wasDisconnected {
                // Replace "Not connected" at once, so the caption never contradicts the glyph.
                caption = Caption(text: "Connected again", tone: .success, expiresAt: now.addingTimeInterval(CompanionTiming.reconnectedCaptionSeconds))
            }

        case .userSpeaking(let level):
            voice = .userSpeaking
            voiceLevel = min(max(level, 0), 1)
            lastVoiceLevelAt = now
            voiceExpiresAt = nil

        case .userSaid(let text):
            voice = .listening
            voiceLevel = 0
            voiceExpiresAt = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                caption = Caption(
                    text: "\u{201C}\(trimmed)\u{201D}", tone: .heard,
                    expiresAt: now.addingTimeInterval(CompanionTiming.heardCaptionSeconds))
            }

        case .agentSpeaking(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let speakingSeconds = CompanionTiming.spokenCaptionSeconds(for: trimmed)
            voice = .agentSpeaking
            voiceExpiresAt = now.addingTimeInterval(speakingSeconds)
            // While a question or confirmation card is up, the card is what to read:
            // a second box with the spoken version of the question is clutter.
            // (Everything said is still in the panel's transcript.)
            if !trimmed.isEmpty && prompt == nil {
                caption = Caption(text: trimmed, tone: .spoken, expiresAt: now.addingTimeInterval(speakingSeconds))
            }

        case .voiceDisconnected:
            voice = .disconnected
            voiceLevel = 0
            voiceExpiresAt = nil
            caption = Caption(
                text: "Not connected. Trying again\u{2026}", tone: .muted,
                expiresAt: now.addingTimeInterval(CompanionTiming.disconnectedCaptionSeconds))

        case .thinking(let text):
            // A task that is thinking again has had its question answered.
            prompt = nil
            if target?.phase == .held { target = nil }
            setActivity(.thinking, until: nil)
            showProgress(text, now: now)

        case .pointerMoving(let destination, let duration):
            // A move that takes no time is the hands reporting where the pointer really is,
            // for example where it stopped after "stop". The companion follows the real
            // pointer anyway, so there is no ring to draw, and it must not end "Stopped".
            guard duration > 0 else {
                if target?.phase == .approaching { target = nil }
                return
            }
            prompt = nil
            let travelSeconds = max(duration, 0)
            setActivity(.moving, until: now.addingTimeInterval(travelSeconds + 0.3))
            target = TargetMarker(
                point: destination, phase: .approaching, phaseStartedAt: now, travelSeconds: travelSeconds,
                expiresAt: now.addingTimeInterval(travelSeconds + CompanionTiming.arrivedTargetLingerSeconds))

        case .clicked(let point):
            prompt = nil
            setActivity(.clicking, until: now.addingTimeInterval(CompanionTiming.clickingSeconds))
            target = TargetMarker(
                point: point, phase: .clicked, phaseStartedAt: now, travelSeconds: 0,
                expiresAt: now.addingTimeInterval(CompanionTiming.clickRippleSeconds))

        case .typing:
            prompt = nil
            if target?.phase == .held { target = nil }
            setActivity(.typing, until: now.addingTimeInterval(CompanionTiming.typingQuietSeconds))

        case .scrolled:
            prompt = nil
            if target?.phase == .held { target = nil }
            setActivity(.scrolling, until: now.addingTimeInterval(CompanionTiming.scrollQuietSeconds))

        case .taskStarted(let goal):
            currentGoal = goal
            prompt = nil
            target = nil
            setActivity(.thinking, until: nil)
            showProgress(goal, now: now)

        case .progress(let text):
            if activity == .idle || Self.isFinished(activity) { setActivity(.thinking, until: nil) }
            showProgress(text, now: now)

        case .waitingForAnswer(let question):
            if var existing = prompt, existing.isConfirmation {
                existing.question = question
                prompt = existing
                setActivity(.holding, until: nil)
            } else {
                prompt = Prompt(
                    question: question, heldAction: nil, since: now,
                    expiresAt: now.addingTimeInterval(CompanionTiming.promptBackstopSeconds))
                setActivity(.asking, until: nil)
            }
            caption = nil

        case .heldForConfirmation(let action):
            // If the question arrived first, keep it.
            let earlierQuestion = prompt?.question
            prompt = Prompt(
                question: earlierQuestion, heldAction: action, since: now,
                expiresAt: now.addingTimeInterval(CompanionTiming.promptBackstopSeconds))
            setActivity(.holding, until: nil)
            if var marker = target {
                marker.phase = .held
                marker.phaseStartedAt = now
                marker.expiresAt = nil
                target = marker
            }
            caption = nil

        case .taskEnded(let status, let summary):
            prompt = nil
            target = nil
            currentGoal = nil
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Stop" already shows; a cancelled result right after it should not replace it.
            if activity == .stopped && status == .cancelled {
                if !trimmed.isEmpty { caption = Caption(text: trimmed, tone: .stop, expiresAt: now.addingTimeInterval(CompanionTiming.resultCaptionSeconds)) }
                return
            }
            switch status {
            case .done:
                setActivity(.finished(.done), until: now.addingTimeInterval(CompanionTiming.finishedSeconds))
                caption = Caption(text: trimmed.isEmpty ? "Done" : trimmed, tone: .success, expiresAt: now.addingTimeInterval(CompanionTiming.resultCaptionSeconds))
            case .failed:
                setActivity(.finished(.failed), until: now.addingTimeInterval(CompanionTiming.finishedSeconds))
                caption = Caption(text: trimmed.isEmpty ? "I couldn\u{2019}t finish that" : trimmed, tone: .problem, expiresAt: now.addingTimeInterval(CompanionTiming.resultCaptionSeconds))
            case .cancelled:
                setActivity(.finished(.cancelled), until: now.addingTimeInterval(CompanionTiming.finishedSeconds))
                caption = Caption(text: trimmed.isEmpty ? "Cancelled" : trimmed, tone: .muted, expiresAt: now.addingTimeInterval(CompanionTiming.resultCaptionSeconds))
            case .running, .needsInput:
                // Not a real end; treat it as progress so nothing gets stuck.
                showProgress(trimmed, now: now)
            }

        case .halted:
            // The same stop may be reported more than once (by the runner, the stop watcher
            // and the hands). Show it once; a repeat must not restart it or bring back
            // "Stopped" after the task's own summary has replaced it.
            if activity == .stopped { return }
            prompt = nil
            target = nil
            setActivity(.stopped, until: now.addingTimeInterval(CompanionTiming.stoppedSeconds))
            caption = Caption(text: "Stopped", tone: .stop, expiresAt: now.addingTimeInterval(CompanionTiming.stoppedSeconds))
        }
    }

    /// Removes whatever has run out of time. Called several times a second.
    mutating func expire(now: Date) {
        if let caption, caption.expiresAt <= now { self.caption = nil }
        if let prompt, prompt.expiresAt <= now {
            self.prompt = nil
            if activity == .holding || activity == .asking { setActivity(currentGoal == nil ? .idle : .thinking, until: nil) }
            if target?.phase == .held { target = nil }
        }
        if let expiry = target?.expiresAt, expiry <= now { target = nil }

        if let expiry = activityExpiresAt, expiry <= now {
            switch activity {
            case .moving, .clicking, .typing, .scrolling:
                // Between two actions of a task the screen agent is deciding again.
                setActivity(currentGoal == nil ? .idle : .thinking, until: nil)
            default:
                setActivity(.idle, until: nil)
            }
        }

        switch voice {
        case .userSpeaking:
            if let lastLevel = lastVoiceLevelAt, now.timeIntervalSince(lastLevel) >= CompanionTiming.userSpeakingSilenceSeconds {
                voice = .listening
                voiceLevel = 0
            }
        case .agentSpeaking:
            if let expiry = voiceExpiresAt, expiry <= now {
                voice = .listening
                voiceExpiresAt = nil
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private mutating func setActivity(_ newActivity: Activity, until expiry: Date?) {
        activity = newActivity
        activityExpiresAt = expiry
    }

    private mutating func showProgress(_ text: String, now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        caption = Caption(text: trimmed, tone: .progress, expiresAt: now.addingTimeInterval(CompanionTiming.progressCaptionSeconds))
    }

    private static func isFinished(_ activity: Activity) -> Bool {
        if case .finished = activity { return true }
        return activity == .stopped
    }

    /// True when two sentences have the same words, ignoring case, punctuation and quotes.
    static func sameWords(_ first: String, _ second: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        return words(first) == words(second)
    }
}
