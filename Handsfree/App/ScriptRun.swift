//
//  ScriptRun.swift
//  Handsfree
//
//  Test-only: `scripts/run_app.sh --wait --script <file>`. Drives the BUILT app
//  through a whole flow with typed turns instead of speech: a text conversation
//  on the TEST agent (never the user's), no microphone (a script wake listener
//  that only pretends to hear the phrase) and no sound (the chimes are off).
//  Everything else is the real app: HFWake's cycle, the real tools, the task
//  runner, the screen agent with the real pointer and keys, the safety gate,
//  and the app's own sign-off handling. It records timings and checks results
//  by reading the screen (the front app, the document's text through the
//  accessibility API, read only), then writes <data dir>/script-run.json and
//  quits. It cannot be reached from the panel. New for Handsfree.
//
//  Script lines (one per line, "#" starts a comment):
//    wake <rest of the sentence>      the wake phrase was "heard", with these words after it
//    say <sentence>                   a typed user turn; waits up to 12 s for a reply (not required)
//    expect-reply                     the agent replied to the last turn
//    expect-tool <name>               the last turn called this tool
//    expect-no-tool                   the last turn called no tool
//    expect-reply-without <w1,w2>     the last reply contains none of these words
//    expect-reply-with <w1,w2>        the last reply contains at least one of these words
//    expect-no-task                   no task started since the last turn
//    require-unlocked                 stop the run here if the screen is locked (nothing can be clicked)
//    expect-front <App>               this app is in front (read only)
//    wait-task <seconds>              wait for the task to end and its result to be said
//    expect-text <App> | <words>      the front document of App contains these words (read only)
//    wait-asleep <seconds>            the conversation closed and the cycle is asleep again
//    close-without-saving <App>       Command-W, then the save sheet's Delete button (cleanup)
//

import AppKit
import ApplicationServices
import Foundation
import HFCore
import os

/// A wake listener that never opens the microphone: the script says when the phrase was heard.
final class ScriptWakeListener: WakeListening, @unchecked Sendable {
    private let lock = NSLock()
    private var onWake: (@Sendable (String) -> Void)?
    private var listening = false
    private(set) var startCount = 0

    func start(onWake: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock { self.onWake = onWake; listening = true; startCount += 1 }
    }
    func stop() async { lock.withLock { onWake = nil; listening = false } }
    var isListening: Bool { lock.withLock { listening } }
    var starts: Int { lock.withLock { startCount } }

    /// "Hey Handsfree", then `rest`. Does nothing unless the cycle is listening.
    func hear(_ rest: String) {
        let handler = lock.withLock { onWake }
        handler?(rest)
    }
}

/// Every tool call the agent makes: which, when, how long, and whether it worked.
final class ToolCallLog: @unchecked Sendable {
    struct Call: Sendable {
        let name: String
        let startedAt: Date
        var finishedAt: Date?
        var ok: Bool?
        var error: String?
    }
    private let lock = NSLock()
    private var calls: [Call] = []

    func wrap(_ tools: [ToolSpec]) -> [ToolSpec] {
        tools.map { tool in
            ToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters,
                     tier: tool.tier, timeoutSeconds: tool.timeoutSeconds) { [weak self] parameters in
                let index = self?.begin(tool.name) ?? 0
                let result = await tool.handler(parameters)
                self?.end(index, ok: result["ok"]?.boolValue ?? true, error: result["error"]?.stringValue)
                return result
            }
        }
    }
    private func begin(_ name: String) -> Int {
        lock.withLock { calls.append(Call(name: name, startedAt: Date())); return calls.count - 1 }
    }
    private func end(_ index: Int, ok: Bool, error: String?) {
        lock.withLock { if index < calls.count { calls[index].finishedAt = Date(); calls[index].ok = ok; calls[index].error = error } }
    }
    func since(_ date: Date) -> [Call] { lock.withLock { calls.filter { $0.startedAt >= date } } }
}

@MainActor
final class ScriptRun {
    struct Step: Equatable {
        let verb: String
        let argument: String
    }

    /// One line per step; blank lines and "#" comments are skipped.
    static func parse(_ text: String) -> [Step] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            return Step(verb: String(parts[0]).lowercased(), argument: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
        }
    }

    struct Outcome {
        var step: String
        var ok: Bool
        var detail: String
        var seconds: Double
    }

    private let steps: [Step]
    private let voice: any VoiceConnecting
    private let cycle: any ListeningCycling
    private let listener: ScriptWakeListener
    private let tools: ToolCallLog
    private let labels: any Labels
    private let hands: any Hands
    private let safetyGate: any SafetyGating
    private let bus: ActivityBus
    private let logger = Logger(subsystem: "com.handsfree", category: "script")

    // What the bus showed, with times.
    private var replies: [(Date, String)] = []
    private var progressAt: [Date] = []
    private var thinkingAt: [Date] = []
    private var taskStartedAt: Date?
    private var taskEnded: (Date, TaskStatus, String)?
    private var questions: [(Date, String)] = []
    private var watching: Task<Void, Never>?

    private var lastTurnStartedAt = Date()
    private var outcomes: [Outcome] = []
    private var textEditWasRunning = false

    init(steps: [Step], voice: any VoiceConnecting, cycle: any ListeningCycling, listener: ScriptWakeListener,
         tools: ToolCallLog, labels: any Labels, hands: any Hands, safetyGate: any SafetyGating, bus: ActivityBus) {
        self.steps = steps
        self.voice = voice
        self.cycle = cycle
        self.listener = listener
        self.tools = tools
        self.labels = labels
        self.hands = hands
        self.safetyGate = safetyGate
        self.bus = bus
    }

    /// Runs every step in order; returns the report as JSON-ready values.
    func run() async -> [String: Any] {
        let started = Date()
        textEditWasRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.TextEdit" }
        let events = bus.events()
        watching = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                let now = Date()
                switch event {
                case .agentSpeaking(let text): self.replies.append((now, text))
                case .progress: self.progressAt.append(now)
                case .thinking: self.thinkingAt.append(now)
                case .taskStarted: self.taskStartedAt = now
                case .taskEnded(let status, let summary): self.taskEnded = (now, status, summary)
                case .waitingForAnswer(let question): self.questions.append((now, question))
                default: break
                }
            }
        }
        // The cycle must be asleep and "listening" (to the script) before the first wake.
        _ = await waitUntil(30) { [listener] in listener.isListening }
        for step in steps {
            let stepStarted = Date()
            let (ok, detail) = await perform(step)
            let outcome = Outcome(step: "\(step.verb) \(step.argument)".trimmingCharacters(in: .whitespaces), ok: ok,
                                  detail: detail, seconds: Date().timeIntervalSince(stepStarted))
            outcomes.append(outcome)
            logger.notice("SCRIPT \(ok ? "ok  " : "FAIL", privacy: .public) \(outcome.step, privacy: .public): \(detail, privacy: .public)")
            if step.verb == "require-unlocked", !ok { break }
        }
        watching?.cancel()
        return [
            "started_at": ISO8601DateFormatter().string(from: started),
            "total_seconds": Date().timeIntervalSince(started),
            "passed": outcomes.allSatisfy(\.ok),
            "steps": outcomes.map { ["step": $0.step, "ok": $0.ok, "detail": $0.detail, "seconds": ($0.seconds * 100).rounded() / 100] },
            "wake_listener_starts": listener.starts,
        ]
    }

    // MARK: Steps

    private func perform(_ step: Step) async -> (Bool, String) {
        switch step.verb {
        case "wake":
            lastTurnStartedAt = Date()
            let repliesBefore = replies.count
            listener.hear(step.argument)
            let gotReply = await waitUntil(30) { self.replies.count > repliesBefore }
            if gotReply { await settleTurn() }
            return (gotReply, turnSummary(repliesBefore: repliesBefore, connected: voice.isConversationConnected))
        case "say":
            lastTurnStartedAt = Date()
            let repliesBefore = replies.count
            do { try await voice.sendTypedTurn(step.argument) } catch {
                return (false, "could not send: \(error)")
            }
            // A reply is waited for (up to 12 s) but not required: after "that's all" saying nothing is right.
            _ = await waitUntil(12) { self.replies.count > repliesBefore }
            await settleTurn()
            return (true, turnSummary(repliesBefore: repliesBefore, connected: true))
        case "expect-tool":
            let names = tools.since(lastTurnStartedAt).map(\.name)
            return (names.contains(step.argument), "tools this turn: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        case "expect-reply":
            let said = replies.filter { $0.0 >= lastTurnStartedAt }.map(\.1)
            return (!said.isEmpty, said.isEmpty ? "no reply to the last turn" : "reply: \"\(said.joined(separator: " "))\"")
        case "expect-reply-with":
            let words = step.argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let said = replies.filter { $0.0 >= lastTurnStartedAt }.map(\.1).joined(separator: " ")
            let found = words.filter { said.lowercased().contains($0) }
            return (!found.isEmpty, "reply: \"\(said)\"")
        case "expect-no-task":
            let started = taskStartedAt.map { $0 >= lastTurnStartedAt } ?? false
            return (!started, started ? "a task started" : "no task started")
        case "expect-no-tool":
            let names = tools.since(lastTurnStartedAt).map(\.name)
            return (names.isEmpty, "tools this turn: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        case "expect-reply-without":
            let words = step.argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let said = replies.filter { $0.0 >= lastTurnStartedAt }.map(\.1).joined(separator: " ")
            let found = words.filter { said.lowercased().contains($0) }
            return (found.isEmpty && !said.isEmpty, found.isEmpty ? "reply: \"\(said)\"" : "reply used \(found.joined(separator: ", ")): \"\(said)\"")
        case "require-unlocked":
            let front = await labels.frontmost()
            let locked = Self.screenIsLocked() || front.app == "loginwindow"
            return (!locked, locked
                ? "the screen is locked (in front: \(front.app)); nothing can be clicked or typed until someone unlocks it, so the run stops here"
                : "the screen is unlocked (in front: \(front.app))")
        case "expect-front":
            let front = await labels.frontmost()
            return (front.app.localizedCaseInsensitiveContains(step.argument), "in front: \(front.app), window \"\(front.window)\"")
        case "wait-task":
            return await waitForTask(seconds: Double(step.argument) ?? 180)
        case "expect-text":
            let parts = step.argument.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return (false, "write: expect-text <App> | <words>") }
            let text = Self.documentText(appName: parts[0]) ?? ""
            return (text.localizedCaseInsensitiveContains(parts[1]), "the document holds \(text.count) characters" + (text.isEmpty ? "" : ": \"\(text.prefix(80))\""))
        case "wait-asleep":
            let since = Date()
            let asleep = await waitUntil(Double(step.argument) ?? 30) {
                self.voice.conversationActivity.isOpen == false && self.listener.isListening
            }
            let state = await cycle.currentState()
            let afterLastTurn = Date().timeIntervalSince(lastTurnStartedAt)
            return (asleep, "cycle \(state); conversation \(voice.conversationActivity.isOpen ? "open" : "closed"); "
                    + String(format: "asleep %.1f s after the last turn was sent (%.1f s of waiting here)", afterLastTurn, Date().timeIntervalSince(since)))
        case "close-without-saving":
            return await closeWithoutSaving(appName: step.argument)
        default:
            return (false, "unknown step")
        }
    }

    /// A turn is over when its tool calls have finished and the agent has replied after the last
    /// of them (it often speaks once with the call, then again with the result), or nothing more
    /// comes for 3 s. So a check sees the agent's answer to the result, not its first words.
    private func settleTurn() async {
        _ = await waitUntil(15) { self.tools.since(self.lastTurnStartedAt).allSatisfy { $0.finishedAt != nil } }
        guard let lastFinished = tools.since(lastTurnStartedAt).compactMap(\.finishedAt).max() else {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return
        }
        _ = await waitUntil(8) { self.replies.contains { $0.0 > lastFinished } }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func turnSummary(repliesBefore: Int, connected: Bool) -> String {
        let calls = tools.since(lastTurnStartedAt)
        let firstCall = calls.first.map { call in
            String(format: "%@ after %.2f s (%@)", call.name, call.startedAt.timeIntervalSince(lastTurnStartedAt),
                   call.ok == nil ? "still running" : (call.ok == true ? "ok" : "failed: \(call.error ?? "")"))
        }
        let firstReply = replies.dropFirst(repliesBefore).first
        let replyTime = firstReply.map { String(format: "%.2f s", $0.0.timeIntervalSince(lastTurnStartedAt)) } ?? "none"
        return "connected: \(connected); first tool call: \(firstCall ?? "none"); reply after \(replyTime): \"\(firstReply?.1 ?? "")\""
    }

    private func waitForTask(seconds: Double) async -> (Bool, String) {
        let ended = await waitUntil(seconds) { self.taskEnded != nil || !self.questions.isEmpty }
        guard ended, let start = taskStartedAt else {
            return (false, questions.isEmpty ? "no task ended within \(Int(seconds)) s" : "the task asked: \"\(questions[0].1)\" (the script does not answer)")
        }
        guard let (endedAt, status, summary) = taskEnded else { return (false, "the task asked: \"\(questions[0].1)\"") }
        // The result is said after the task ends.
        _ = await waitUntil(15) { self.replies.contains { $0.0 > endedAt } }
        let duringTask = replies.filter { $0.0 > start.addingTimeInterval(2) && $0.0 < endedAt }
        let result = replies.first { $0.0 > endedAt }
        let progress = progressAt.filter { $0 >= start && $0 <= endedAt }.count
        let modelTurns = thinkingAt.filter { $0 >= start && $0 <= endedAt }.count
        let detail = String(format: "status %@ after %.1f s; %d progress lines, %d model turns; %d agent replies during the task (progress is context only, so 0 expected); result said: \"%@\"; summary: \"%@\"",
                            status.rawValue, endedAt.timeIntervalSince(start), progress, modelTurns, duringTask.count, result?.1 ?? "none", summary)
        return (status == .done && duringTask.isEmpty && result != nil, detail)
    }

    /// Cleanup, as a person would: Command-W, then the save sheet's "Delete" button. The app's own
    /// hands do it directly (this is the test harness, not the agent), after recording what the
    /// safety gate would say about that click if the agent tried it. Quits the app again if it
    /// was not running before the script.
    private func closeWithoutSaving(appName: String) async -> (Bool, String) {
        var notes: [String] = []
        var front = await labels.frontmost()
        guard front.app.localizedCaseInsensitiveContains(appName) else { return (false, "\(appName) is not in front (\(front.app)); not pressing anything") }
        do { try await hands.key("cmd+w") } catch { return (false, "Command-W failed: \(error)") }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let controls = await labels.visibleControls(limit: 120)
        if let button = controls.first(where: { $0.role == .button && ["delete", "don\u{2019}t save", "don't save"].contains($0.label.lowercased()) }) {
            let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
            let action = await labels.clickAction(at: center)
            let verdict = await safetyGate.check(action)
            notes.append("safety gate on \(action.description): \(verdict.label) (\(verdict.source))")
            do { try await hands.click(at: center, button: .left, count: 1, modifiers: []) } catch {
                return (false, notes.joined(separator: "; ") + "; click failed: \(error)")
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        } else {
            notes.append("no save sheet (nothing to discard)")
        }
        if !textEditWasRunning, appName.localizedCaseInsensitiveContains("TextEdit") {
            front = await labels.frontmost()
            if front.app.localizedCaseInsensitiveContains("TextEdit") {
                try? await hands.key("cmd+q")
                notes.append("quit TextEdit (it was not running before)")
            }
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.TextEdit" }
        notes.append("TextEdit running now: \(stillRunning), before: \(textEditWasRunning)")
        return (stillRunning == textEditWasRunning, notes.joined(separator: "; "))
    }

    // MARK: Reading the screen (read only)

    /// True while the Mac shows its lock screen. Read only, from the window server's session.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// The text of the front document of `appName`: the first text area's value, read through the
    /// accessibility API. Nothing is clicked or changed.
    static func documentText(appName: String) -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        return firstTextAreaValue(window as! AXUIElement, depth: 0)
    }

    private static func firstTextAreaValue(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == (kAXTextAreaRole as String) {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            return value as? String
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let found = firstTextAreaValue(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func waitUntil(_ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}
