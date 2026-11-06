//
//  CycleWiring.swift
//  Handsfree
//
//  How the listening cycle (asleep, waking, awake) is connected to the rest of
//  the app. The cycle itself lives in HFWake and takes its dependencies as
//  closures; this file builds those closures from the voice session, the task
//  runner and memory, so the rule "is anything going on" is written once and
//  unit tested. It also holds the app's own always-open cycle, used for wake
//  mode "always" and whenever HFWake is not linked. New for Handsfree.
//

import Foundation
import HFCore

/// "Is anything going on", in the three parts HFWake's cycle asks about.
struct CycleSnapshot: Equatable, Sendable {
    /// The user or the agent is speaking, the agent is working out a reply or running a tool,
    /// or a task's news has not been said yet. (HFWake waits for this to end before a goodbye closes.)
    var someoneSpeaking: Bool
    /// A task is running. A task keeps the app awake for its whole length, which is what makes
    /// a spoken "stop" always work: there is always a conversation open to hear it.
    var taskRunning: Bool
    /// A task is waiting for the user's answer or their yes.
    var awaitingAnswer: Bool

    static let idle = CycleSnapshot(someoneSpeaking: false, taskRunning: false, awaitingAnswer: false)

    var isBusy: Bool { someoneSpeaking || taskRunning || awaitingAnswer }
}

/// The closures the listening cycle is given.
struct CycleHooks {
    /// Opens a conversation, saying the rest of the wake sentence as the first turn.
    /// Throws a `SpeakableError` if no conversation could be opened; nothing is left open then.
    let open: @MainActor (_ firstUtterance: String) async throws -> Void
    /// Opens a conversation and leaves the session reconnecting until it works (wake mode "always").
    let openAndKeepTrying: @MainActor () async -> Void
    /// Closes the conversation. Safe to call when it is already closed.
    let close: @MainActor () async -> Void
    /// What is going on right now.
    let snapshot: @MainActor () -> CycleSnapshot
    /// When something last happened in the conversation, on `ProcessInfo.systemUptime`.
    let lastActivityAt: @MainActor () -> TimeInterval
}

@MainActor
enum CycleWiring {
    /// How long a wake waits for the conversation to connect, including one automatic retry,
    /// before it gives up and goes back to sleep.
    static let connectPatienceSeconds: TimeInterval = 4

    static let couldNotConnect = SpeakableError("I heard you, but I couldn't reach the voice service. Say the wake phrase to try again.")

    /// "Is anything going on": a task is running or waiting for an answer, either side is
    /// speaking, or a task event has not been said yet. Any one keeps the conversation open.
    nonisolated static func snapshot(taskRunning: Bool, awaitingAnswer: Bool, conversation: VoiceActivity) -> CycleSnapshot {
        CycleSnapshot(
            someoneSpeaking: conversation.isUserSpeaking || conversation.isAgentSpeaking || conversation.hasUnspokenNews,
            taskRunning: taskRunning,
            awaitingAnswer: awaitingAnswer)
    }

    static func hooks(voice: any VoiceConnecting, runner: any TaskRunnerPart, memory: any MemoryProviding) -> CycleHooks {
        CycleHooks(
            open: { [weak voice] firstUtterance in
                guard let voice else { throw couldNotConnect }
                // Memory may have learned something since the last conversation.
                let summary = await memory.summaryForPrompt(maxCharacters: 1200)
                await voice.openConversation(firstUtterance: firstUtterance, memorySummary: summary)
                if voice.isConversationConnected { return }
                // The session retries by itself after a second; give it that one chance.
                if await voice.waitUntilConnected(timeout: connectPatienceSeconds) { return }
                // Nothing may keep reconnecting while the app is asleep.
                await voice.closeConversation()
                throw couldNotConnect
            },
            openAndKeepTrying: { [weak voice] in
                guard let voice else { return }
                let summary = await memory.summaryForPrompt(maxCharacters: 1200)
                await voice.openConversation(firstUtterance: "", memorySummary: summary)
            },
            close: { [weak voice] in await voice?.closeConversation() },
            snapshot: { [weak voice] in
                snapshot(taskRunning: runner.isRunning, awaitingAnswer: runner.isAwaitingAnswer,
                         conversation: voice?.conversationActivity ?? .closed)
            },
            lastActivityAt: { [weak voice] in voice?.conversationActivity.lastActivityAt ?? -.infinity })
    }

    /// A task's question, confirmation or result pushed while no conversation is open wakes the
    /// cycle, as if the phrase had been heard, so the user hears it (HFWake's `wakeNow()`).
    /// The event itself waits in the voice session's queue and is said once connected.
    static func wakeForNews(voice: any VoiceConnecting, cycle: any ListeningCycling) {
        voice.onNewsWhileClosed = { [weak cycle] in cycle?.wakeWithoutPhrase() }
    }

    /// The go_to_sleep tool must refuse while a task is running or waiting for an answer.
    nonisolated static func isTaskActive(_ runner: any TaskRunnerPart) -> Bool {
        runner.isRunning || runner.isAwaitingAnswer
    }
}

/// A copy of "what is going on" that any thread can read.
///
/// HFWake's cycle is an actor and asks from its own thread, synchronously; the voice session's
/// state lives on the main actor. So the main actor refreshes this copy five times a second, and
/// the cycle reads the copy. HFWake checks for idleness once a second, so 0.2 s is fresh enough.
final class ActivityMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = CycleSnapshot.idle
    private var refreshing: Task<Void, Never>?

    var current: CycleSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func store(_ snapshot: CycleSnapshot) {
        lock.lock(); latest = snapshot; lock.unlock()
    }

    @MainActor
    func startRefreshing(every seconds: TimeInterval = 0.2, from read: @escaping @MainActor () -> CycleSnapshot) {
        refreshing?.cancel()
        store(read())
        refreshing = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self else { return }
                self.store(read())
            }
        }
    }

    func stopRefreshing() {
        refreshing?.cancel()
        refreshing = nil
    }
}

/// Keeps one conversation open the whole time: the behaviour before wake phrases.
/// Used for wake mode "always" (demos and testing), and when HFWake is not linked, so the
/// app still works without it. Never sleeps; the go_to_sleep tool does nothing here.
/// The voice session reconnects by itself, so a failed first attempt is not retried here.
@MainActor
final class AlwaysOpenCycle: ListeningCycling {
    private let hooks: CycleHooks
    private(set) var isStarted = false

    init(hooks: CycleHooks) { self.hooks = hooks }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await hooks.openAndKeepTrying()
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        await hooks.close()
    }

    func requestSleep() {}
    func wakeWithoutPhrase() {}
    func currentState() async -> String { isStarted ? "always open" : "stopped" }
    var isListenerRunning: Bool { false }
}
