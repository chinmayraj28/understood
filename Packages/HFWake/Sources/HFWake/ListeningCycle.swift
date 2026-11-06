import Foundation
import HFCore

/// What is going on in the open conversation, as far as sleeping is concerned.
public struct ConversationActivity: Sendable, Equatable {
    /// The user or the agent is speaking right now.
    public var someoneSpeaking: Bool
    /// A task is running.
    public var taskRunning: Bool
    /// A task is waiting for the user's answer or their yes. The pointer may be over Send.
    public var awaitingAnswer: Bool

    public init(someoneSpeaking: Bool = false, taskRunning: Bool = false, awaitingAnswer: Bool = false) {
        self.someoneSpeaking = someoneSpeaking
        self.taskRunning = taskRunning
        self.awaitingAnswer = awaitingAnswer
    }

    public static let idle = ConversationActivity()

    var anything: Bool { someoneSpeaking || taskRunning || awaitingAnswer }
    /// Work that must never be cut off by going to sleep.
    var taskInProgress: Bool { taskRunning || awaitingAnswer }
}

/// The rule for when the app is asleep and when a conversation is open.
///
/// ```
///   start ──▶ asleep ── phrase heard ──▶ waking ── conversation opened ──▶ awake
///               ▲  (listener on)            │ (listener off)                  │
///               │                           │ opening failed                  │ idle long enough,
///               └───────────────────────────┘                                 │ or "that's all"
///               └──────────────────── falling asleep (conversation closed) ◀──┘
/// ```
///
/// - **Asleep:** the wake listener runs and `.asleep(wakePhrase:)` is on the activity bus.
/// - **Waking:** `.waking` is posted, the listener is stopped so the conversation can have the
///   microphone, and the conversation is opened with the rest of the sentence as the user's first words.
/// - **Awake:** stays awake while anyone speaks, while a task runs or waits for an answer, and for
///   `sleepAfterIdleSeconds` after the last of these. A task waiting for a yes is never put to sleep.
/// - **Falling asleep:** the conversation is closed, then the listener starts again.
/// - If opening the conversation fails, it goes back to sleep and keeps listening. If the listener
///   cannot start, `onProblem` gets a sentence to show and speak, and it retries at a steady pace.
/// - In `WakeMode.always` none of this happens: the conversation is opened and kept open.
///
/// Everything it depends on is passed in, so it is tested with a fake clock and no audio.
public actor ListeningCycle {
    public enum State: String, Sendable {
        case stopped
        case asleep
        /// The phrase was heard, or (always mode) the conversation is being opened.
        case waking
        case awake
        case fallingAsleep
        /// The wake listener could not start. Retrying.
        case cannotListen
    }

    /// The answer to "that's all, thanks".
    public enum SleepRequestOutcome: String, Sendable {
        /// The conversation will close once the agent has finished speaking.
        case goingToSleep
        /// A task is running or waiting for an answer, so it stays awake. Cancel the task first.
        case busy
        /// It is not awake.
        case notAwake
        /// Wake mode is "always": the conversation stays open.
        case alwaysOn
    }

    /// How often things are checked and retried. The defaults suit the app; tests shorten them.
    public struct Pace: Sendable {
        /// How often an open conversation is checked for idleness.
        public var idleCheckSeconds: Double = 1
        /// How often the sleeping listener is checked to still be running.
        public var healthCheckSeconds: Double = 5
        /// Waits between attempts to start the listener (or, in always mode, open the conversation).
        /// The last value repeats.
        public var retrySeconds: [Double] = [2, 5, 10, 30, 60]
        /// After "that's all", time for the agent to start its goodbye before waiting for it to end.
        public var goodbyeGraceSeconds: Double = 1.5
        /// The longest a goodbye is waited for.
        public var goodbyeLongestSeconds: Double = 15
        public init() {}
    }

    public let mode: WakeMode
    public let wakePhrase: String
    public let sleepAfterIdleSeconds: Double
    public private(set) var state: State = .stopped
    /// The latest thing that went wrong, until it is put right.
    public private(set) var problem: SpeakableError?

    private let listener: WakeListening
    private let openConversation: @Sendable (_ firstUtterance: String) async throws -> Void
    private let closeConversation: @Sendable () async -> Void
    private let currentActivity: @Sendable () -> ConversationActivity
    private let now: @Sendable () -> Double
    private let sleep: @Sendable (_ seconds: Double) async throws -> Void
    private let bus: ActivityBus
    private let onProblem: @Sendable (SpeakableError) -> Void
    private let pace: Pace

    /// Bumped on every start and stop, so work from an earlier run stops itself.
    private var epoch = 0
    private var lastActivityAt: Double = 0
    private var retryIndex = 0
    private var loops: [Task<Void, Never>] = []
    private var busWatcher: Task<Void, Never>?
    /// wakeNow() was called while the conversation was closing.
    private var wakeWhenClosed = false

    /// - Parameters:
    ///   - listener: the wake listener (in the app, `WakeListener`).
    ///   - openConversation: opens the ElevenLabs conversation and sends `firstUtterance` as the
    ///     user's first message when it is not empty. Throws when it cannot.
    ///   - closeConversation: closes it. Must be safe to call when it is already closed.
    ///   - currentActivity: what is going on right now (speaking, a task, a question waiting).
    ///   - now: seconds on a steady clock.
    ///   - sleep: waits that many seconds; throws when cancelled.
    ///   - bus: where `.asleep` and `.waking` are posted, and where activity is watched for.
    ///   - onProblem: a sentence for the app to show and say when something is wrong.
    public init(
        mode: WakeMode,
        wakePhrase: String,
        sleepAfterIdleSeconds: Double,
        listener: WakeListening,
        openConversation: @escaping @Sendable (_ firstUtterance: String) async throws -> Void,
        closeConversation: @escaping @Sendable () async -> Void,
        currentActivity: @escaping @Sendable () -> ConversationActivity,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        bus: ActivityBus = .shared,
        onProblem: @escaping @Sendable (SpeakableError) -> Void = { _ in },
        pace: Pace = Pace()
    ) {
        self.mode = mode
        self.wakePhrase = wakePhrase
        self.sleepAfterIdleSeconds = sleepAfterIdleSeconds
        self.listener = listener
        self.openConversation = openConversation
        self.closeConversation = closeConversation
        self.currentActivity = currentActivity
        self.now = now
        self.sleep = sleep
        self.bus = bus
        self.onProblem = onProblem
        self.pace = pace
    }

    // MARK: Public controls

    /// Starts the cycle: asleep and listening, or (always mode) with the conversation open.
    public func start() async {
        guard state == .stopped else { return }
        epoch += 1
        let epoch = self.epoch
        watchBus(epoch: epoch)
        switch mode {
        case .always:
            state = .waking
            loops.append(Task { await self.keepConversationOpen(epoch: epoch) })
        case .phrase:
            await enterSleep(epoch: epoch)
        }
    }

    /// Stops everything: the listener, and the conversation if one is open. For quitting.
    public func stop() async {
        guard state != .stopped else { return }
        epoch += 1
        let previous = state
        state = .stopped
        wakeWhenClosed = false
        cancelLoops()
        busWatcher?.cancel()
        busWatcher = nil
        await listener.stop()
        if previous == .awake || previous == .waking || previous == .fallingAsleep {
            await closeConversation()
        }
    }

    /// "That's all, thanks." Closes the conversation once the agent has said goodbye, unless a
    /// task is running or waiting for an answer.
    public func requestSleep() async -> SleepRequestOutcome {
        if mode == .always { return .alwaysOn }
        guard state == .awake else { return .notAwake }
        if currentActivity().taskInProgress { return .busy }
        let epoch = self.epoch
        loops.append(Task { await self.sleepAfterGoodbye(epoch: epoch) })
        return .goingToSleep
    }

    /// Something happened in the conversation that the bus does not show. Restarts the idle wait.
    public func noteActivity() {
        if state == .awake { lastActivityAt = now() }
    }

    /// What `wakeNow()` did.
    public enum WakeNowOutcome: String, Sendable {
        /// It was asleep (or could not listen): it is waking now.
        case waking
        /// A conversation is already open or opening. Nothing was done.
        case alreadyAwake
        /// It was closing the conversation: it will wake as soon as the close has finished.
        case afterFallingAsleep
        /// The cycle is stopped.
        case notRunning
    }

    /// Wakes as if the phrase had been heard, with nothing said yet: posts `.waking`, stops the
    /// listener and opens the conversation with an empty first utterance.
    ///
    /// For news that must be spoken while asleep, such as a task's question or result that
    /// arrived just as the app was going to sleep. Returns at once; the waking carries on in the
    /// background. Call it from anywhere with `Task { await cycle.wakeNow() }`. Calling it while
    /// awake does nothing; calling it while falling asleep lets the close finish and then wakes,
    /// so a sleep is never left half done.
    @discardableResult
    public func wakeNow() -> WakeNowOutcome {
        switch state {
        case .stopped:
            return .notRunning
        case .waking, .awake:
            return .alreadyAwake
        case .fallingAsleep:
            wakeWhenClosed = true
            return .afterFallingAsleep
        case .asleep, .cannotListen:
            let epoch = self.epoch
            // Claim the state now, so a second call (or the phrase) in the meantime does nothing.
            state = .waking
            Task { await self.wake(firstUtterance: "", epoch: epoch) }
            return .waking
        }
    }

    // MARK: Asleep

    private func enterSleep(epoch: Int) async {
        guard epoch == self.epoch else { return }
        state = .asleep
        do {
            try await listener.start(onWake: { [weak self] rest in
                Task { await self?.heard(restOfSentence: rest, epoch: epoch) }
            })
        } catch {
            guard epoch == self.epoch, state == .asleep else { return }
            state = .cannotListen
            report(WakeListener.speakable(error))
            let delay = nextRetryDelay()
            loops.append(Task {
                do { try await self.sleep(delay) } catch { return }
                await self.retryListening(epoch: epoch)
            })
            return
        }
        guard epoch == self.epoch, state == .asleep else {
            // Stopped, or woken, while the listener was starting.
            if epoch != self.epoch { await listener.stop() }
            return
        }
        retryIndex = 0
        clearProblem()
        bus.post(.asleep(wakePhrase: wakePhrase))
        loops.append(Task { await self.checkListenerHealth(epoch: epoch) })
    }

    private func retryListening(epoch: Int) async {
        guard epoch == self.epoch, state == .cannotListen else { return }
        await enterSleep(epoch: epoch)
    }

    /// The listener restarts itself after a hiccup. If it has stayed down for two checks in a
    /// row, start it again from here, which also reports why it cannot listen.
    private func checkListenerHealth(epoch: Int) async {
        var downChecks = 0
        while true {
            do { try await sleep(pace.healthCheckSeconds) } catch { return }
            guard epoch == self.epoch, state == .asleep else { return }
            downChecks = listener.isListening ? 0 : downChecks + 1
            if downChecks >= 2 {
                await listener.stop()
                guard epoch == self.epoch, state == .asleep else { return }
                await enterSleep(epoch: epoch)
                return
            }
        }
    }

    // MARK: Waking

    private func heard(restOfSentence: String, epoch: Int) async {
        guard epoch == self.epoch, state == .asleep else { return }
        state = .waking
        await wake(firstUtterance: restOfSentence, epoch: epoch)
    }

    /// The one way to wake, for the phrase and for `wakeNow()`. The caller has set `.waking`.
    private func wake(firstUtterance restOfSentence: String, epoch: Int) async {
        guard epoch == self.epoch, state == .waking else { return }
        wakeWhenClosed = false
        cancelLoops()
        bus.post(.waking)
        // Release the microphone before the conversation opens it with voice processing.
        await listener.stop()
        // Stopped meanwhile: don't open a paid conversation only to close it.
        guard epoch == self.epoch, state == .waking else { return }
        do {
            try await openConversation(restOfSentence)
        } catch {
            report(error as? SpeakableError
                ?? SpeakableError("I heard you, but I couldn't start a conversation. Say the wake phrase to try again."))
            guard epoch == self.epoch, state == .waking else { return }
            await enterSleep(epoch: epoch)
            return
        }
        guard epoch == self.epoch, state == .waking else {
            // Stopped while the conversation was opening: do not leave it open.
            await closeConversation()
            return
        }
        clearProblem()
        state = .awake
        lastActivityAt = now()
        loops.append(Task { await self.watchForIdle(epoch: epoch) })
    }

    // MARK: Awake

    private func watchForIdle(epoch: Int) async {
        while true {
            do { try await sleep(pace.idleCheckSeconds) } catch { return }
            guard epoch == self.epoch, state == .awake else { return }
            if currentActivity().anything {
                lastActivityAt = now()
                continue
            }
            if now() - lastActivityAt >= sleepAfterIdleSeconds {
                beginFallingAsleep(epoch: epoch)
                return
            }
        }
    }

    private func sleepAfterGoodbye(epoch: Int) async {
        do { try await sleep(pace.goodbyeGraceSeconds) } catch { return }
        var waited = pace.goodbyeGraceSeconds
        while currentActivity().someoneSpeaking && waited < pace.goodbyeLongestSeconds {
            do { try await sleep(0.5) } catch { return }
            waited += 0.5
        }
        guard epoch == self.epoch, state == .awake else { return }
        // The user started something after all: stay awake.
        if currentActivity().taskInProgress { return }
        beginFallingAsleep(epoch: epoch)
    }

    /// Closing runs in a task of its own, not inside the loop that decided to sleep, because
    /// falling asleep cancels those loops and the close must not be cancelled with them.
    private func beginFallingAsleep(epoch: Int) {
        Task { await self.fallAsleep(epoch: epoch) }
    }

    private func fallAsleep(epoch: Int) async {
        guard epoch == self.epoch, state == .awake else { return }
        // The last word: a task that started since the decision to sleep keeps the app awake.
        if currentActivity().taskInProgress {
            lastActivityAt = now()
            cancelLoops()
            loops.append(Task { await self.watchForIdle(epoch: epoch) })
            return
        }
        state = .fallingAsleep
        cancelLoops()
        await closeConversation()
        guard epoch == self.epoch, state == .fallingAsleep else { return }
        if wakeWhenClosed {
            // wakeNow() was called while closing: the close is done, so wake at once.
            state = .waking
            await wake(firstUtterance: "", epoch: epoch)
            return
        }
        await enterSleep(epoch: epoch)
    }

    // MARK: Always mode

    private func keepConversationOpen(epoch: Int) async {
        while epoch == self.epoch {
            do {
                try await openConversation("")
                guard epoch == self.epoch else {
                    await closeConversation()
                    return
                }
                clearProblem()
                state = .awake
                return
            } catch {
                guard epoch == self.epoch else { return }
                report(SpeakableError("I couldn't start a conversation. I'll keep trying."))
                do { try await sleep(nextRetryDelay()) } catch { return }
            }
        }
    }

    // MARK: Activity on the bus

    private func watchBus(epoch: Int) {
        busWatcher?.cancel()
        let events = bus.events()
        busWatcher = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.observe(event, epoch: epoch)
            }
        }
    }

    private func observe(_ event: ActivityEvent, epoch: Int) {
        guard epoch == self.epoch, state == .awake, Self.countsAsActivity(event) else { return }
        lastActivityAt = now()
    }

    /// Anything the user, the agent or a task does. Not the cycle's own events, and not
    /// `.listening`, which is posted when the conversation is merely open and waiting.
    static func countsAsActivity(_ event: ActivityEvent) -> Bool {
        switch event {
        case .asleep, .waking, .listening, .voiceDisconnected: return false
        case .userSpeaking, .userSaid, .agentSpeaking, .thinking, .pointerMoving, .clicked, .typing, .scrolled,
            .taskStarted, .progress, .waitingForAnswer, .taskEnded, .heldForConfirmation, .halted:
            return true
        }
    }

    // MARK: Helpers

    private func nextRetryDelay() -> Double {
        let delays = pace.retrySeconds.isEmpty ? [5] : pace.retrySeconds
        let delay = delays[min(retryIndex, delays.count - 1)]
        retryIndex += 1
        return delay
    }

    private func cancelLoops() {
        for loop in loops { loop.cancel() }
        loops = []
    }

    /// Reports a problem once, not again every retry while it is the same problem: to `onProblem`
    /// (for the app to say it) and to the bus as `.voiceDisconnected(reason:)` (for the companion
    /// and the panel to show it). Every problem means the app is, at least for now, neither awake
    /// nor listening; `.asleep` follows once the listener really runs again.
    private func report(_ error: SpeakableError) {
        guard problem != error else { return }
        problem = error
        bus.post(.voiceDisconnected(reason: error.spokenMessage))
        onProblem(error)
    }

    private func clearProblem() { problem = nil }
}

extension ListeningCycle {
    /// The cycle with the wake settings from `Settings`: `wakeMode`, `wakePhrase` and
    /// `sleepAfterIdleSeconds`.
    public init(
        settings: Settings,
        listener: WakeListening,
        openConversation: @escaping @Sendable (_ firstUtterance: String) async throws -> Void,
        closeConversation: @escaping @Sendable () async -> Void,
        currentActivity: @escaping @Sendable () -> ConversationActivity,
        bus: ActivityBus = .shared,
        onProblem: @escaping @Sendable (SpeakableError) -> Void = { _ in }
    ) {
        self.init(
            mode: settings.wakeMode, wakePhrase: settings.wakePhrase,
            sleepAfterIdleSeconds: settings.sleepAfterIdleSeconds, listener: listener,
            openConversation: openConversation, closeConversation: closeConversation,
            currentActivity: currentActivity, bus: bus, onProblem: onProblem)
    }
}
