//
//  Parts.swift
//  Handsfree
//
//  The app's view of the parts that HFCore has no protocol for: the voice
//  session, the task runner and the stop watcher. The composition root talks to
//  these small interfaces, so it is the same code whether a part is the real
//  package or the app's stand-in. Each real package is wrapped by a short
//  adapter in Integration/Wire+<Package>.swift. New for Handsfree.
//

import Foundation
import HFCore

/// The live voice conversation (HFVoice's VoiceSession).
@MainActor
protocol VoiceConnecting: AnyObject {
    /// Starts the always-on conversation with these tools. Never throws: a
    /// problem shows on the companion as `.voiceDisconnected`.
    /// `onUserSentence` is called for every finished sentence the user says.
    func start(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) async
    /// Makes the agent say a task's question, confirmation or result while the user is silent.
    /// Callable from any thread, so the task runner's sink calls it directly and events keep their order.
    nonisolated func push(_ event: TaskEvent)
    func stop() async
}

/// The task runner (HFTasks's TaskRunner plus TaskTools). Named "Part" so it
/// does not clash with HFTasks's own `TaskRunning` protocol.
protocol TaskRunnerPart: AnyObject, Sendable {
    /// start_task, answer_task, cancel_task, task_status.
    var tools: [ToolSpec] { get }
    /// Stops the current task at once; the hands are halted first.
    func cancel()
    /// True while a task is running or paused waiting for the user.
    var isRunning: Bool { get }
    /// True while a task has asked something and is waiting for the reply.
    var isAwaitingAnswer: Bool { get }
    /// The running task's id, so a late "stop" can never cancel a newer task.
    var currentTaskID: String? { get }
    /// Cancels any task and waits briefly for it to let go of the hands. Called on quit.
    func shutdown()
}

/// The stop watcher (HFDecisions's StopWatcher).
protocol StopWatching: AnyObject, Sendable {
    /// Every sentence the user says. Never blocks.
    func hear(_ sentence: String)
}

/// Whether one part is the real package or the app's stand-in, for the panel and docs/APP.md.
struct PartWiring: Identifiable, Equatable {
    let part: String
    let package: String
    let isReal: Bool
    let note: String
    var id: String { part }
}

/// One of each part, connected. Built once by `PartAssembly.assemble`.
struct AssembledParts {
    let hands: any Hands
    let eyes: any Eyes
    let labels: any Labels
    let classifiers: any UtteranceClassifying & RiskClassifying & AnswerClassifying
    let safetyGate: any SafetyGating
    let memory: any MemoryProviding
    let executor: any TaskExecuting
    let taskRunner: any TaskRunnerPart
    let stopWatcher: any StopWatching
    let voice: any VoiceConnecting
    /// Every package's voice tools, registered with the voice session.
    let tools: [ToolSpec]
    let wiring: [PartWiring]
    /// Run when the app quits: release the hands, stop the runner, and undo
    /// anything a package switched on in other apps.
    let quitHooks: [@Sendable () -> Void]
    /// Run once at launch, off the main thread (each may take a second or more).
    let launchHooks: [@Sendable () async -> Void]
}
