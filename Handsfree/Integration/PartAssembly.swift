//
//  PartAssembly.swift
//  Handsfree
//
//  Creates one of each part and connects them: the hands, eyes and labels; the
//  classifiers, safety gate and stop watcher; memory; the voice session; the
//  task runner with the screen agent as its executor and `hands.halt` as its
//  cancel hook; and the list of every package's voice tools. For each package it
//  uses the real one when the package is linked (RealParts.swift), and the
//  stand-in otherwise. New for Handsfree.
//
//  The order follows the dependencies:
//  hands -> eyes and labels -> classifiers and gate -> quick tools (guarded by
//  labels and gate) -> Claude client -> memory -> voice -> screen agent (held
//  while the user speaks) -> task runner (speaks through the voice) -> stop
//  watcher (cancels the runner).
//
//  Only the task runner ever releases the hands (`hands.resume` through its
//  task-ended hook). Nothing else in the app calls `resume`: resuming before a
//  halted action has unwound would let it carry on.
//

import Foundation
import HFCore

@MainActor
enum PartAssembly {

    /// - Parameter scriptAgentID: test-only (`--script`): the voice is a text conversation on this agent.
    static func assemble(settings: HFCore.Settings, bus: ActivityBus, scriptAgentID: String? = nil) -> AssembledParts {
        var wiring: [PartWiring] = []
        var launchHooks: [@Sendable () async -> Void] = []
        var quitHooks: [@Sendable () -> Void] = []
        func record(_ part: String, _ package: String, real: Bool, _ note: String) {
            wiring.append(PartWiring(part: part, package: package, isReal: real, note: note))
        }

        // Hands.
        let hands: any Hands
        let handsAreReal: Bool
        if let real = RealParts.makeHands(settings: settings) {
            hands = real.hands
            handsAreReal = true
            launchHooks.append { real.releaseEverything() }
            quitHooks.append(real.releaseEverything)
        } else {
            hands = StandInHands()
            handsAreReal = false
        }

        // Eyes and labels.
        let eyes: any Eyes
        let labels: any Labels
        if let real = RealParts.makeEyesAndLabels(settings: settings) {
            eyes = real.eyes
            labels = real.labels
            launchHooks.append(real.enableWebContent)
            quitHooks.append(real.restoreWebContent)
            record("Eyes and labels", "HFEyes", real: true, "ScreenEyes (leaves our own windows out), AccessibilityLabels; web content switched on at launch, restored at quit")
        } else {
            eyes = StandInEyes()
            labels = StandInLabels()
            record("Eyes and labels", "HFEyes", real: false, RealParts.missingNote("HFEyes"))
        }

        // Decisions: one Classifiers shared by the gate, the runner and the stop watcher.
        let classifiers: any UtteranceClassifying & RiskClassifying & AnswerClassifying
        let safetyGate: any SafetyGating
        if let real = RealParts.makeDecisions(settings: settings) {
            classifiers = real.classifiers
            safetyGate = real.safetyGate
            record("Classifiers and safety gate", "HFDecisions", real: true,
                   settings.isJevEnabled ? "Classifiers (Jev with word-list fallback), SafetyGate" : "word lists only (no OpenRouter key), SafetyGate")
        } else {
            classifiers = StandInClassifiers()
            safetyGate = StandInSafetyGate()
            record("Classifiers and safety gate", "HFDecisions", real: false, RealParts.missingNote("HFDecisions") + " The stand-in gate asks about every action.")
        }

        // Quick tools, guarded by the labels and the gate.
        let quickTools = RealParts.makeQuickTools(hands: hands, labels: labels, safetyGate: safetyGate) ?? []
        if handsAreReal {
            record("Hands and quick tools", "HFHands", real: true, "SystemHands; QuickTools (\(quickTools.count) tools, guarded by labels and the safety gate); release-everything at launch and quit")
        } else {
            record("Hands and quick tools", "HFHands", real: false, RealParts.missingNote("HFHands"))
        }

        // The Claude client, shared by the screen agent and memory's learning.
        let languageModel = RealParts.makeLanguageModel(settings: settings)

        // Memory.
        let memory: any MemoryProviding
        let memoryTools: [ToolSpec]
        if let real = RealParts.makeMemory(settings: settings, languageModel: languageModel) {
            memory = real.memory
            memoryTools = real.tools
            record("Memory", "HFMemory", real: true,
                   "Memory at \(settings.dataDirectory.path)/memory.db; MemoryTools (\(real.tools.count) tools)" + (languageModel == nil ? "; learning by rules only (no Claude client)" : ""))
        } else {
            memory = StandInMemory()
            memoryTools = []
            record("Memory", "HFMemory", real: false, RealParts.linkedPackages.contains("HFMemory")
                   ? "HFMemory is linked but its database could not be opened." : RealParts.missingNote("HFMemory"))
        }

        // The voice session. Created before the screen agent, which holds still while the user speaks.
        let voice: any VoiceConnecting
        let isUserSpeaking: @Sendable () -> Bool
        if let real = RealParts.makeVoice(settings: settings, bus: bus, scriptAgentID: scriptAgentID) {
            voice = real.voice
            isUserSpeaking = real.isUserSpeaking
            record("Voice session", "HFVoice", real: true, settings.wakeMode == .always
                   ? "VoiceSession (ElevenLabs), kept open (WAKE_MODE=always)"
                   : "VoiceSession (ElevenLabs), opened on the wake phrase, closed after \(Int(settings.sleepAfterIdleSeconds)) s of quiet")
        } else {
            voice = StandInVoice(bus: bus)
            isUserSpeaking = { false }
            record("Voice session", "HFVoice", real: false, RealParts.missingNote("HFVoice"))
        }

        // The screen agent, as the runner's executor.
        let executor: any TaskExecuting
        if let real = RealParts.makeScreenAgent(
            settings: settings, hands: hands, eyes: eyes, labels: labels, languageModel: languageModel, holdWhile: isUserSpeaking)
        {
            // A locked screen stops a task before its first look and at every step (ScreenLock.swift).
            executor = LockAwareExecutor(inner: real, isLocked: ScreenLock.isLockedNow)
            record("Screen agent", "HFScreenAgent", real: true, "ScreenAgent with ClaudeClient (\(settings.taskModel)); holds while the user speaks")
        } else {
            executor = StandInExecutor()
            record("Screen agent", "HFScreenAgent", real: false, RealParts.linkedPackages.contains("HFScreenAgent")
                   ? "HFScreenAgent is linked but ANTHROPIC_API_KEY is missing." : RealParts.missingNote("HFScreenAgent"))
        }

        // The task runner: the screen agent does the work, `hands.halt` is the brake.
        // Its events go straight to `voice.push`, which is thread-safe and keeps their order.
        let speakTaskEvent: @Sendable (TaskEvent) -> Void = { [voice] event in voice.push(event) }
        let taskRunner: any TaskRunnerPart
        if let real = RealParts.makeTaskRunner(
            settings: settings, executor: executor, safetyGate: safetyGate, answers: classifiers,
            memory: memory, hands: hands, onEvent: speakTaskEvent, bus: bus)
        {
            taskRunner = real
            record("Task runner", "HFTasks", real: true, "TaskRunner, TaskTools; cancel halts the hands first, task end resumes them")
        } else {
            taskRunner = StandInTaskRunner(onCancel: { [hands] in hands.halt() })
            record("Task runner", "HFTasks", real: false, RealParts.missingNote("HFTasks"))
        }
        // On quit: the runner shuts down first (its cancel halts the hands), then the hands are
        // halted and released, then the web-content switches are restored.
        quitHooks.insert({ [taskRunner] in taskRunner.shutdown() }, at: 0)
        quitHooks.insert({ [hands] in hands.halt() }, at: 1)

        // The stop watcher hears every sentence and cancels the runner on "stop".
        let stopWatcher: any StopWatching
        if let real = RealParts.makeStopWatcher(classifiers: classifiers, runner: taskRunner) {
            stopWatcher = real
            record("Stop watcher", "HFDecisions", real: true, "StopWatcher with the runner's task id, cancelling the runner")
        } else {
            stopWatcher = StandInStopWatcher(onCancel: { [taskRunner] in taskRunner.cancel() })
            record("Stop watcher", "HFDecisions", real: false, RealParts.missingNote("HFDecisions") + " The stand-in stops on a short word list.")
        }

        // "That's all, thanks": the agent asks the listening cycle to sleep. Refused while a
        // task is running or waiting for an answer, so a task can never be left unheard.
        // Only offered when something can go to sleep: wake-phrase mode with HFWake linked.
        // In wake mode "always" the agent would say "Okay." and keep listening.
        let sleepRequests = SleepRequestRelay()
        let canSleep = settings.wakeMode == .phrase && RealParts.linkedPackages.contains("HFWake")
        let sleepTools = !canSleep ? [] : RealParts.makeSleepTool(
            isTaskActive: { [taskRunner] in CycleWiring.isTaskActive(taskRunner) },
            requestSleep: { [sleepRequests] in await sleepRequests.request() }).map { [$0] } ?? []

        return AssembledParts(
            hands: hands, eyes: eyes, labels: labels, classifiers: classifiers, safetyGate: safetyGate,
            memory: memory, executor: executor, taskRunner: taskRunner, stopWatcher: stopWatcher, voice: voice,
            // While the Mac is locked, quick tools and start_task do nothing and say so (ScreenLock.swift).
            // While a task runs or waits for an answer, it owns the hands (TaskOwnsHands.swift).
            tools: ScreenLock.guarding(
                TaskOwnsHands.guarding(quickTools, isTaskActive: { [taskRunner] in CycleWiring.isTaskActive(taskRunner) })
                    + memoryTools + taskRunner.tools + sleepTools, isLocked: ScreenLock.isLockedNow),
            sleepRequests: sleepRequests,
            wiring: wiring,
            quitHooks: quitHooks,
            launchHooks: launchHooks)
    }
}
