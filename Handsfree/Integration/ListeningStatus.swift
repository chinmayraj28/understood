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

/// The language the wake phrase is listened for in: WAKE_LANGUAGE, or the Mac's own when empty.
/// Accent matters a great deal to the recogniser, so it is shown in the panel and the status file.
enum AppWakeLanguage {
    static func locale(for setting: String) -> Locale {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Locale.current : Locale(identifier: trimmed.replacingOccurrences(of: "-", with: "_"))
    }

    /// For example "English (India), en_IN, the Mac's own language".
    static func describe(setting: String) -> String {
        let locale = locale(for: setting)
        let name = Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let source = setting.trimmingCharacters(in: .whitespaces).isEmpty ? "the Mac's own language; set WAKE_LANGUAGE to change it" : "set by WAKE_LANGUAGE"
        return "\(name), \(locale.identifier) (\(source))"
    }
}

struct ListeningStatus: Equatable {
    /// The language the phrase is listened for in, described for people.
    var language = ""
    /// Phrases other than the main one that also wake it, and how sure the matcher must be.
    var alternatives: [String] = []
    var strictness = "balanced"
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
    /// How long a conversation stays open with nobody speaking and no task, from SLEEP_AFTER_IDLE_S.
    var sleepAfterIdleSeconds = 15.0

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

    /// The voice agent on ElevenLabs, as last checked against the app's tools.
    var agent: AgentStatus?

    /// One line on the voice agent, for the panel. Out of step, the app opens no conversation.
    func agentLine(now: Date) -> String {
        guard let agent else { return "Voice agent: not checked yet." }
        let when = ago(agent.checkedAt, now: now)
        if agent.inSync {
            return "Voice agent: in step with the app (\(agent.toolCount) tools), checked \(when)."
        }
        var line = "Voice agent: NOT in step with the app, so no conversation opens. \(agent.problem ?? "") Retrying in the background; checked \(when)."
        if !agent.missing.isEmpty { line += " Missing: \(agent.missing.joined(separator: ", "))." }
        if !agent.unexpected.isEmpty { line += " Not the app's: \(agent.unexpected.joined(separator: ", "))." }
        return line
    }

    /// What it listens for and how, for the panel: the first thing to check if the phrase is not heard.
    var languageLine: String {
        guard !alwaysOpen else { return "" }
        var line = "Listening in \(language)."
        if !alternatives.isEmpty {
            line += " Also wakes on " + alternatives.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + "."
        }
        if strictness != "balanced" { line += " Matching: \(strictness)." }
        return line
    }

    /// When an open conversation closes: the first thing a new user wondered (6 Nov).
    var whenItSleeps: String {
        guard !alwaysOpen else { return " It stays open (WAKE_MODE=always)." }
        return " Goes back to sleep after \(Int(sleepAfterIdleSeconds.rounded())) seconds of quiet, or when they say \u{201C}that\u{2019}s all\u{201D}, with a falling chime; never while a task is running or waiting for an answer."
    }

    /// One line on the conversation, for the panel.
    var conversationLine: String {
        if conversationConnected { return "Conversation: open, and the voice service can hear." + whenItSleeps }
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
            "wake_language": language,
            "wake_alternatives": alternatives,
            "wake_strictness": strictness,
            "agent": agent.map { agent -> [String: Any] in
                ["in_sync": agent.inSync, "tool_count": agent.toolCount, "expected_tool_count": agent.expectedToolCount,
                 "checked_seconds_ago": Int(now.timeIntervalSince(agent.checkedAt)), "problem": agent.problem ?? "",
                 "missing": agent.missing, "unexpected": agent.unexpected]
            } ?? ["in_sync": "not checked yet"],
            "waiting_for": waitingFor ?? "",
            "wake_listener": listener,
            "conversation": ["open": conversationOpen, "connected": conversationConnected],
        ]
    }
}
