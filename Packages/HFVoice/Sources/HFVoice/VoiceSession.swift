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
        /// The longest the first wake after launch waits for the agent's definition to be updated
        /// (measured at about 2 s). Real time: it bounds how long a person waits in silence.
        public var firstSyncPatience: TimeInterval = 3
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
        lastActivityAt = openRequestedAt
        hasConnectedThisConversation = false
        reconnectAttempt = 0
        let text = firstUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFirstUtterance = text.isEmpty ? nil : text
        firstUtteranceAlreadyHeard = false

        openRefusal = nil

        // A conversation never opens with the wrong tools: on 6 Nov the user spoke to an agent
        // whose only tool was a test one, and it invented results. So the agent must be known to
        // be in step first (see `agentReadyForConversation`).
        let ready = await agentReadyForConversation()
        syncWaitSeconds = clock() - openRequestedAt
        // Closed while waiting, or closed and opened again (that newer open connects instead).
        guard wantsToRun, thisOpen == openCount else { return }
        guard ready else {
            refuseOpen(agentCheck?.problem ?? "The voice agent isn't ready yet, so I can't start a conversation.")
            return
        }
        // Anything else holding the key could have changed the agent since the last check. A
        // read-back takes about 0.3 s, so it runs alongside connecting, and the first sentence
        // waits for its answer: a wake is no slower, and a changed agent is caught before anything is said.
        if let keeper {
            let tools = self.tools
            pendingVerification = Task { await keeper.verify(tools) }
        }
        startPump()
        await connect()
    }

    /// Whether the agent is known to have exactly this app's tools, updating it if needed.
    ///
    /// The launch-time update is waited for up to `firstSyncPatience`. If it is still on its way,
    /// a read-back (about 0.3 s) may show the agent already has these tools from the last run.
    /// If it is out of step, one update is tried now (about 2.5 s). Only a confirmed agent opens.
    private func agentReadyForConversation() async -> Bool {
        guard let keeper else { return true }
        startAgentSyncIfNeeded()
        if let syncTask { await Self.wait(for: syncTask, atMost: tuning.firstSyncPatience) }
        if agentCheck?.inSync == true { return true }
        let tools = self.tools
        let readBack = await keeper.verify(tools)
        record(readBack, tools: tools)
        if readBack.inSync { return true }
        if let syncTask {
            await Self.wait(for: syncTask, atMost: tuning.firstSyncPatience)
            if agentCheck?.inSync == true { return true }
        }
        let pushed = await keeper.push(tools)
        record(pushed, tools: tools)
        return pushed.inSync
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
    private static func wait(for task: Task<AgentCheck, Never>, atMost seconds: TimeInterval) async {
        let resumed = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                _ = await task.value
                if resumed.claim() { continuation.resume() }
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

    /// Makes the agent say a task's question, confirmation, result or progress.
    ///
    /// Safe to call from any thread. The event waits until the agent has finished
    /// speaking and the user is quiet, because a pushed message cuts the agent off.
    /// Progress is also added silently to the agent's context straight away.
    /// If no conversation is open, the event waits for the next one, and `onNewsWhileClosed`
    /// is called for anything the user must hear.
    public nonisolated func push(_ event: TaskEvent) {
        let now = clock()
        withQueue { $0.add(event, at: now) }
        Task { @MainActor [weak self] in
            guard let self else { return }
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
        if queuedEventCount > 0 { return true }
        // A question, confirmation or result was sent and the agent has not answered yet.
        if let since = awaitingReplySince, clock() - since < tuning.replyTimeout { return pushAwaitingReply }
        return false
    }
    private var pushAwaitingReply = false

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
        guard let keeper, !agentID.isEmpty else { return }
        let fingerprint = Self.fingerprint(tools)
        guard fingerprint != syncedFingerprint, fingerprint != syncingFingerprint else { return }
        syncingFingerprint = fingerprint
        agentSyncCount += 1
        let tools = self.tools
        syncTask = Task { @MainActor [weak self] in
            let check = await keeper.push(tools)
            guard let self else { return check }
            if self.syncingFingerprint == fingerprint {
                self.syncingFingerprint = nil
                self.syncTask = nil
            }
            self.record(check, tools: tools)
            return check
        }
    }

    /// Keeps the latest check. In step: these tools count as synced and any repair stops. Out of
    /// step: it is logged loudly and a repair is scheduled, so the next wake finds it fixed.
    private func record(_ check: AgentCheck, tools checkedTools: [ToolSpec]) {
        agentCheck = check
        if check.inSync {
            syncedFingerprint = Self.fingerprint(checkedTools)
            repairTask?.cancel()
            repairTask = nil
        } else {
            Self.logger.error("Voice agent out of step: \(check.summary, privacy: .public) \(check.detail ?? "", privacy: .public)")
            if Self.fingerprint(checkedTools) == syncedFingerprint { syncedFingerprint = nil }
            scheduleRepair()
        }
    }

    /// While the agent is out of step, updates it again after 30 s, 60 s, 2 min, then every 5 min.
    private func scheduleRepair(startingAfter firstDelay: TimeInterval? = nil) {
        guard let keeper, repairTask == nil else { return }
        let delays = [firstDelay ?? 30, 60, 120, 300]
        repairTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.agentCheck?.inSync == true { break }
                let tools = self.tools
                let check = await keeper.push(tools)
                self.agentCheck = check
                if check.inSync {
                    self.syncedFingerprint = Self.fingerprint(tools)
                    Self.logger.notice("Voice agent repaired: \(check.summary, privacy: .public)")
                    break
                }
            }
            self?.repairTask = nil
        }
    }

    /// The agent asked for a tool the app does not have: it is out of step. Repaired at once.
    private func markOutOfStep(unknownTool name: String) {
        var check = agentCheck ?? AgentCheck.failed("", detail: nil, at: Date())
        check.inSync = false
        check.unexpected = Array(Set(check.unexpected + [name])).sorted()
        check.checkedAt = Date()
        check.problem = "The voice agent asked for a tool the app doesn't have, so I'm updating it."
        agentCheck = check
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
            let now = clock()
            if !hasConnectedThisConversation {
                lastOpenTiming = OpenTiming(
                    waitedForAgentSync: syncWaitSeconds, connecting: now - connectStartedAt, total: now - openRequestedAt)
                Self.logger.notice("Conversation ready \(String(format: "%.2f", now - self.openRequestedAt), privacy: .public) s after the wake (connecting \(String(format: "%.2f", now - self.connectStartedAt), privacy: .public) s)")
            }
            hasConnectedThisConversation = true
            lastActivityAt = max(lastActivityAt, now)
            // The read-back started with this wake: nothing is said, and no "listening" is shown,
            // until it confirms the agent has the app's tools.
            if let verification = pendingVerification {
                pendingVerification = nil
                let check = await verification.value
                guard myGeneration == generation, wantsToRun else { return }
                record(check, tools: tools)
                if !check.inSync {
                    await replaceConversationWithWrongTools(generation: myGeneration)
                    return
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
            connectionLost("I can't reach the voice service.")
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
        guard let keeper, wantsToRun else { return }
        let tools = self.tools
        let repaired = await keeper.push(tools)
        record(repaired, tools: tools)
        guard wantsToRun else { return }
        if repaired.inSync {
            hasConnectedThisConversation = false
            await connect()
        } else {
            refuseOpen(repaired.problem ?? "The voice agent's tools don't match the app, so I can't start a conversation yet.")
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
        case .toolCall(let name, let callID, let parameters):
            lastActivityAt = now
            runTool(name: name, callID: callID, parameters: parameters, generation: signalGeneration)
        case .disconnected(let reason):
            connectionLost(reason)
        }
        Task { @MainActor [weak self] in await self?.deliverIfReady() }
    }

    private func runTool(name: String, callID: String, parameters: Data, generation callGeneration: Int) {
        if !router.knows(name) { markOutOfStep(unknownTool: name) }
        toolCallsInFlight += 1
        let router = self.router
        Task.detached { [weak self] in
            // Listeners for this turn's transcript go first, so the stop watcher sees the
            // state before the tool changes it.
            await self?.listenersCaughtUp()
            // Off the main actor: a slow handler must not hold up the conversation or the overlay.
            let reply = await router.handle(toolName: name, parametersJSON: parameters)
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

    /// Hands a sentence to every listener, in order, on the listener queue.
    ///
    /// Called the instant the transcript arrives, before any tool call of the same turn
    /// is handled: `runTool` waits for this queue first. That is what lets the stop watcher
    /// read "is the assistant waiting for an answer" before `answer_task` changes it.
    private func notifyTranscriptListeners(_ text: String) {
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
        do {
            try await driver.sendUserMessage(PushQueue.message(for: ready))
        } catch {
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
