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

/// What the listening cycle needs to know about the conversation, read at one moment.
struct VoiceActivity: Equatable, Sendable {
    /// A conversation is open, or being opened or reconnected.
    var isOpen: Bool
    var isUserSpeaking: Bool
    /// Talking, working out a reply, or waiting for a tool.
    var isAgentSpeaking: Bool
    /// A task's question, confirmation or result has not been said yet.
    var hasUnspokenNews: Bool
    /// The last time anyone spoke or the agent did anything (`ProcessInfo.systemUptime`).
    var lastActivityAt: TimeInterval

    static let closed = VoiceActivity(isOpen: false, isUserSpeaking: false, isAgentSpeaking: false, hasUnspokenNews: false, lastActivityAt: -.infinity)
}

/// The agent on ElevenLabs, as last checked against the app's tools (HFVoice's AgentCheck).
struct AgentStatus: Equatable, Sendable {
    var inSync: Bool
    var toolCount: Int
    var expectedToolCount: Int
    var checkedAt: Date
    /// One plain sentence when out of step.
    var problem: String?
    var missing: [String]
    var unexpected: [String]
}

/// The voice conversation (HFVoice's VoiceSession). Prepared once, then opened on every
/// wake and closed on every sleep.
@MainActor
protocol VoiceConnecting: AnyObject {
    /// Once at launch: the tools, memory's summary, and the listener for every finished
    /// sentence the user says (the stop watcher). Opens nothing.
    func prepareConversations(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void)
    /// Opens a conversation and says `firstUtterance` (the rest of the wake sentence) as the
    /// user's first turn. Returns once connected or the first attempt failed. Never throws:
    /// a problem shows on the companion as `.voiceDisconnected`.
    func openConversation(firstUtterance: String, memorySummary: String?) async
    /// Ends the conversation, leaving no connection or microphone open.
    func closeConversation() async
    /// True once the open conversation can hear the user.
    var isConversationConnected: Bool { get }
    /// Whether the agent on ElevenLabs has exactly the app's tools, as last checked. Nil until checked.
    var agentStatus: AgentStatus? { get }
    /// Why the last open did not open a conversation (the agent is out of step), if it did not.
    var openRefusal: String? { get }
    /// Waits for the conversation to connect (it retries by itself), up to `timeout` seconds.
    func waitUntilConnected(timeout: TimeInterval) async -> Bool
    /// Makes the agent say a task's question, confirmation or result while the user is silent.
    /// Callable from any thread, so the task runner's sink calls it directly and events keep their order.
    nonisolated func push(_ event: TaskEvent)
    var conversationActivity: VoiceActivity { get }
    /// Called when a task event the user must hear arrives while no conversation is open.
    var onNewsWhileClosed: (@MainActor () -> Void)? { get set }
    func stop() async
}

/// Decides when the app is asleep and when a conversation is open (HFWake's listening
/// cycle, or the app's always-open one). Asleep at start in wake-phrase mode.
@MainActor
protocol ListeningCycling: AnyObject {
    func start() async
    /// On quit: stops listening and closes any conversation.
    func stop() async
    /// The user ended the conversation (the go_to_sleep tool): sleep as soon as nothing is going on.
    func requestSleep() async -> SleepAnswer
    /// Something must be said while asleep: open a conversation as if the phrase had been heard.
    func wakeWithoutPhrase()
    /// For the panel and app-status.json: asleep, waking, awake, falling asleep, cannot listen, stopped.
    func currentState() async -> String
    /// True while the wake listener has the microphone and is recognising.
    var isListenerRunning: Bool { get }
}

/// What the listening cycle did with "that's all, thanks". Returned to the go_to_sleep tool, so
/// the agent's words match what really happens.
enum SleepAnswer: Equatable, Sendable {
    /// The conversation closes once the agent has finished its short reply.
    case goingToSleep
    /// A task is running or waiting for an answer: it goes to sleep as soon as the task ends.
    case afterTask
    /// A task is running or waiting for an answer, so it stays awake.
    case busy
    /// It cannot sleep now: it is not awake, or it is set to stay open.
    case notAvailable
}

/// Lets the go_to_sleep tool, built with the other tools, reach the listening cycle,
/// which is created later. Thread-safe.
final class SleepRequestRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor () async -> SleepAnswer)?

    func setHandler(_ handler: @escaping @MainActor () async -> SleepAnswer) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    /// Asks the cycle and waits for its answer. Before the cycle exists, it cannot sleep.
    func request() async -> SleepAnswer {
        let handler = lock.withLock { self.handler }
        guard let handler else { return .notAvailable }
        return await handler()
    }
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
    /// The go_to_sleep tool's way to the listening cycle.
    let sleepRequests: SleepRequestRelay
    let wiring: [PartWiring]
    /// Run when the app quits: release the hands, stop the runner, and undo
    /// anything a package switched on in other apps.
    let quitHooks: [@Sendable () -> Void]
    /// Run once at launch, off the main thread (each may take a second or more).
    let launchHooks: [@Sendable () async -> Void]
}
