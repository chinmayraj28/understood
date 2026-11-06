//
//  RealParts.swift
//  Handsfree
//
//  The real packages, one function each. A function returns nil when its
//  package is not linked into this build (see Handsfree/LinkedPackages.txt and
//  scripts/build_app.sh), and PartAssembly then uses the stand-in.
//
//  Each body sits behind `#if canImport(<Package>)`, so code for a package
//  that is not linked is never compiled. The adapters are written against each
//  package's public API as it stood on 5 Nov 2026 (evening).
//

import Foundation
import HFCore

#if canImport(HFHands)
import HFHands
#endif
#if canImport(HFEyes)
import HFEyes
#endif
#if canImport(HFDecisions)
import HFDecisions
#endif
#if canImport(HFMemory)
import HFMemory
#endif
#if canImport(HFTasks)
import HFTasks
#endif
#if canImport(HFScreenAgent)
import HFScreenAgent
#endif
#if canImport(HFVoice)
import HFVoice
#endif

@MainActor
enum RealParts {

    /// Why a part is still a stand-in, for the panel and the integration checklist.
    static func missingNote(_ package: String) -> String {
        if linkedPackages.contains(package) {
            return "\(package) is linked, but its adapter in RealParts.swift is not written yet."
        }
        return "\(package) is not linked into this build yet."
    }

    /// The optional packages linked into this build.
    static var linkedPackages: [String] {
        var linked: [String] = []
        #if canImport(HFHands)
        linked.append("HFHands")
        #endif
        #if canImport(HFEyes)
        linked.append("HFEyes")
        #endif
        #if canImport(HFDecisions)
        linked.append("HFDecisions")
        #endif
        #if canImport(HFMemory)
        linked.append("HFMemory")
        #endif
        #if canImport(HFTasks)
        linked.append("HFTasks")
        #endif
        #if canImport(HFScreenAgent)
        linked.append("HFScreenAgent")
        #endif
        #if canImport(HFVoice)
        linked.append("HFVoice")
        #endif
        return linked
    }

    // MARK: - HFHands

    /// The hands, and a hook that lets go of any mouse button or modifier key left
    /// held (run at launch and at quit, so a crash can never leave Command stuck
    /// down for a user who cannot press a key to clear it).
    static func makeHands(settings: HFCore.Settings) -> (hands: any Hands, releaseEverything: @Sendable () -> Void)? {
        #if canImport(HFHands)
        // SystemHands posts .pointerMoving, .clicked, .typing and .scrolled itself.
        let hands = SystemHands(activity: .shared)
        return (hands, { hands.releaseEverything() })
        #else
        return nil
        #endif
    }

    /// The quick tools, guarded: before any quick action that could commit (Return,
    /// a click, Command+Delete...), the guard names what is really focused or under
    /// the point and asks the safety gate. Anything but "safe" is refused, and the
    /// voice agent does it as a task instead, where confirmations are asked.
    static func makeQuickTools(hands: any Hands, labels: any Labels, safetyGate: any SafetyGating) -> [ToolSpec]? {
        #if canImport(HFHands)
        return QuickTools.make(hands: hands, guard: GateQuickActionGuard(labels: labels, safetyGate: safetyGate))
        #else
        return nil
        #endif
    }

    // MARK: - HFEyes

    /// Also returns two hooks for web content: Chrome and Electron apps only expose
    /// their pages to accessibility when asked. `enableWebContent` asks them (at
    /// launch), and the switch outlives us, so `restoreWebContentSwitches` puts
    /// it back (at quit). Both can take over a second per app that does not answer,
    /// so they are never run on the main thread.
    static func makeEyesAndLabels(settings: HFCore.Settings) -> (
        eyes: any Eyes, labels: any Labels, enableWebContent: @Sendable () async -> Void, restoreWebContent: @Sendable () -> Void
    )? {
        #if canImport(HFEyes)
        // ScreenEyes leaves every window of this process (the overlay, the panel) out of its screenshots,
        // and the labels look through our windows to the app beneath.
        let eyes = ScreenEyes()
        let labels = AccessibilityLabels(source: SystemAccessibilitySource())
        return (eyes, labels, { _ = await labels.enableWebContent() }, { _ = labels.restoreWebContentSwitches() })
        #else
        return nil
        #endif
    }

    // MARK: - HFDecisions

    static func makeDecisions(settings: HFCore.Settings) -> (
        classifiers: any UtteranceClassifying & RiskClassifying & AnswerClassifying, safetyGate: any SafetyGating
    )? {
        #if canImport(HFDecisions)
        // Without an OpenRouter key, Classifiers uses its word-list fallbacks.
        let classifiers = Classifiers(settings: settings)
        return (classifiers, SafetyGate(classifier: classifiers))
        #else
        return nil
        #endif
    }

    static func makeStopWatcher(
        classifiers: any UtteranceClassifying & RiskClassifying & AnswerClassifying,
        runner: any TaskRunnerPart
    ) -> (any StopWatching)? {
        #if canImport(HFDecisions)
        let watcher = StopWatcher(
            classifier: classifiers,
            isTaskRunning: { runner.isRunning },
            isAwaitingAnswer: { runner.isAwaitingAnswer },
            currentTaskID: { runner.currentTaskID },
            cancel: { runner.cancel() })
        return StopWatcherAdapter(watcher: watcher)
        #else
        return nil
        #endif
    }

    // MARK: - HFScreenAgent

    /// The Claude client, shared by the screen agent and by memory's learning.
    static func makeLanguageModel(settings: HFCore.Settings) -> (any StructuredLanguageModel)? {
        #if canImport(HFScreenAgent)
        guard !settings.anthropicAPIKey.isEmpty else { return nil }
        return ClaudeClient(settings: settings)
        #else
        return nil
        #endif
    }

    /// `holdWhile`: true while the user is speaking. The agent takes no new action
    /// then, so a "stop" or a correction lands before the pointer moves again.
    static func makeScreenAgent(
        settings: HFCore.Settings, hands: any Hands, eyes: any Eyes, labels: any Labels,
        languageModel: (any StructuredLanguageModel)?, holdWhile: @escaping @Sendable () -> Bool
    ) -> (any TaskExecuting)? {
        #if canImport(HFScreenAgent)
        guard let client = languageModel as? ClaudeClient else { return nil }
        return ScreenAgent(
            hands: hands, eyes: eyes, labels: labels, client: client,
            configuration: ScreenAgentConfiguration(settings: settings), holdWhile: holdWhile)
        #else
        return nil
        #endif
    }

    // MARK: - HFMemory

    static func makeMemory(settings: HFCore.Settings, languageModel: (any StructuredLanguageModel)?) -> (memory: any MemoryProviding, tools: [ToolSpec])? {
        #if canImport(HFMemory)
        do {
            let memory = try Memory.openDefault(settings: settings, model: languageModel)
            return (memory, MemoryTools.make(memory: memory))
        } catch {
            // A broken memory database must never stop the app: fall back to the stand-in.
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - HFTasks

    static func makeTaskRunner(
        settings: HFCore.Settings, executor: any TaskExecuting, safetyGate: any SafetyGating,
        answers: any AnswerClassifying, memory: any MemoryProviding, hands: any Hands,
        onEvent: @escaping @Sendable (TaskEvent) -> Void, bus: ActivityBus
    ) -> (any TaskRunnerPart)? {
        #if canImport(HFTasks)
        let runner = TaskRunner(
            executor: executor,
            gate: safetyGate,
            answerClassifier: answers,
            memory: memory,
            sink: onEvent,
            configuration: TaskRunner.Configuration(settings: settings),
            // "Stop" freezes the pointer and keyboard first, before anything else happens.
            onCancel: { hands.halt() },
            // The hands are released only when no executor is alive any more.
            onTaskEnd: { _, _ in hands.resume() },
            activityBus: bus)
        return TaskRunnerAdapter(runner: runner)
        #else
        return nil
        #endif
    }

    // MARK: - HFVoice

    /// The voice session, and a thread-safe "is the user speaking right now" for the
    /// screen agent's hold. The closure captures the concrete VoiceSession, because
    /// `isUserSpeaking` is nonisolated there and must be read without hopping to the main actor.
    static func makeVoice(settings: HFCore.Settings, bus: ActivityBus) -> (voice: any VoiceConnecting, isUserSpeaking: @Sendable () -> Bool)? {
        #if canImport(HFVoice)
        let session = VoiceSession(settings: settings, mode: .voice, bus: bus)
        return (session, { [weak session] in session?.isUserSpeaking ?? false })
        #else
        return nil
        #endif
    }
}

#if canImport(HFDecisions)
/// HFDecisions's StopWatcher as the app's StopWatching.
final class StopWatcherAdapter: StopWatching, @unchecked Sendable {
    let watcher: StopWatcher
    init(watcher: StopWatcher) { self.watcher = watcher }
    func hear(_ sentence: String) { watcher.heard(sentence) }
}
#endif

#if canImport(HFTasks)
/// HFTasks's TaskRunner and TaskTools as the app's TaskRunnerPart.
final class TaskRunnerAdapter: TaskRunnerPart, @unchecked Sendable {
    let runner: TaskRunner
    let tools: [ToolSpec]

    init(runner: TaskRunner) {
        self.runner = runner
        self.tools = TaskTools.make(runner: runner)
    }

    func cancel() { _ = runner.cancel(taskID: nil) }
    var isRunning: Bool { runner.isRunning }
    var isAwaitingAnswer: Bool { runner.isAwaitingAnswer }
    var currentTaskID: String? { runner.status()["task_id"]?.stringValue }
    func shutdown() { runner.shutdown() }
}
#endif

#if canImport(HFVoice)
/// VoiceSession already has exactly the app's interface.
extension VoiceSession: VoiceConnecting {}
#endif

#if canImport(HFHands)
/// The quick tools' guard: names what an action would land on, from what is really
/// focused or under the point right now, and asks the safety gate. Only "safe" goes ahead.
final class GateQuickActionGuard: QuickActionGuarding, @unchecked Sendable {
    private let labels: any Labels
    private let safetyGate: any SafetyGating

    init(labels: any Labels, safetyGate: any SafetyGating) {
        self.labels = labels
        self.safetyGate = safetyGate
    }

    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict {
        let target: UIElementInfo?
        if let point { target = await labels.element(at: point) } else { target = await labels.focusedElement() }
        let front = await labels.frontmost()
        let bundleIdentifier = await labels.frontmostBundleIdentifier()
        let action = ScreenAction(
            kind: kind, key: key, target: target,
            frontApp: front.app, frontWindow: front.window, frontAppBundleIdentifier: bundleIdentifier)
        let decision = await safetyGate.check(action)
        return decision.label == .safe ? .allow : .refuse()
    }
}
#endif
