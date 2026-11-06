//
//  ListeningStatus.swift
//  Handsfree
//
//  What the app can say about its own listening, for diagnosis: is the wake
//  listener running, is a conversation open, which permissions are missing,
//  and how often it has heard speech that was not the wake phrase. The first
//  real test of the phrase is someone saying it to the app, and this is what
//  lets them tell "it cannot hear me" from "it heard me but did not recognise
//  the phrase".
//
//  Privacy: nothing here holds what was said. Speech heard while asleep is
//  only counted, with the time of the last one. Pure value type, unit tested.
//  New for Handsfree.
//

import Foundation

/// Something the wake listener reported, without any words.
enum WakeListenerEvent: Equatable {
    /// Listening started, with this recogniser.
    case started(recognizer: String)
    /// Speech was heard that was not the wake phrase. Never carries what was said.
    case speechWithoutPhrase
    /// The wake phrase was heard.
    case phraseHeard
    /// It woke: the conversation is being opened.
    case woke
    /// The microphone or recogniser stopped by itself and is being restarted.
    case restarting
    /// Listening could not be restarted.
    case cannotListen(reason: String)
}

struct ListeningStatus: Equatable {
    /// Where the cycle is: asleep, waking, awake, falling asleep, cannot listen, stopped, or not started.
    var cycleState = "not started"
    /// What is keeping the cycle from starting, in plain words, if anything.
    var waitingFor: String?
    /// The wake listener has the microphone and its recogniser is running.
    var listenerRunning = false
    var recognizer: String?
    /// The latest reason it cannot listen, until it listens again.
    var listenerProblem: String?
    var conversationOpen = false
    var conversationConnected = false
    var wakePhrase = "Hey Handsfree"
    var alwaysOpen = false

    // Counts since launch. Only counts and times: never what was said.
    private(set) var speechWithoutPhraseCount = 0
    private(set) var lastSpeechWithoutPhraseAt: Date?
    private(set) var phraseHeardCount = 0
    private(set) var wakeCount = 0
    private(set) var lastWakeAt: Date?
    private(set) var restartCount = 0

    mutating func record(_ event: WakeListenerEvent, at time: Date) {
        switch event {
        case .started(let name):
            recognizer = name
            listenerProblem = nil
        case .speechWithoutPhrase:
            speechWithoutPhraseCount += 1
            lastSpeechWithoutPhraseAt = time
        case .phraseHeard:
            phraseHeardCount += 1
        case .woke:
            wakeCount += 1
            lastWakeAt = time
        case .restarting:
            restartCount += 1
        case .cannotListen(let reason):
            listenerProblem = reason
        }
    }

    /// One line on the wake listener, for the panel.
    var listenerLine: String {
        if alwaysOpen { return "Wake listener: off (WAKE_MODE=always keeps a conversation open)." }
        if let waitingFor { return "Wake listener: not started. Waiting for \(waitingFor)." }
        if let listenerProblem { return "Wake listener: not running. \(listenerProblem)" }
        if listenerRunning {
            return "Wake listener: listening on this Mac for \u{201C}\(wakePhrase)\u{201D}" + (recognizer.map { ", using \($0)." } ?? ".")
        }
        if conversationOpen { return "Wake listener: paused while the conversation has the microphone." }
        if cycleState == "asleep" {
            // HFWake marks itself asleep, then starts the listener; the first start downloads
            // Apple's speech model, which can take a while and needs the internet once.
            return "Wake listener: starting. The first start downloads Apple's speech model (no audio is sent), which needs the internet once."
        }
        return "Wake listener: not running (\(cycleState))."
    }

    /// One line on the conversation, for the panel.
    var conversationLine: String {
        if conversationConnected { return "Conversation: open, and the voice service can hear." }
        if conversationOpen { return "Conversation: opening or reconnecting\u{2026}" }
        return "Conversation: closed. Nothing said reaches the voice service."
    }

    /// What it has heard since launch, as counts, for the panel. This is the line that tells
    /// "it cannot hear me" (all zero while someone speaks) from "it heard me but not the phrase".
    func heardLine(now: Date) -> String {
        guard !alwaysOpen else { return "" }
        var parts: [String] = []
        parts.append(speechWithoutPhraseCount == 0
            ? "no other speech heard yet"
            : "heard speech \(times(speechWithoutPhraseCount)) that was not \u{201C}\(wakePhrase)\u{201D}"
                + (lastSpeechWithoutPhraseAt.map { ", last \(ago($0, now: now))" } ?? ""))
        parts.append(wakeCount == 0 ? "not woken yet" : "woke \(times(wakeCount))" + (lastWakeAt.map { ", last \(ago($0, now: now))" } ?? ""))
        return "Since launch: " + parts.joined(separator: "; ") + ". What was said is never kept."
    }

    private func times(_ count: Int) -> String { count == 1 ? "once" : "\(count) times" }

    private func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    /// For app-status.json. Counts and states only.
    func statusDictionary(now: Date) -> [String: Any] {
        var listener: [String: Any] = [
            "running": listenerRunning,
            "recognizer": recognizer ?? "",
            "problem": listenerProblem ?? "",
            "speech_without_phrase_count": speechWithoutPhraseCount,
            "phrase_heard_count": phraseHeardCount,
            "wake_count": wakeCount,
            "restart_count": restartCount,
        ]
        if let lastSpeechWithoutPhraseAt { listener["last_speech_without_phrase_seconds_ago"] = Int(now.timeIntervalSince(lastSpeechWithoutPhraseAt)) }
        if let lastWakeAt { listener["last_wake_seconds_ago"] = Int(now.timeIntervalSince(lastWakeAt)) }
        return [
            "cycle_state": cycleState,
            "waiting_for": waitingFor ?? "",
            "wake_listener": listener,
            "conversation": ["open": conversationOpen, "connected": conversationConnected],
        ]
    }
}
