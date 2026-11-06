import Foundation
import HFCore
import os

/// The voice conversation with the ElevenLabs agent.
///
/// The app does not keep a conversation open all day. It sleeps, listening on the Mac for
/// the wake phrase, and opens a conversation only when it hears it (see HFCore's Wake.swift).
/// So one session object is opened and closed many times in one run of the app:
///
/// - `prepare(tools:memorySummary:onUserSentence:)` once at launch: registers the tools and
///   brings the agent's definition on ElevenLabs in step with them, in the background.
/// - `open(firstUtterance:)` on each wake: connects, then says the rest of the wake sentence
///   ("open Spotify") as the user's first turn.
/// - `close()` on each sleep: ends the conversation and leaves nothing running (no connection,
///   no microphone, no timers). Task events still waiting are kept, never dropped.
/// - `activity` tells the listening cycle whether anything is going on, and when it last was.
///
/// While open it also:
/// - answers the agent's tool calls with JSON text;
/// - hands every user sentence to the transcript listeners (the stop watcher is one) on its
///   own queue, before that turn's tool runs;
/// - speaks task events with `push(_:)`, waiting for a quiet moment first;
/// - reconnects on its own, with growing gaps, and never takes the app down;
/// - posts what it hears and says to the activity bus for the companion.
///
/// `start(tools:memorySummary:onUserSentence:)` and `stop()` are kept for the always-open
/// mode and for tools and tests: start is prepare then open, stop is close.
@MainActor
public final class VoiceSession {
    public enum Mode: Sendable {
        /// Microphone and speakers, over WebRTC.
        case voice
        /// Typed messages only, over a websocket. For automated tests and `hf-voice text`.
        case text
    }

    /// Timings that shape turn-taking. The defaults come from the spike's measurements.
    public struct Tuning: Sendable {
        /// Gaps between reconnection attempts, in seconds. The last one repeats.
        public var reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        /// The user counts as speaking for this long after the voice-activity score was high.
        public var userQuietAfter: TimeInterval = 0.8
        public var voiceActivityThreshold: Double = 0.5
        /// After the agent's reply text arrives, its audio starts about 0.1 s later. Stay
        /// busy a little longer so a push cannot slip into that gap.
        public var settleAfterReply: TimeInterval = 0.6
        /// After the user speaks, or after a tool answers, wait at most this long for the agent's
        /// reply before speaking a task event. The agent may relay an answer with answer_task and
        /// say nothing, so this must stay short. The spike measured replies within about 0.4 to 2.6 s.
        public var replyTimeout: TimeInterval = 4
        /// How often waiting task events are checked.
        public var pumpInterval: TimeInterval = 0.2
        /// If the SDK says the agent is speaking or thinking and then goes quiet for this long, the
        /// state is treated as stuck, so a lost "listening" update cannot keep the app awake for ever.
        /// Replies are one or two sentences; even a long one is far shorter than this.
        public var agentStuckAfter: TimeInterval = 60
        /// Task news older than this is not mentioned at the start of a new conversation.
        public var taskNewsShelfLife: TimeInterval = 1800
        /// The longest a wake waits for an update already on its way (the launch update, about 2.5 s).
        /// Real time: it bounds how long a person waits in silence.
        public var firstSyncPatience: TimeInterval = 2
        /// The longest a connected wake waits for the agent's read-back before carrying on (it is
        /// about 0.3 s and runs alongside connecting). A slow or failed read-back never refuses a wake.
        public var wakeCheckPatience: TimeInterval = 2
        /// The longest a wake waits for a repair of an agent confirmed wrong (about 2.5 s) before refusing.
        public var repairPatience: TimeInterval = 4
        /// After the connection drops, waiting news keeps the conversation open this long while it
        /// reconnects; after that it waits for the next conversation instead.
        public var undeliverableNewsGrace: TimeInterval = 30
        public var push = PushQueue.Timing()
        public init() {}
    }

    /// What the listening cycle needs to decide whether the conversation may close.
    public struct Activity: Sendable, Equatable {
        /// A conversation is open, or being opened or reconnected.
        public var isOpen: Bool
        /// The user is talking, or what they said has not reached the listeners yet.
        public var isUserSpeaking: Bool
        /// The agent is talking, working out a reply, or waiting for a tool.
        public var isAgentSpeaking: Bool
        /// A task's question, confirmation or result is waiting to be said, or has just been sent
        /// and the agent has not said it yet. Closing now could lose something the user needs.
        public var hasUnspokenNews: Bool
        /// The last time anyone spoke or the agent did anything, on the session's clock.
        /// The conversation counts as idle from here.
        public var lastActivityAt: TimeInterval

        /// True when the conversation must stay open whatever the idle time.
        public var isBusy: Bool { isUserSpeaking || isAgentSpeaking || hasUnspokenNews }
    }

    /// How long the last `open` took, for measurements and the log.
    public struct OpenTiming: Sendable, Equatable {
        /// Waiting for the agent's definition to finish updating (only the first wake after launch, if at all).
        public var waitedForAgentSync: TimeInterval
        /// From starting to connect until the conversation was ready to hear the user.
        public var connecting: TimeInterval
        /// From `open` being called until the conversation was ready.
        public var total: TimeInterval
    }

    // MARK: Configuration

    private let agentID: String
    private let mode: Mode
    private let bus: ActivityBus
    private let tuning: Tuning
    private let makeDriver: @MainActor () -> ConversationDriving
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// Brings the agent on ElevenLabs in step with the tools, and checks that it is. Nil in tests
    /// that do not care about the agent.
    private let keeper: AgentKeeper?
    /// Gets what the next connection needs (a token or signed URL) ahead of time, so a wake
    /// does not wait for it. Nil in tests.
    private let prepareNextConnection: (@Sendable (ConversationStart) async -> Void)?
    nonisolated private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    // MARK: State (main actor)

    private var router = ToolRouter(tools: [])
    private var tools: [ToolSpec] = []
    private var memorySummary = ""
    /// The listener given to `prepare` (the app's stop watcher). Replaced, never added twice.
    private var primaryListener: (@Sendable (String) -> Void)?
    private var transcriptListeners: [@Sendable (String) -> Void] = []
    private var replyListeners: [@Sendable (String) -> Void] = []
    private var driver: ConversationDriving?
    /// Bumped on every connect and every close, so signals from an old connection are ignored.
    private var generation = 0
    private var wantsToRun = false
    public private(set) var isConnected = false
    /// How often the user (or, if echo cancellation fails, the agent's own voice) cut in. For diagnostics.
    public private(set) var interruptionCount = 0
    /// The highest voice-activity score heard. Near zero all the time means the microphone is silent
    /// (macOS hands silent audio, not an error, to a process without Microphone permission).
    public private(set) var peakVoiceActivity = 0.0
    /// How many times a conversation has been opened. For diagnostics and tests.
    public private(set) var openCount = 0
    /// How many times the agent's definition has been sent to ElevenLabs. For tests.
    public private(set) var agentSyncCount = 0
    public private(set) var lastOpenTiming: OpenTiming?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    // Keeping the agent's definition in step: once per launch, again only if the tools change.
    private var syncedFingerprint: String?
    private var syncingFingerprint: String?
    private var syncTask: Task<AgentCheck, Never>?
    /// The latest check of the agent on ElevenLabs: in step or not, how many tools, when. Nil until checked.
    public private(set) var agentCheck: AgentCheck?
    /// The latest check that said something about the agent (in step, or a confirmed mismatch):
    /// a failed check ("could not check") never replaces it. Decisions are made on this one.
    public private(set) var confirmedCheck: AgentCheck?
    /// True once a check in this launch has confirmed the agent in step.
    private var hasConfirmedGoodCheck = false
    /// Every check is numbered when it starts; a result older than the newest recorded is ignored,
    /// so a slow update that fails late cannot overwrite a newer good check.
    private var checksStarted = 0
    private var newestRecordedCheck = 0
    /// With no good check yet, tool calls wait for the first read-back (at most `wakeCheckPatience`).
    private var toolGate: Task<Void, Never>?
    /// Why the last `open` did not open a conversation, if it did not. One sentence, fine to say.
    public private(set) var openRefusal: String?
    /// The read-back started with a wake; the first sentence waits for it.
    private var pendingVerification: Task<AgentCheck, Never>?
    private var repairTask: Task<Void, Never>?

    // This conversation.
    /// The rest of the wake sentence, said as the user's first turn as soon as the conversation is ready.
    private var pendingFirstUtterance: String?
    /// True when a restored first utterance was already given to the transcript listeners.
    private var firstUtteranceAlreadyHeard = false
    /// False until this conversation has connected once; a later connect is a reconnect.
    private var hasConnectedThisConversation = false
    private var openRequestedAt: TimeInterval = 0
    private var syncWaitSeconds: TimeInterval = 0
    private var connectStartedAt: TimeInterval = 0

    // Turn-taking.
    private var agentAudible = false
    private var lastAgentSignalAt: TimeInterval = -.infinity
    private var awaitingReplySince: TimeInterval?
    private var lastReplyAt: TimeInterval = -.infinity
    private var lastVoiceAt: TimeInterval = -.infinity
    private var lastActivityAt: TimeInterval = -.infinity
    private var toolCallsInFlight = 0
    /// Whether pushed questions, confirmations and results were really said, and whether the user
    /// heard a question before their answer is passed on (see SaidCheck).
    private var said = SaidCheck()
    /// The user's recent sentences with when they arrived: a confirmation is answered in their own words.
    private var userSentences: [(text: String, turn: Int)] = []
    /// Numbers every sentence either side says, in order (a clock can give two the same time).
    private var turnCounter = 0

    // What to tell the agent after a reconnect, or at the start of the next conversation.
    private var recentTurns: [String] = []
    private var lastTaskNote: String?
    private var lastTaskNoteAt: TimeInterval = -.infinity

    /// True in wake mode "always": the conversation is kept open, there is no wake phrase and no
    /// go_to_sleep. Each conversation is told so, because the prompt describes waking and sleeping.
    public var keepsConversationOpen = false

    /// Whether failed attempts to open a conversation are posted as `.voiceDisconnected`. True by
    /// default (and in wake mode "always"); the app sets it false when HFWake's cycle reports a failed
    /// wake itself. A drop after the conversation has connected is posted either way.
    public var announcesFailedOpens = true

    /// Called, on the main actor, when a question, confirmation or result is pushed while no
    /// conversation is open, so the app can wake to say it if its listening cycle can do that.
    /// Either way the event stays queued and is said in the next conversation.
    public var onNewsWhileClosed: (@MainActor () -> Void)?

    /// Task events wait here. `push` may be called from any thread, so it has its own lock.
    private let queueLock = NSLock()
    nonisolated(unsafe) private var queue: PushQueue

    /// Every use of the queue goes through here, so the lock is never held across an await.
    private nonisolated func withQueue<Result>(_ body: (inout PushQueue) -> Result) -> Result {
        queueLock.lock()
        defer { queueLock.unlock() }
        return body(&queue)
    }

    /// Whether the user is talking, from voice activity. Read from any thread.
    private let speechLock = NSLock()
    nonisolated(unsafe) private var speech = UserSpeechDetector()
    private nonisolated func withSpeech<Result>(_ body: (inout UserSpeechDetector) -> Result) -> Result {
        speechLock.lock()
        defer { speechLock.unlock() }
        return body(&speech)
    }

    /// For measurements: every voice-activity score, as it arrives.
    var voiceActivityObserver: (@Sendable (Double) -> Void)?

    /// Transcript listeners run here, in order, off the main actor.
    private let listenerQueue = DispatchQueue(label: "com.handsfree.voice.listeners", qos: .userInteractive)

    // MARK: Creating

    /// A session using `Settings` for the key, talking to the app's agent (ELEVENLABS_AGENT_ID),
    /// or, with `agentID`, to another agent such as the test agent (`TestAgent.resolve`).
    ///
    /// With `syncAgentOnStart`, the agent is brought in step with the app's prompt and tools when
    /// the session is prepared, read back to confirm it, and checked again on every wake.
    public convenience init(
        settings: Settings,
        agentID: String? = nil,
        mode: Mode = .voice,
        bus: ActivityBus = .shared,
        configuration: AgentConfiguration = AgentConfiguration(),
        syncAgentOnStart: Bool = true,
        tuning: Tuning = Tuning()
    ) {
        let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
        let target = agentID ?? settings.elevenLabsAgentID
        // The app's own agent never takes test tools; any other agent must not be the app's.
        let role: AgentSyncer.Role = target == settings.elevenLabsAgentID
            ? .production : .test(productionAgentID: settings.elevenLabsAgentID)
        let keeper = syncAgentOnStart && !target.isEmpty
            ? AgentKeeper(syncer: AgentSyncer(apiKey: settings.elevenLabsAPIKey, agentID: target, role: role, configuration: configuration))
            : nil
        let credentials = ConnectionCredentials(api: api)
        self.init(
            agentID: target, mode: mode, bus: bus, tuning: tuning,
            makeDriver: { ElevenLabsDriver(credentials: credentials) },
            clock: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
            syncAgent: nil,
            prepareNextConnection: { start in await credentials.prefetch(agentID: start.agentID, textOnly: start.textOnly) },
            agentKeeper: keeper)
    }

    /// The full initialiser, with the SDK, the clock and sleeping injectable. Tests in any package
    /// can pass their own `ConversationDriving` fake here, so nothing touches the network.
    ///
    /// - Parameters:
    ///   - syncAgent: the older, simpler form of `agentKeeper`: true when the update worked. A read-back
    ///     is then assumed to agree. Kept for tests written against it.
    ///   - agentKeeper: updates the agent and reads it back. Takes precedence over `syncAgent`.
    public init(
        agentID: String,
        mode: Mode,
        bus: ActivityBus,
        tuning: Tuning,
        makeDriver: @escaping @MainActor () -> ConversationDriving,
        clock: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        syncAgent: (@Sendable ([ToolSpec]) async -> Bool)?,
        prepareNextConnection: (@Sendable (ConversationStart) async -> Void)? = nil,
        agentKeeper: AgentKeeper? = nil
    ) {
        self.agentID = agentID
        self.mode = mode
        self.bus = bus
        self.tuning = tuning
        self.makeDriver = makeDriver
        self.clock = clock
        self.sleep = sleep
        self.keeper = agentKeeper ?? syncAgent.map(AgentKeeper.init(simple:))
        self.prepareNextConnection = prepareNextConnection
        self.queue = PushQueue(timing: tuning.push)
    }

    // MARK: Listeners

    /// Adds a listener that is told every finished user sentence. Listeners run in
    /// order on a background queue and must return quickly.
    public func addTranscriptListener(_ listener: @escaping @Sendable (String) -> Void) {
        transcriptListeners.append(listener)
    }

    /// Adds a listener for every reply the agent gives, as text.
    public func addReplyListener(_ listener: @escaping @Sendable (String) -> Void) {
        replyListeners.append(listener)
    }

    // MARK: Preparing, opening and closing

    /// Gets ready to open conversations: registers the tools, keeps the memory summary, and
    /// starts bringing the agent's definition on ElevenLabs in step with the tools, in the
    /// background. Call it once at launch. Calling it again with the same tools does not
    /// update the agent again; `onUserSentence` replaces the one given before.
    public func prepare(tools: [ToolSpec], memorySummary: String, onUserSentence: (@Sendable (String) -> Void)? = nil) {
        router = ToolRouter(tools: tools)
        self.tools = tools
        self.memorySummary = memorySummary
        if let onUserSentence { primaryListener = onUserSentence }
        startAgentSyncIfNeeded()
        prefetchConnection()
    }

    /// Opens a conversation. Returns once it is connected, or once the first attempt failed
    /// (it then keeps trying, and the failure is posted as `.voiceDisconnected`). Never throws.
    ///
    /// - Parameters:
    ///   - firstUtterance: what the user said after the wake phrase in the same breath, such as
    ///     "open Spotify". It is sent as the user's first turn the moment the conversation is
    ///     ready, so nothing is lost while connecting. Empty when they said only the phrase.
    ///   - memorySummary: a fresher summary than the one given to `prepare`, if there is one.
    public func open(firstUtterance: String = "", memorySummary: String? = nil) async {
        guard !wantsToRun else {
            // Already open: a second wake just passes on what was said.
            let text = firstUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if isConnected {
                    try? await sayAsUser(text)
                } else {
                    pendingFirstUtterance = [pendingFirstUtterance, text].compactMap { $0 }.joined(separator: " ")
                }
            }
            return
        }
        guard !agentID.isEmpty else {
            bus.post(.voiceDisconnected(reason: "The voice agent is not set up yet. Run hf-voice setup."))
            return
        }
        if let memorySummary { self.memorySummary = memorySummary }
        wantsToRun = true
        openCount += 1
        let thisOpen = openCount
        openRequestedAt = clock()
        disconnectedSince = nil
        lastActivityAt = openRequestedAt
        hasConnectedThisConversation = false
        reconnectAttempt = 0
        let text = firstUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFirstUtterance = text.isEmpty ? nil : text
        firstUtteranceAlreadyHeard = false
        // Nothing has been heard in this conversation yet; what was left unsaid gets a new chance.
        let again = said.newConversation(at: clock(), shelfLife: tuning.taskNewsShelfLife)
        if !again.isEmpty {
            let now = clock()
            withQueue { queue in for event in again where !queue.items.contains(where: { $0.event == event }) { queue.add(event, at: now) } }
        }

        openRefusal = nil

        // A conversation never opens with an agent confirmed wrong: on 6 Nov the user spoke to an
        // agent whose only tool was a test one, and it invented results. But a check that merely
        // failed (network, timeout, 5xx, 429) never stops a wake: see `agentReadyForConversation`.
        let ready = await agentReadyForConversation()
        syncWaitSeconds = clock() - openRequestedAt
        // Closed while waiting, or closed and opened again (that newer open connects instead).
        guard wantsToRun, thisOpen == openCount else { return }
        guard ready else {
            refuseOpen(AgentCheck.notSetUpSentence)
            return
        }
        // Anything else holding the key could have changed the agent since the last check. The
        // read-back (about 0.3 s) runs alongside connecting; the first sentence waits for it, at most
        // `wakeCheckPatience`. (If it finds the agent wrong while an update is on its way, the
        // repair is that update.)
        if keeper != nil {
            let verification = startCheck(push: false)
            pendingVerification = verification
            // With no good check yet in this launch, tools wait for it too (speech cannot be held).
            if !hasConfirmedGoodCheck {
                let patience = tuning.wakeCheckPatience
                toolGate = Task { _ = await Self.result(of: verification, atMost: patience) }
            }
        }
        startPump()
        await connect()
    }

    /// Whether a conversation may open. False only when the agent is confirmed wrong and a repair,
    /// tried now for at most `repairPatience`, has not fixed it. An update already on its way is
    /// waited for at most `firstSyncPatience`. A check that fails or is slow never refuses.
    private func agentReadyForConversation() async -> Bool {
        guard keeper != nil else { return true }
        startAgentSyncIfNeeded()
        if let syncTask { _ = await Self.result(of: syncTask, atMost: tuning.firstSyncPatience) }
        guard confirmedCheck?.isConfirmedMismatch == true else { return true }
        let repair = syncTask ?? startCheck(push: true)
        let repaired = await Self.result(of: repair, atMost: tuning.repairPatience)
        if repaired?.inSync == true || confirmedCheck?.isConfirmedMismatch == false { return true }
        Self.logger.error("Voice agent still out of step after a repair (\(repaired?.summary ?? "repair still running", privacy: .public))")
        return false
    }

    /// Starts a numbered check (an update with read-back, or a read-back alone) and records its
    /// result when it comes, unless a newer check has been recorded first.
    private func startCheck(push: Bool) -> Task<AgentCheck, Never> {
        checksStarted += 1
        let number = checksStarted
        let tools = self.tools
        guard let keeper else { return Task { AgentCheck.matching(tools) } }
        return Task { @MainActor [weak self] in
            let check = push ? await keeper.push(tools) : await keeper.verify(tools)
            self?.record(check, number: number, tools: tools)
            return check
        }
    }

    /// The task's result, or nil if it has not finished within `seconds`. The task keeps running.
    private static func result(of task: Task<AgentCheck, Never>, atMost seconds: TimeInterval) async -> AgentCheck? {
        let box = CheckBox()
        await wait(for: task, atMost: seconds, into: box)
        return box.value
    }

    /// No conversation can be opened. Says why once (unless the listening cycle will), and leaves
    /// nothing running. A repair keeps being tried in the background.
    private func refuseOpen(_ problem: String) {
        Self.logger.error("Not opening a conversation: \(problem, privacy: .public)")
        openRefusal = problem
        wantsToRun = false
        pumpTask?.cancel()
        pumpTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingVerification = nil
        pendingFirstUtterance = nil
        if announcesFailedOpens { bus.post(.voiceDisconnected(reason: problem)) }
    }

    /// Waits for the update to finish, or for `seconds`, whichever comes first. Real time on
    /// purpose: this is a bound on how long a person waits, not part of turn-taking.
    /// (Not a task group: a group waits for all its children, and the child waiting for the
    /// update cannot be cancelled, so the limit would never apply.)
    private static func wait(for task: Task<AgentCheck, Never>, atMost seconds: TimeInterval, into box: CheckBox? = nil) async {
        let resumed = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                let check = await task.value
                if resumed.claim() {
                    box?.set(check)
                    continuation.resume()
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if resumed.claim() { continuation.resume() }
            }
        }
    }

    /// Ends the conversation and stops reconnecting. Leaves no connection, no microphone and
    /// no timer running. Task events not yet said are kept, and said in the next conversation.
    public func close() async {
        let wasRunning = wantsToRun || driver != nil
        wantsToRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        generation += 1
        isConnected = false
        pendingFirstUtterance = nil
        hasConnectedThisConversation = false
        resetTurnState()
        agentAudible = false
        recentTurns = []
        toolGate = nil
        pendingVerification = nil
        withSpeech { $0.reset() }
        let ending = driver
        driver = nil
        await ending?.end()
        if wasRunning { prefetchConnection() }
    }

    /// Starts the conversation at once with these tools and this memory summary:
    /// `prepare` then `open`. For the always-open mode, tools and tests.
    public func start(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) async {
        prepare(tools: tools, memorySummary: memorySummary, onUserSentence: onUserSentence)
        await open()
    }

    /// Starts the conversation at once with these tools and this memory summary.
    public func start(tools: [ToolSpec], memorySummary: String) async {
        prepare(tools: tools, memorySummary: memorySummary)
        await open()
    }

    /// Ends the conversation. The same as `close()`.
    public func stop() async {
        await close()
    }

    /// True while a conversation is open, or being opened or reconnected.
    public var isOpen: Bool { wantsToRun }

    /// How many tools the app registered with `prepare`: what the agent should have.
    public var preparedToolCount: Int { tools.count }

    /// True if anything of a conversation is still around: a driver, the push pump or a
    /// pending reconnect. Must be false after `close()`. For tests.
    public var hasConversationResources: Bool { driver != nil || pumpTask != nil || reconnectTask != nil || isConnected }

    // MARK: Speaking task events

    /// Makes the agent say a task's question, confirmation or result; gives it progress silently.
    ///
    /// Safe to call from any thread. The event waits until the agent has finished
    /// speaking and the user is quiet, because a pushed message cuts the agent off.
    /// Progress is only added silently to the agent's context (never spoken, never queued).
    /// If no conversation is open, the event waits for the next one, and `onNewsWhileClosed`
    /// is called for anything the user must hear.
    public nonisolated func push(_ event: TaskEvent) {
        let now = clock()
        // Progress is never a user message: a user message always gets a spoken reply, and the
        // agent said "Nothing to add yet." after every task step (6 Nov evaluation). It goes only
        // into the agent's context, so "how is it going?" can be answered; the companion shows it
        // on screen. Questions, confirmations and results still go as user messages, to be said.
        if event.kind != .progress { withQueue { $0.add(event, at: now, fresh: true) } }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.said.noted(event)
            self.lastTaskNote = TaskEventSpeech.contextLine(for: event)
            self.lastTaskNoteAt = self.clock()
            if event.kind == .progress, self.isConnected, let driver = self.driver {
                try? await driver.sendContext(TaskEventSpeech.contextLine(for: event))
            }
            if !self.wantsToRun && event.kind != .progress {
                self.onNewsWhileClosed?()
            }
            await self.deliverIfReady()
        }
    }

    /// Sends a typed user message, as if the user had said it. For tests and `hf-voice text`.
    ///
    /// The server does not echo typed messages back as transcripts, so the
    /// transcript listeners are told here instead.
    public func sendText(_ text: String) async throws {
        guard isConnected, let driver else { throw SpeakableError("The voice connection is not ready.") }
        awaitingReplySince = clock()
        lastActivityAt = clock()
        remember("User: \(text)")
        try await driver.sendUserMessage(text)
        notifyTranscriptListeners(text)
    }

    /// A typed turn that goes exactly where a heard sentence goes: to the agent, to the transcript
    /// listeners (the stop watcher, sign-off detection) and to the companion as `.userSaid`. For the
    /// app's test-only `--script` runs; `sendText` stays as it was for the older tests.
    public func sendTypedTurn(_ text: String) async throws {
        guard isConnected else { throw SpeakableError("The voice connection is not ready.") }
        try await sayAsUser(text)
    }

    /// Waits until the conversation is connected, up to `timeout` seconds.
    public func waitUntilConnected(timeout: TimeInterval) async -> Bool {
        let deadline = clock() + timeout
        while !isConnected && clock() < deadline { await sleep(0.05) }
        return isConnected
    }

    // MARK: Signals for the listening cycle

    /// True from the moment the user starts speaking until the transcript of what they said
    /// has reached the transcript listeners (with a short tail between words). Safe to read
    /// from any thread. The screen agent holds before each new action while this is true.
    /// Always false while no conversation is open.
    public nonisolated var isUserSpeaking: Bool {
        let now = clock()
        return withSpeech { $0.isSpeaking(at: now) }
    }

    /// True when the agent is talking, working out a reply, or waiting for a tool.
    public var isAgentSpeaking: Bool { isAgentBusy(at: clock()) }

    /// True when a task event is waiting to be said, or was just sent and not yet said.
    public var hasUnspokenNews: Bool {
        let now = clock()
        // News that cannot be delivered (no conversation, or one that has not reconnected for a while)
        // does not keep the app awake: it waits for the next conversation, and is dropped once it is
        // half an hour old.
        let canDeliver = wantsToRun && (isConnected || now - (disconnectedSince ?? now) < tuning.undeliverableNewsGrace)
        guard canDeliver else { return false }
        if withQueue({ $0.freshCount(at: now) }) > 0 { return true }
        // A question, confirmation or result was sent and the agent has not answered yet.
        if said.attempt != nil { return true }
        if said.hasUnsaid(at: clock(), shelfLife: tuning.taskNewsShelfLife) { return true }
        if let since = awaitingReplySince, clock() - since < tuning.replyTimeout { return pushAwaitingReply }
        return false
    }
    private var pushAwaitingReply = false
    /// When the connection last dropped, until it is back.
    private var disconnectedSince: TimeInterval?

    /// Everything the listening cycle needs, read at one moment.
    public var activity: Activity {
        let now = clock()
        let userSpeaking = withSpeech { $0.isSpeaking(at: now) }
        return Activity(
            isOpen: wantsToRun,
            isUserSpeaking: userSpeaking,
            isAgentSpeaking: isAgentBusy(at: now),
            hasUnspokenNews: hasUnspokenNews,
            lastActivityAt: max(lastActivityAt, userSpeaking ? now : -.infinity))
    }

    /// True when the agent is not speaking or working on a reply and the user is quiet:
    /// the moment a task event would be spoken. For measurements and diagnostics.
    public var isQuietNow: Bool { isQuiet(at: clock()) }

    /// How many task events are waiting to be spoken.
    public nonisolated var queuedEventCount: Int { withQueue { $0.count } }

    // MARK: Keeping the agent in step

    /// A short fingerprint of the tool definitions. The prompt is fixed for a run of the app
    /// (it ships inside the package), so the tools are what can change.
    static func fingerprint(_ tools: [ToolSpec]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let definitions = JSONValue.array(tools.sorted { $0.name < $1.name }.map(AgentConfiguration.clientTool))
        let data = (try? encoder.encode(definitions)) ?? Data()
        // FNV-1a: stable across runs, unlike Hasher.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16) + "-\(data.count)"
    }

    /// Starts updating the agent's definition if the tools differ from what was last sent
    /// and no update is already on its way.
    private func startAgentSyncIfNeeded() {
        guard keeper != nil, !agentID.isEmpty else { return }
        let fingerprint = Self.fingerprint(tools)
        guard fingerprint != syncedFingerprint, fingerprint != syncingFingerprint else { return }
        syncingFingerprint = fingerprint
        agentSyncCount += 1
        let update = startCheck(push: true)
        syncTask = Task { @MainActor [weak self] in
            let check = await update.value
            if let self, self.syncingFingerprint == fingerprint {
                self.syncingFingerprint = nil
                self.syncTask = nil
            }
            return check
        }
    }

    /// Keeps the result of check number `number`, unless a newer one is already recorded.
    ///
    /// - In step: these tools count as synced and any repair stops. A model or reasoning
    ///   difference is only logged (`warning`).
    /// - Confirmed mismatch: logged loudly and a repair is scheduled, so the next wake finds it fixed.
    /// - Could not check: logged and shown; nothing is re-sent (a failed read says nothing about the
    ///   agent), and the last confirmed check still decides. The next wake checks again.
    private func record(_ check: AgentCheck, number: Int, tools checkedTools: [ToolSpec]) {
        // An older result is ignored unless it confirms the agent in step (an update that finished late
        // read the agent after it was changed, so its good news stands).
        guard number > newestRecordedCheck || check.inSync else {
            Self.logger.notice("Ignoring an older agent check (\(number) after \(self.newestRecordedCheck)): \(check.summary, privacy: .public)")
            return
        }
        newestRecordedCheck = max(newestRecordedCheck, number)
        agentCheck = check
        if check.couldNotCheck {
            Self.logger.error("Could not check the voice agent: \(check.detail ?? "", privacy: .public)")
            return
        }
        confirmedCheck = check
        if check.inSync {
            hasConfirmedGoodCheck = true
            syncedFingerprint = Self.fingerprint(checkedTools)
            repairTask?.cancel()
            repairTask = nil
        } else {
            Self.logger.error("Voice agent out of step: \(check.summary, privacy: .public) \(check.detail ?? "", privacy: .public)")
            if Self.fingerprint(checkedTools) == syncedFingerprint { syncedFingerprint = nil }
            scheduleRepair()
        }
    }

    /// While the agent is confirmed out of step, updates it again after 30 s, 60 s, 2 min, then every 5 min.
    private func scheduleRepair(startingAfter firstDelay: TimeInterval? = nil) {
        guard keeper != nil, repairTask == nil else { return }
        let delays = [firstDelay ?? 30, 60, 120, 300]
        repairTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.confirmedCheck?.inSync == true { break }
                let check = await self.startCheck(push: true).value
                if check.inSync {
                    Self.logger.notice("Voice agent repaired: \(check.summary, privacy: .public)")
                    break
                }
            }
            self?.repairTask = nil
        }
    }

    /// The agent asked for a tool the app does not have: it is out of step. Repaired at once.
    private func markOutOfStep(unknownTool name: String) {
        var check = confirmedCheck ?? AgentCheck.failed(detail: nil, at: Date())
        check.inSync = false
        check.couldNotCheck = false
        check.unexpected = Array(Set(check.unexpected + [name])).sorted()
        check.checkedAt = Date()
        check.problem = AgentCheck.notSetUpSentence
        agentCheck = check
        confirmedCheck = check
        syncedFingerprint = nil
        Self.logger.error("The agent called \(name, privacy: .public), which the app does not have; repairing the agent.")
        repairTask?.cancel()
        repairTask = nil
        scheduleRepair(startingAfter: 0)
    }

    private func prefetchConnection() {
        guard let prepareNextConnection, !agentID.isEmpty else { return }
        let start = ConversationStart(agentID: agentID, textOnly: mode == .text, dynamicVariables: [:])
        Task { await prepareNextConnection(start) }
    }

    // MARK: Connecting

    private func connect() async {
        guard wantsToRun else { return }
        generation += 1
        let myGeneration = generation
        let newDriver = makeDriver()
        driver = newDriver
        resetTurnState()
        connectStartedAt = clock()
        let request = ConversationStart(
            agentID: agentID,
            textOnly: mode == .text,
            dynamicVariables: ["user_memory": memorySummary.isEmpty ? "Nothing yet." : memorySummary,
                               "session_context": sessionContext()])
        do {
            try await newDriver.start(request) { [weak self] signal in
                self?.handle(signal, generation: myGeneration)
            }
            guard myGeneration == generation, wantsToRun else {
                await newDriver.end()
                return
            }
            isConnected = true
            reconnectAttempt = 0
            disconnectedSince = nil
            let now = clock()
            if !hasConnectedThisConversation {
                lastOpenTiming = OpenTiming(
                    waitedForAgentSync: syncWaitSeconds, connecting: now - connectStartedAt, total: now - openRequestedAt)
                Self.logger.notice("Conversation ready \(String(format: "%.2f", now - self.openRequestedAt), privacy: .public) s after the wake (connecting \(String(format: "%.2f", now - self.connectStartedAt), privacy: .public) s)")
            }
            hasConnectedThisConversation = true
            lastActivityAt = max(lastActivityAt, now)
            // The read-back started with this wake: nothing is said, and no "listening" is shown, until
            // it answers or `wakeCheckPatience` passes. Only a confirmed mismatch replaces the
            // conversation; a slow or failed read-back is logged and the conversation carries on.
            if let verification = pendingVerification {
                pendingVerification = nil
                let check = await Self.result(of: verification, atMost: tuning.wakeCheckPatience)
                guard myGeneration == generation, wantsToRun else { return }
                if let check, check.isConfirmedMismatch, confirmedCheck?.isConfirmedMismatch == true {
                    await replaceConversationWithWrongTools(generation: myGeneration)
                    return
                }
                if check == nil {
                    Self.logger.error("The agent read-back is still running after \(self.tuning.wakeCheckPatience, privacy: .public) s; carrying on")
                } else if check?.couldNotCheck == true {
                    Self.logger.error("Could not check the agent at this wake; carrying on with the conversation")
                }
            }
            bus.post(.listening)
            if let first = pendingFirstUtterance {
                pendingFirstUtterance = nil
                await sendFirstUtterance(first, generation: myGeneration, alreadyHeard: firstUtteranceAlreadyHeard)
            }
            await deliverIfReady()
        } catch {
            // A failed start may have got as far as the room or the microphone: end it explicitly.
            await newDriver.end()
            guard myGeneration == generation else { return }
            Self.logger.error("Voice connect failed: \(String(describing: error), privacy: .public)")
            connectionLost(AgentCheck.unreachableSentence)
        }
    }

    /// The conversation just opened belongs to an agent that is out of step (changed since the
    /// last check). It is ended before anything is said, the agent is updated, and a fresh
    /// conversation opens with the right tools; if the update fails, the wake is refused.
    private func replaceConversationWithWrongTools(generation connectionGeneration: Int) async {
        guard connectionGeneration == generation else { return }
        generation += 1
        isConnected = false
        let wrong = driver
        driver = nil
        await wrong?.end()
        guard keeper != nil, wantsToRun else { return }
        let repaired = await Self.result(of: syncTask ?? startCheck(push: true), atMost: tuning.repairPatience)
        guard wantsToRun, connectionGeneration + 1 == generation else { return }
        if repaired?.inSync == true || confirmedCheck?.isConfirmedMismatch == false {
            hasConnectedThisConversation = false
            await connect()
        } else {
            refuseOpen(AgentCheck.notSetUpSentence)
        }
    }

    /// Says the rest of the wake sentence on this connection. One quick retry if the send fails
    /// while still connected; if the connection dropped, it is kept for the reconnect. It is never
    /// carried into a different conversation (the generation check).
    private func sendFirstUtterance(_ text: String, generation connectionGeneration: Int, alreadyHeard: Bool = false) async {
        for attempt in 0..<2 {
            guard connectionGeneration == generation, wantsToRun else { return }
            do {
                try await sayAsUser(text, tellListeners: attempt == 0 && !alreadyHeard)
                return
            } catch {
                if attempt == 0, isConnected { await sleep(0.3) } else { break }
            }
        }
        if connectionGeneration == generation, wantsToRun, pendingFirstUtterance == nil {
            pendingFirstUtterance = text
            firstUtteranceAlreadyHeard = true  // the stop watcher has heard it; do not tell it again
        }
    }

    /// Sends what the user said to the wake listener as their turn, and shows it like a transcript.
    /// The listeners (the stop watcher) are told first, before any tool call of this turn can arrive.
    private func sayAsUser(_ text: String, tellListeners: Bool = true) async throws {
        guard let driver else { throw SpeakableError("The voice connection is not ready.") }
        let now = clock()
        awaitingReplySince = now
        lastActivityAt = now
        if tellListeners { notifyTranscriptListeners(text) }
        try await driver.sendUserMessage(text)
        remember("User: \(text)")
        bus.post(.userSaid(text))
    }

    private func connectionLost(_ reason: String) {
        isConnected = false
        if disconnectedSince == nil { disconnectedSince = clock() }
        // A push the agent may not have said before the drop is said again after reconnecting.
        let unanswered = said.notSent()
        if !unanswered.isEmpty { let now = clock(); withQueue { $0.putBack(unanswered, at: now) } }
        // End the old conversation explicitly, so nothing of it (room, microphone) lingers.
        let lost = driver
        driver = nil
        if let lost { Task { await lost.end() } }
        // A drop in a conversation that was connected is always announced. Failed attempts to open one
        // are announced only if no one else will: with the listening cycle, the cycle says once that
        // the wake failed, instead of the companion showing (and chiming) every retry.
        if hasConnectedThisConversation || announcesFailedOpens {
            bus.post(.voiceDisconnected(reason: reason))
        }
        guard wantsToRun, reconnectTask == nil else { return }
        let delays = tuning.reconnectDelays
        let delay = delays.isEmpty ? 1 : delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            await self?.sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    /// What a fresh session needs to carry on: a new session starts with no memory of the old one.
    private func sessionContext() -> String {
        var parts: [String] = []
        if keepsConversationOpen {
            parts.append("The Mac keeps this conversation open all the time: there is no wake phrase and no go_to_sleep.")
        }
        let isReconnect = hasConnectedThisConversation
        if isReconnect, !recentTurns.isEmpty {
            parts.append("The connection to the Mac dropped and came back. The last things said were: " + recentTurns.joined(separator: " | "))
        }
        if let lastTaskNote {
            if isReconnect {
                parts.append("Latest task news: \(lastTaskNote)")
            } else if clock() - lastTaskNoteAt < tuning.taskNewsShelfLife {
                parts.append("From an earlier conversation, the latest task news: \(lastTaskNote)")
            }
        }
        let waiting = withQueue { $0.pendingSummaries }
        if !waiting.isEmpty { parts.append("Not yet told to the user: " + waiting.joined(separator: " | ")) }
        let defaultContext = AgentConfiguration.dynamicVariableDefaults["session_context"]!
        if parts.count == (keepsConversationOpen ? 1 : 0) { parts.append(defaultContext) }
        return parts.joined(separator: "\n")
    }

    private func remember(_ turn: String) {
        recentTurns.append(String(turn.prefix(200)))
        if recentTurns.count > 6 { recentTurns.removeFirst(recentTurns.count - 6) }
    }

    private func resetTurnState() {
        agentAudible = false
        awaitingReplySince = nil
        pushAwaitingReply = false
        toolCallsInFlight = 0
    }

    // MARK: Signals from the conversation

    func handle(_ signal: ConversationSignal, generation signalGeneration: Int) {
        guard signalGeneration == generation else { return }  // from a connection we already left
        let now = clock()
        switch signal {
        case .userTranscript(let text):
            awaitingReplySince = now
            pushAwaitingReply = false
            lastActivityAt = now
            remember("User: \(text)")
            bus.post(.userSaid(text))
            notifyTranscriptListeners(text)
        case .agentResponse(let text):
            awaitingReplySince = nil
            pushAwaitingReply = false
            lastReplyAt = now
            lastActivityAt = now
            lastAgentSignalAt = now
            remember("Agent: \(text)")
            bus.post(.agentSpeaking(text))
            for listener in replyListeners { listener(text) }
            turnCounter += 1
            apply(said.replied(text, at: now, turn: turnCounter))
        case .agentActivity(let activity):
            agentAudible = activity != .listening
            lastActivityAt = now
            lastAgentSignalAt = now
            if activity == .listening, isConnected { bus.post(.listening) }
        case .voiceActivity(let level):
            peakVoiceActivity = max(peakVoiceActivity, level)
            voiceActivityObserver?(level)
            withSpeech { $0.heard(level: level, at: now) }
            if level >= tuning.voiceActivityThreshold {
                lastVoiceAt = now
                lastActivityAt = now
                // Only real speech is posted. The listening cycle counts every `.userSpeaking` as
                // activity, so room noise below the threshold must not keep the app awake.
                bus.post(.userSpeaking(level: level))
            }
        case .interruption:
            lastVoiceAt = now
            lastActivityAt = now
            interruptionCount += 1
            withSpeech { $0.voiceDetected(at: now) }
        case .toolRequested:
            awaitingReplySince = now
            lastActivityAt = now
        case .toolAnswered:
            // The agent's reply, if any, follows the tool's answer, so the wait restarts here.
            if awaitingReplySince != nil { awaitingReplySince = now }
            lastActivityAt = now
        case .silentTurn:
            // The agent chose to say nothing (skip_turn): the turn is over. Nothing is "on its way",
            // so task news goes out at once and the idle wait starts now, not after the reply timeout.
            agentAudible = false  // not "thinking" any more, so it does not hold the conversation open
            awaitingReplySince = nil
            pushAwaitingReply = false
            lastActivityAt = now
            // But a question, confirmation or result it skipped was not said: it goes again, once.
            apply(said.silent(at: now))
        case .toolCall(let name, let callID, let parameters):
            lastActivityAt = now
            runTool(name: name, callID: callID, parameters: parameters, generation: signalGeneration)
        case .disconnected(let reason):
            connectionLost(reason)
        }
        Task { @MainActor [weak self] in await self?.deliverIfReady() }
    }

    private func runTool(name: String, callID: String, parameters originalParameters: Data, generation callGeneration: Int) {
        if !router.knows(name) { markOutOfStep(unknownTool: name) }
        var parameters = originalParameters
        if name == Self.answerToolName {
            let taskID = Self.taskID(in: parameters)
            if let question = said.unheardQuestion(forAnswerTo: taskID) {
                holdBackAnswer(callID: callID, question: question, generation: callGeneration)
                return
            }
            // A yes to a held action is judged on what the user said, never on the agent's wording:
            // their most recent sentence after the confirmation was said. None yet: not passed on.
            if let confirmation = said.openQuestion(forAnswerTo: taskID), confirmation.kind == .confirmation {
                guard let heardIn = said.heardInTurn(confirmation), let reply = userSentence(after: heardIn) else {
                    holdBackUnansweredConfirmation(callID: callID, generation: callGeneration)
                    return
                }
                parameters = Self.replacingAnswer(in: parameters, with: reply)
            }
        }
        toolCallsInFlight += 1
        let router = self.router
        Task.detached { [weak self] in
            // Listeners for this turn's transcript go first, so the stop watcher sees the
            // state before the tool changes it.
            await self?.listenersCaughtUp()
            // With no good agent check yet, tools wait for the first read-back (at most 2 s). And a call
            // from a conversation that has since closed or been replaced never runs.
            guard await self?.toolMayRun(generation: callGeneration) == true else {
                await self?.toolDropped(generation: callGeneration)
                return
            }
            // Off the main actor: a slow handler must not hold up the conversation or the overlay.
            let reply = await router.handle(toolName: name, parametersJSON: parameters)
            if name == VoiceSession.answerToolName, !reply.isError {
                await self?.answerPassedOn(taskID: VoiceSession.taskID(in: parameters))
            }
            await self?.finishTool(callID: callID, reply: reply, generation: callGeneration)
        }
    }

    private func finishTool(callID: String, reply: ToolRouter.Reply, generation callGeneration: Int) async {
        guard callGeneration == generation else { return }  // the connection it belonged to is gone
        toolCallsInFlight = max(0, toolCallsInFlight - 1)
        lastActivityAt = clock()
        do {
            try await driver?.sendToolResult(callID: callID, text: reply.text, isError: reply.isError)
        } catch {
            Self.logger.error("Tool result not sent: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Was it said?

    /// The task tool that passes the user's reply to a waiting task (HFTasks).
    nonisolated static let answerToolName = "answer_task"

    nonisolated static func taskID(in parameters: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: parameters) as? [String: Any],
              let id = object["task_id"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return id
    }

    /// Counts for the status file: never the words.
    public struct SpokenNewsCounts: Sendable, Equatable {
        /// Pushes sent a second time because the first was not said.
        public var sentAgain: Int
        /// Pushes not said after the second attempt.
        public var notSaidTwice: Int
        /// Items unsaid right now (keeping the conversation open).
        public var unsaidNow: Int
        /// Answers not passed on because the user had not heard the question.
        public var answersHeldBack: Int
    }

    public var spokenNews: SpokenNewsCounts {
        SpokenNewsCounts(sentAgain: said.sentAgainCount, notSaidTwice: said.gaveUpCount,
                         unsaidNow: said.unsaid.count, answersHeldBack: said.answersHeldBack)
    }

    private func apply(_ outcome: SaidCheck.Outcome) {
        switch outcome {
        case .nothingPending, .said:
            return
        case .sendAgain(let events):
            let kinds = events.map(\.kind.rawValue).joined(separator: ", ")
            Self.logger.notice("Not said by the agent (\(kinds, privacy: .public)); sending it once more")
            let now = clock()
            withQueue { queue in
                for event in events where !queue.items.contains(where: { $0.event == event }) { queue.add(event, at: now) }
            }
            Task { @MainActor [weak self] in await self?.deliverIfReady() }
        case .gaveUp(let events):
            let kinds = events.map(\.kind.rawValue).joined(separator: ", ")
            Self.logger.error("Not said by the agent after two attempts (\(kinds, privacy: .public)); kept as unsaid")
        }
    }

    /// The agent tried to pass on an answer to a question the user has not heard in this
    /// conversation. It is not passed on: a stray "yes" must never become consent. The agent is
    /// told why, and the question is pushed again to be said.
    private func holdBackAnswer(callID: String, question: TaskEvent, generation callGeneration: Int) {
        Self.logger.notice("Answer held back: the user has not heard the \(question.kind.rawValue, privacy: .public) yet")
        let now = clock()
        let alreadyGoing = said.attempt?.events.contains(question) == true
        if !alreadyGoing {
            withQueue { queue in
                if !queue.items.contains(where: { $0.event == question }) { queue.add(question, at: now) }
            }
        }
        let reply = ToolRouter.Reply(
            text: "Not passed on: the user has not heard this task's question yet, so what they said is not an answer to it. "
                + "The app is sending you the question now. Say it to the user, then wait for their reply.",
            isError: true)
        toolCallsInFlight += 1
        Task { @MainActor [weak self] in
            await self?.finishTool(callID: callID, reply: reply, generation: callGeneration)
        }
    }

    private func answerPassedOn(taskID: String?) { said.answered(taskID: taskID) }

    /// The agent passed on an answer to a confirmation the user has not answered yet (no sentence
    /// of theirs since it was said). Not passed on: the yes must be the user's own words.
    private func holdBackUnansweredConfirmation(callID: String, generation callGeneration: Int) {
        said.noteAnswerHeldBack()
        Self.logger.notice("Answer held back: the user has not said anything since the confirmation was asked")
        let reply = ToolRouter.Reply(
            text: "Not passed on: the user has not answered the confirmation yet. Wait for them to say yes or no, then pass on their words.",
            isError: true)
        toolCallsInFlight += 1
        Task { @MainActor [weak self] in
            await self?.finishTool(callID: callID, reply: reply, generation: callGeneration)
        }
    }

    /// The user's most recent sentence (heard, or typed in a test) after turn `turn`.
    private func userSentence(after turn: Int) -> String? {
        userSentences.last(where: { $0.turn > turn })?.text
    }

    nonisolated static func replacingAnswer(in parameters: Data, with answer: String) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: parameters) as? [String: Any]) ?? [:]
        object["answer"] = answer
        return (try? JSONSerialization.data(withJSONObject: object)) ?? parameters
    }

    /// Waits for the tool gate (if any), then says whether a call from `callGeneration` may still run.
    private func toolMayRun(generation callGeneration: Int) async -> Bool {
        if let toolGate { await toolGate.value }
        return callGeneration == generation && wantsToRun && isConnected
    }

    /// A call that was not run: it no longer counts as in flight.
    private func toolDropped(generation callGeneration: Int) {
        guard callGeneration == generation else { return }
        toolCallsInFlight = max(0, toolCallsInFlight - 1)
    }

    /// A push with no reply at all within the reply timeout was not said. Not judged while the agent is
    /// speaking or working (a long reply, a tool call) or while the user is talking (over the reply, or
    /// answering it): the wait restarts from the last thing either side said or did.
    private func checkUnansweredPush() {
        guard isConnected, said.attempt != nil else { return }
        let now = clock()
        let agentHolding = agentAudible && now - lastAgentSignalAt < tuning.agentStuckAfter
        let userTalking = withSpeech { $0.isSpeaking(at: now) } || now - lastVoiceAt < tuning.userQuietAfter
        guard !agentHolding, toolCallsInFlight == 0, !userTalking else { return }
        let lastActivity = max(lastAgentSignalAt, lastVoiceAt, lastActivityAt)
        apply(said.checkTimeout(at: now, replyTimeout: tuning.replyTimeout, lastActivity: lastActivity))
    }

    /// Hands a sentence to every listener, in order, on the listener queue.
    ///
    /// Called the instant the transcript arrives, before any tool call of the same turn
    /// is handled: `runTool` waits for this queue first. That is what lets the stop watcher
    /// read "is the assistant waiting for an answer" before `answer_task` changes it.
    private func notifyTranscriptListeners(_ text: String) {
        turnCounter += 1
        userSentences.append((text, turnCounter))
        if userSentences.count > 10 { userSentences.removeFirst(userSentences.count - 10) }
        let listeners = (primaryListener.map { [$0] } ?? []) + transcriptListeners
        listenerQueue.async { [weak self] in
            for listener in listeners { listener(text) }
            guard let self else { return }
            let now = self.clock()
            self.withSpeech { $0.transcriptDelivered(at: now) }
        }
    }

    /// Returns once every listener call queued before it has finished. Never blocks a thread.
    private nonisolated func listenersCaughtUp() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listenerQueue.async { continuation.resume() }
        }
    }

    // MARK: Turn-taking

    /// True while the agent is talking, a reply is on its way, or a tool is running.
    private func isAgentBusy(at now: TimeInterval) -> Bool {
        guard wantsToRun else { return false }
        if toolCallsInFlight > 0 { return true }
        if agentAudible, now - lastAgentSignalAt < tuning.agentStuckAfter { return true }
        if let since = awaitingReplySince, now - since < tuning.replyTimeout { return true }
        if mode == .voice, now - lastReplyAt < tuning.settleAfterReply { return true }
        return false
    }

    /// True when nothing is being said and no reply is on its way.
    private func isQuiet(at now: TimeInterval) -> Bool {
        if isAgentBusy(at: now) { return false }
        return now - lastVoiceAt >= tuning.userQuietAfter
    }

    private func deliverIfReady() async {
        guard isConnected, let driver else { return }
        let now = clock()
        let quiet = isQuiet(at: now)
        let ready = withQueue { $0.takeReady(at: now, quiet: quiet, connected: true) }
        guard !ready.isEmpty else { return }
        // A progress line may get no reply at all (the agent is told it may say nothing), so only
        // a question, confirmation or result makes the next push wait for the agent's answer.
        // Otherwise a confirmation could sit behind a silent progress line for the full wait.
        let expectsReply = ready.contains { $0.kind != .progress }
        if expectsReply {
            awaitingReplySince = now
            pushAwaitingReply = true
        }
        lastActivityAt = now
        var message = PushQueue.message(for: ready)
        if said.isSecondTry(ready) { message = TaskEventSpeech.sayItNow + "\n" + message }
        said.sent(ready, at: now)
        do {
            try await driver.sendUserMessage(message)
        } catch {
            said.notSent()
            // Never lose a question or a confirmation: back to the front, sent after reconnecting.
            Self.logger.error("Task event not sent: \(String(describing: error), privacy: .public)")
            let failedAt = clock()
            withQueue { $0.putBack(ready, at: failedAt) }
            if expectsReply {
                awaitingReplySince = nil
                pushAwaitingReply = false
            }
        }
    }

    private func startPump() {
        pumpTask?.cancel()
        let interval = tuning.pumpInterval
        pumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleep(interval)
                self.checkUnansweredPush()
                if self.queuedEventCount > 0 { await self.deliverIfReady() }
            }
        }
    }
}

/// True for the first caller of `claim()` only. Thread-safe.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Holds a check handed across tasks. Thread-safe.
final class CheckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentCheck?
    var value: AgentCheck? { lock.withLock { stored } }
    func set(_ check: AgentCheck) { lock.withLock { stored = check } }
}
