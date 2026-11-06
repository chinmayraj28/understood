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
import os

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
#if canImport(HFWake)
import HFWake
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
        #if canImport(HFWake)
        linked.append("HFWake")
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
    /// While no conversation is open it is always false, so nothing is held.
    static func makeVoice(settings: HFCore.Settings, bus: ActivityBus) -> (voice: any VoiceConnecting, isUserSpeaking: @Sendable () -> Bool)? {
        #if canImport(HFVoice)
        let session = VoiceSession(settings: settings, mode: .voice, bus: bus)
        // The always-open cycle is used in wake mode "always" and when HFWake is not linked;
        // the agent is then told there is no wake phrase and no go_to_sleep.
        session.keepsConversationOpen = settings.wakeMode == .always || !linkedPackages.contains("HFWake")
        // With HFWake's cycle, a failed wake is announced once, by the cycle.
        session.announcesFailedOpens = session.keepsConversationOpen
        return (session, { [weak session] in session?.isUserSpeaking ?? false })
        #else
        return nil
        #endif
    }

    /// The tool the agent calls when the user ends the conversation ("that's all, thanks").
    /// It refuses while a task is running or waiting for an answer.
    static func makeSleepTool(isTaskActive: @escaping @Sendable () -> Bool, requestSleep: @escaping @Sendable () async -> SleepAnswer) -> ToolSpec? {
        #if canImport(HFVoice)
        return SleepTool.make(isTaskActive: isTaskActive, requestSleep: {
            switch await requestSleep() {
            case .goingToSleep: return .goingToSleep
            case .afterTask: return .afterTask
            case .busy: return .busy
            case .notAvailable: return .notAvailable
            }
        })
        #else
        return nil
        #endif
    }

    // MARK: - HFWake

    /// The listening cycle for wake-phrase mode: asleep at launch, wakes on the phrase,
    /// sleeps after `sleepAfterIdleSeconds` with nothing going on.
    /// Whether the wake listener needs the Speech Recognition permission on this Mac, asked of the
    /// listener itself. On macOS 26 it uses Apple's SpeechAnalyzer, which needs only the
    /// Microphone; only the older recogniser it falls back to elsewhere needs Speech Recognition.
    /// Checked on 6 Nov: false on this Mac (macOS 26.3.1, SpeechTranscriber available, en_IN).
    static func wakeListenerNeedsSpeechRecognition() -> Bool {
        #if canImport(HFWake)
        return WakePermissions.needsSpeechRecognition
        #else
        return false
        #endif
    }

    /// `onListenerEvent` is told what the wake listener does, as counts-only events (never what was said).
    static func makeListeningCycle(
        settings: HFCore.Settings, hooks: CycleHooks, bus: ActivityBus,
        onListenerEvent: @escaping @Sendable (WakeListenerEvent) -> Void
    ) -> (any ListeningCycling)? {
        #if canImport(HFWake)
        return WakeCycleAdapter(settings: settings, hooks: hooks, bus: bus, onListenerEvent: onListenerEvent)
        #else
        return nil
        #endif
    }
}

#if canImport(HFVoice)
/// VoiceSession as the app's VoiceConnecting.
extension VoiceSession: VoiceConnecting {
    func prepareConversations(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) {
        prepare(tools: tools, memorySummary: memorySummary, onUserSentence: onUserSentence)
    }

    func openConversation(firstUtterance: String, memorySummary: String?) async {
        await open(firstUtterance: firstUtterance, memorySummary: memorySummary)
    }

    func closeConversation() async { await close() }

    var isConversationConnected: Bool { isConnected }

    var agentStatus: AgentStatus? {
        guard let check = agentCheck else { return nil }
        return AgentStatus(
            inSync: check.inSync, toolCount: check.toolCount, expectedToolCount: preparedToolCount, checkedAt: check.checkedAt,
            problem: check.problem, missing: check.missing, unexpected: check.unexpected)
    }
    // `openRefusal` is VoiceSession's own property, with the same meaning.

    var conversationActivity: VoiceActivity {
        let now = activity
        return VoiceActivity(
            isOpen: now.isOpen, isUserSpeaking: now.isUserSpeaking, isAgentSpeaking: now.isAgentSpeaking,
            hasUnspokenNews: now.hasUnspokenNews, lastActivityAt: now.lastActivityAt)
    }
}
#endif

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

#if canImport(HFWake)
/// HFWake's listening cycle as the app's ListeningCycling, with its on-device wake listener.
@MainActor
final class WakeCycleAdapter: ListeningCycling {
    nonisolated static let logger = Logger(subsystem: "com.handsfree", category: "wake")
    private let cycle: ListeningCycle
    private let listener: WakeListener
    private let mirror = ActivityMirror()
    private let hooks: CycleHooks

    init(settings: HFCore.Settings, hooks: CycleHooks, bus: ActivityBus, onListenerEvent: @escaping @Sendable (WakeListenerEvent) -> Void) {
        self.hooks = hooks
        let mirror = self.mirror
        // Recognition stays on the Mac. Permissions are asked for by the setup flow, not here,
        // so a restart in the background never pops up a dialog.
        // HFWake reads WAKE_PHRASE, WAKE_LANGUAGE (empty: the Mac's own), WAKE_ALTERNATIVES and WAKE_STRICTNESS
        // itself, so there is one place that interprets them.
        let listener = WakeListener(configuration: WakeListener.Configuration(settings: settings))
        // Counts only: `heardAs`, `restOfSentence` and transcripts are dropped here and never
        // stored, logged or shown (revealTranscripts stays off).
        listener.onDiagnostic = { diagnostic in
            if let event = WakeCycleAdapter.event(for: diagnostic) { onListenerEvent(event) }
        }
        self.listener = listener
        cycle = ListeningCycle(
            settings: settings,
            listener: listener,
            openConversation: { firstUtterance in try await hooks.open(firstUtterance) },
            closeConversation: { await hooks.close() },
            currentActivity: {
                let now = mirror.current
                return HFWake.ConversationActivity(
                    someoneSpeaking: now.someoneSpeaking, taskRunning: now.taskRunning, awaitingAnswer: now.awaitingAnswer)
            },
            bus: bus,
            // The cycle posts each problem itself as `.voiceDisconnected` (once per distinct problem), which the
            // companion and panel show; posting it here too would show it twice. This only logs it.
            onProblem: { problem in WakeCycleAdapter.logger.notice("Listening cycle problem: \(problem.spokenMessage, privacy: .public)") })
    }

    func start() async {
        mirror.startRefreshing(from: hooks.snapshot)
        await cycle.start()
    }

    func stop() async {
        await cycle.stop()
        mirror.stopRefreshing()
    }

    /// Waits for the cycle's answer, so the agent says "Okay" only when it really goes to sleep.
    func requestSleep() async -> SleepAnswer {
        switch await cycle.requestSleep() {
        case .goingToSleep: return .goingToSleep
        case .busy: return .busy
        case .notAwake, .alwaysOn: return .notAvailable
        }
    }


    /// A task question, confirmation or result must be said while asleep: wake as if the phrase had
    /// been heard. HFWake does nothing if it is already waking or awake, and wakes straight after
    /// a close that is in progress.
    func wakeWithoutPhrase() {
        let cycle = self.cycle
        Task { await cycle.wakeNow() }
    }


    func currentState() async -> String { await cycle.state.rawValue }
    var isListenerRunning: Bool { listener.isListening }

    /// HFWake's diagnostics as the app's word-free events.
    nonisolated static func event(for diagnostic: WakeDiagnostic) -> WakeListenerEvent? {
        switch diagnostic {
        case .started(let recognizer): return .started(recognizer: recognizer)
        case .phraseHeard: return .phraseHeard
        case .woke: return .woke
        case .restarting: return .restarting
        case .restartFailed(let problem, _): return .cannotListen(reason: problem.spokenMessage)
        case .speechWithoutPhrase: return .speechWithoutPhrase
        // `.transcript` is only sent when revealTranscripts is on, which the app never does.
        default: return nil
        }
    }
}
#endif
