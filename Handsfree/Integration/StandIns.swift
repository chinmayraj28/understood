//
//  StandIns.swift
//  Handsfree
//
//  Small stand-ins the app uses for a package that has not landed or does not
//  compile yet, so the app always builds and runs. Each one is honest about
//  being a stand-in: it does nothing on the user's Mac, fails with a sentence
//  that can be read aloud, and never says yes to a risky action. New for Handsfree.
//

import AppKit
import CoreGraphics
import Foundation
import HFCore

// MARK: - Hands, eyes, labels

/// Does not move the pointer or press keys. Every action fails with a spoken reason.
final class StandInHands: Hands, @unchecked Sendable {
    private let lock = NSLock()
    private var haltFlag = false

    func halt() { lock.lock(); haltFlag = true; lock.unlock() }
    func resume() { lock.lock(); haltFlag = false; lock.unlock() }
    var isHalted: Bool { lock.lock(); defer { lock.unlock() }; return haltFlag }

    /// Where the real pointer is, in HFCore's top-left screen points.
    var pointerPosition: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func notInstalled() -> SpeakableError { SpeakableError("I can't use the pointer or keyboard yet.") }
    func move(to point: CGPoint, duration: TimeInterval?) async throws { throw notInstalled() }
    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws { throw notInstalled() }
    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws { throw notInstalled() }
    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws { throw notInstalled() }
    func key(_ combo: String) async throws { throw notInstalled() }
    func typeText(_ text: String, allowReturn: Bool) async throws { throw notInstalled() }
}

/// Takes no screenshots.
final class StandInEyes: Eyes, @unchecked Sendable {
    let screenSize: CGSize
    init() { screenSize = CGDisplayBounds(CGMainDisplayID()).size }
    func grab(maxLongEdge: Int) async throws -> Shot { throw SpeakableError("I can't see the screen yet.") }
    func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot { throw SpeakableError("I can't see the screen yet.") }
}

/// Names nothing, and says so plainly rather than guessing.
final class StandInLabels: Labels, @unchecked Sendable {
    func element(at point: CGPoint) async -> UIElementInfo? { nil }
    func focusedElement() async -> UIElementInfo? { nil }
    func frontmost() async -> (app: String, window: String) { ("", "") }
    func describeClick(at point: CGPoint) async -> String { "an unlabelled control" }
    func describeFocus() async -> String { "an unlabelled control" }
    func visibleControls(limit: Int) async -> [UIElementInfo] { [] }
}

// MARK: - Decisions

/// Word-list decisions only. Risk is always "ask", and only a plain yes is a yes.
final class StandInClassifiers: UtteranceClassifying, RiskClassifying, AnswerClassifying, @unchecked Sendable {
    static let cancelPhrases: Set<String> = ["stop", "stop it", "stop that", "stop stop", "wait", "hang on", "cancel", "cancel that", "no stop", "don't"]
    static let yesPhrases: Set<String> = ["yes", "yeah", "yep", "yes please", "go ahead", "do it", "send it", "yes send it", "confirm"]
    static let noPhrases: Set<String> = ["no", "nope", "don't", "do not", "cancel", "no thanks", "stop"]

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
    }

    func classifyUtterance(_ text: String, context: UtteranceContext) async -> Decision<Intent> {
        let phrase = Self.normalized(text)
        if context.awaitingAnswer && Self.noPhrases.contains(phrase) && phrase != "stop" {
            return Decision(label: .other, confidence: 0.6, source: .keywords, reason: "an answer while a question is open")
        }
        let isCancel = Self.cancelPhrases.contains(phrase)
        return Decision(label: isCancel ? .cancel : .other, confidence: isCancel ? 0.9 : 0.5, source: .keywords)
    }

    func classifyRisk(_ action: ScreenAction) async -> Decision<Risk> {
        Decision(label: .needsConfirmation, confidence: 1, source: .rule, reason: "stand-in: always asks")
    }

    func classifyAnswer(_ answer: String, question: String) async -> Decision<Answer> {
        let phrase = Self.normalized(answer)
        if Self.yesPhrases.contains(phrase) { return Decision(label: .yes, confidence: 0.9, source: .keywords) }
        if Self.noPhrases.contains(phrase) { return Decision(label: .no, confidence: 0.9, source: .keywords) }
        return Decision(label: .unclear, confidence: 0.5, source: .keywords)
    }
}

/// Asks about everything. Never fails open.
final class StandInSafetyGate: SafetyGating, @unchecked Sendable {
    func check(_ action: ScreenAction) async -> Decision<Risk> {
        Decision(label: .needsConfirmation, confidence: 1, source: .rule, reason: "stand-in: always asks")
    }
}

/// Calls `onCancel` when a sentence is on the stop word list.
final class StandInStopWatcher: StopWatching, @unchecked Sendable {
    private let classifier = StandInClassifiers()
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    func hear(_ sentence: String) {
        Task {
            let decision = await classifier.classifyUtterance(sentence, context: UtteranceContext(taskRunning: true))
            if decision.label == .cancel { onCancel() }
        }
    }
}

// MARK: - Memory, executor, tasks

/// Remembers nothing.
final class StandInMemory: MemoryProviding, @unchecked Sendable {
    func hints(forGoal goal: String) async -> String { "" }
    func summaryForPrompt(maxCharacters: Int) async -> String { "" }
    func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async {}
    func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async {}
}

/// Cannot carry out goals.
final class StandInExecutor: TaskExecuting, @unchecked Sendable {
    func run(goal: String, context: TaskContext) async throws -> String {
        throw SpeakableError("I can't do tasks on the screen yet.")
    }
}

/// Offers the task tools, each of which says tasks are not available yet.
final class StandInTaskRunner: TaskRunnerPart, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    func cancel() { onCancel() }
    var isRunning: Bool { false }
    var isAwaitingAnswer: Bool { false }
    var currentTaskID: String? { nil }
    func shutdown() {}

    var tools: [ToolSpec] {
        let unavailable: ToolSpec.Handler = { _ in ToolResult.failure("I can't do multi-step tasks yet.") }
        return [
            ToolSpec(
                name: "start_task",
                description: "Starts a multi-step goal on the screen. Not available in this build.",
                parameters: ["type": "object", "properties": ["goal": ["type": "string"]], "required": ["goal"]],
                tier: .task, handler: unavailable),
            ToolSpec(
                name: "cancel_task", description: "Stops the current task.",
                parameters: ["type": "object", "properties": [:]], tier: .task,
                handler: { [weak self] _ in self?.cancel(); return ToolResult.ok() }),
        ]
    }
}

// MARK: - Voice

/// No conversation. Says so on the companion, so nobody waits for an answer that will not come.
@MainActor
final class StandInVoice: VoiceConnecting {
    private let bus: ActivityBus
    init(bus: ActivityBus) { self.bus = bus }

    func prepareConversations(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) {}
    func openConversation(firstUtterance: String, memorySummary: String?) async {
        bus.post(.voiceDisconnected(reason: "The voice package is not installed in this build yet."))
    }
    func closeConversation() async {}
    var isConversationConnected: Bool { false }
    var agentStatus: AgentStatus? { nil }
    var openRefusal: String? { nil }
    func waitUntilConnected(timeout: TimeInterval) async -> Bool { false }
    nonisolated func push(_ event: TaskEvent) {}
    var conversationActivity: VoiceActivity { .closed }
    var onNewsWhileClosed: (@MainActor () -> Void)?
    func stop() async {}
}
