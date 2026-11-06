import Foundation
import HFCore
import os

/// The live voice conversation with the ElevenLabs agent.
///
/// - Registers every ToolSpec and answers the agent's tool calls with JSON text.
/// - Hands every user sentence to the transcript listeners (the stop watcher is
///   one) on its own queue, so a slow listener never holds up the conversation.
/// - Speaks task events with `push(_:)`, waiting for a quiet moment first.
/// - Reconnects on its own, with growing gaps, and never takes the app down.
/// - Posts what it hears and says to the activity bus for the companion.
///
/// It matches the app's `VoiceConnecting` interface: `start(tools:memorySummary:onUserSentence:)`,
/// `push(_:)` and `stop()`.
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
        public var push = PushQueue.Timing()
        public init() {}
    }

    // MARK: Configuration

    private let agentID: String
    private let mode: Mode
    private let bus: ActivityBus
    private let tuning: Tuning
    private let makeDriver: @MainActor () -> ConversationDriving
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// Brings the agent's definition in step with the tools before the first connect.
    private let syncAgent: (@Sendable ([ToolSpec]) async -> Void)?
    nonisolated private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    // MARK: State (main actor)

    private var router = ToolRouter(tools: [])
    private var memorySummary = ""
    private var transcriptListeners: [@Sendable (String) -> Void] = []
    private var replyListeners: [@Sendable (String) -> Void] = []
    private var driver: ConversationDriving?
    /// Bumped on every connect, so signals from an old connection are ignored.
    private var generation = 0
    private var wantsToRun = false
    public private(set) var isConnected = false
    /// How often the user (or, if echo cancellation fails, the agent's own voice) cut in. For diagnostics.
    public private(set) var interruptionCount = 0
    /// The highest voice-activity score heard. Near zero all the time means the microphone is silent
    /// (macOS hands silent audio, not an error, to a process without Microphone permission).
    public private(set) var peakVoiceActivity = 0.0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    // Turn-taking.
    private var agentAudible = false
    private var awaitingReplySince: TimeInterval?
    private var lastReplyAt: TimeInterval = -.infinity
    private var lastVoiceAt: TimeInterval = -.infinity
    private var toolCallsInFlight = 0

    // What to tell the agent after a reconnect.
    private var recentTurns: [String] = []
    private var lastTaskNote: String?

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

    /// A session for the app, using `Settings` for the key and the agent id.
    ///
    /// With `syncAgentOnStart`, the agent on ElevenLabs is updated with the current
    /// prompt and tools before the first connect, so the agent always matches the code.
    public convenience init(
        settings: Settings,
        mode: Mode = .voice,
        bus: ActivityBus = .shared,
        configuration: AgentConfiguration = AgentConfiguration(),
        syncAgentOnStart: Bool = true,
        tuning: Tuning = Tuning()
    ) {
        let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
        let agentID = settings.elevenLabsAgentID
        let sync = syncAgentOnStart && !agentID.isEmpty
            ? Self.agentSynchroniser(api: api, configuration: configuration, agentID: agentID)
            : nil
        self.init(
            agentID: agentID, mode: mode, bus: bus, tuning: tuning,
            makeDriver: { ElevenLabsDriver(api: api) },
            clock: { ProcessInfo.processInfo.systemUptime },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
            syncAgent: sync)
    }

    /// Updates the agent on ElevenLabs with the current prompt and tools. A failure is
    /// logged and ignored: the agent keeps its last definition.
    nonisolated static func agentSynchroniser(
        api: ElevenLabsAPI, configuration: AgentConfiguration, agentID: String
    ) -> @Sendable ([ToolSpec]) async -> Void {
        { tools in
            do {
                _ = try await api.createOrUpdateAgent(definition: configuration.definition(tools: tools), knownAgentID: agentID)
            } catch {
                logger.error("Agent update failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The full initialiser, with the SDK, the clock and sleeping injectable. Tests in any package
    /// can pass their own `ConversationDriving` fake here, so nothing touches the network.
    public init(
        agentID: String,
        mode: Mode,
        bus: ActivityBus,
        tuning: Tuning,
        makeDriver: @escaping @MainActor () -> ConversationDriving,
        clock: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        syncAgent: (@Sendable ([ToolSpec]) async -> Void)?
    ) {
        self.agentID = agentID
        self.mode = mode
        self.bus = bus
        self.tuning = tuning
        self.makeDriver = makeDriver
        self.clock = clock
        self.sleep = sleep
        self.syncAgent = syncAgent
        self.queue = PushQueue(timing: tuning.push)
    }

    // MARK: Public interface

    /// Adds a listener that is told every finished user sentence. Listeners run in
    /// order on a background queue and must return quickly.
    public func addTranscriptListener(_ listener: @escaping @Sendable (String) -> Void) {
        transcriptListeners.append(listener)
    }

    /// Adds a listener for every reply the agent gives, as text.
    public func addReplyListener(_ listener: @escaping @Sendable (String) -> Void) {
        replyListeners.append(listener)
    }

    /// Starts the always-on conversation. Never throws: a problem is posted to the
    /// activity bus as `.voiceDisconnected` and the session keeps trying to connect.
    public func start(tools: [ToolSpec], memorySummary: String, onUserSentence: @escaping @Sendable (String) -> Void) async {
        addTranscriptListener(onUserSentence)
        await start(tools: tools, memorySummary: memorySummary)
    }

    /// Starts the conversation with these tools and this memory summary.
    public func start(tools: [ToolSpec], memorySummary: String) async {
        guard !wantsToRun else { return }
        router = ToolRouter(tools: tools)
        self.memorySummary = memorySummary
        wantsToRun = true
        guard !agentID.isEmpty else {
            bus.post(.voiceDisconnected(reason: "The voice agent is not set up yet. Run hf-voice setup."))
            wantsToRun = false
            return
        }
        if let syncAgent { await syncAgent(tools) }
        startPump()
        await connect()
    }

    /// Ends the conversation and stops reconnecting.
    public func stop() async {
        wantsToRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        generation += 1
        isConnected = false
        let ending = driver
        driver = nil
        await ending?.end()
    }

    /// Makes the agent say a task's question, confirmation, result or progress.
    ///
    /// Safe to call from any thread. The event waits until the agent has finished
    /// speaking and the user is quiet, because a pushed message cuts the agent off.
    /// Progress is also added silently to the agent's context straight away.
    public nonisolated func push(_ event: TaskEvent) {
        let now = clock()
        withQueue { $0.add(event, at: now) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastTaskNote = TaskEventSpeech.contextLine(for: event)
            if event.kind == .progress, self.isConnected, let driver = self.driver {
                try? await driver.sendContext(TaskEventSpeech.contextLine(for: event))
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

    /// True from the moment the user starts speaking until the transcript of what they said
    /// has reached the transcript listeners (with a short tail between words). Safe to read
    /// from any thread. The screen agent holds before each new action while this is true.
    public nonisolated var isUserSpeaking: Bool {
        let now = clock()
        return withSpeech { $0.isSpeaking(at: now) }
    }

    /// True when the agent is not speaking or working on a reply and the user is quiet:
    /// the moment a task event would be spoken. For measurements and diagnostics.
    public var isQuietNow: Bool { isQuiet(at: clock()) }

    /// How many task events are waiting to be spoken.
    public nonisolated var queuedEventCount: Int { withQueue { $0.count } }

    // MARK: Connecting

    private func connect() async {
        guard wantsToRun else { return }
        generation += 1
        let myGeneration = generation
        let newDriver = makeDriver()
        driver = newDriver
        resetTurnState()
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
            bus.post(.listening)
            await deliverIfReady()
        } catch {
            guard myGeneration == generation else { return }
            Self.logger.error("Voice connect failed: \(String(describing: error), privacy: .public)")
            connectionLost("I can't reach the voice service.")
        }
    }

    private func connectionLost(_ reason: String) {
        isConnected = false
        driver = nil
        bus.post(.voiceDisconnected(reason: reason))
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
        if !recentTurns.isEmpty {
            parts.append("The connection to the Mac dropped and came back. The last things said were: " + recentTurns.joined(separator: " | "))
        }
        if let lastTaskNote { parts.append("Latest task news: \(lastTaskNote)") }
        let waiting = withQueue { $0.pendingSummaries }
        if !waiting.isEmpty { parts.append("Not yet told to the user: " + waiting.joined(separator: " | ")) }
        return parts.isEmpty ? AgentConfiguration.dynamicVariableDefaults["session_context"]! : parts.joined(separator: "\n")
    }

    private func remember(_ turn: String) {
        recentTurns.append(String(turn.prefix(200)))
        if recentTurns.count > 6 { recentTurns.removeFirst(recentTurns.count - 6) }
    }

    private func resetTurnState() {
        agentAudible = false
        awaitingReplySince = nil
        toolCallsInFlight = 0
    }

    // MARK: Signals from the conversation

    func handle(_ signal: ConversationSignal, generation signalGeneration: Int) {
        guard signalGeneration == generation else { return }  // from a connection we already left
        let now = clock()
        switch signal {
        case .userTranscript(let text):
            awaitingReplySince = now
            remember("User: \(text)")
            bus.post(.userSaid(text))
            notifyTranscriptListeners(text)
        case .agentResponse(let text):
            awaitingReplySince = nil
            lastReplyAt = now
            remember("Agent: \(text)")
            bus.post(.agentSpeaking(text))
            for listener in replyListeners { listener(text) }
        case .agentActivity(let activity):
            agentAudible = activity != .listening
            if activity == .listening, isConnected { bus.post(.listening) }
        case .voiceActivity(let level):
            peakVoiceActivity = max(peakVoiceActivity, level)
            voiceActivityObserver?(level)
            withSpeech { $0.heard(level: level, at: now) }
            if level >= tuning.voiceActivityThreshold { lastVoiceAt = now }
            if level >= 0.1 { bus.post(.userSpeaking(level: level)) }
        case .interruption:
            lastVoiceAt = now
            interruptionCount += 1
            withSpeech { $0.voiceDetected(at: now) }
        case .toolRequested:
            awaitingReplySince = now
        case .toolAnswered:
            // The agent's reply, if any, follows the tool's answer, so the wait restarts here.
            if awaitingReplySince != nil { awaitingReplySince = now }
        case .toolCall(let name, let callID, let parameters):
            runTool(name: name, callID: callID, parameters: parameters, generation: signalGeneration)
        case .disconnected(let reason):
            connectionLost(reason)
        }
        Task { @MainActor [weak self] in await self?.deliverIfReady() }
    }

    private func runTool(name: String, callID: String, parameters: Data, generation callGeneration: Int) {
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
        let listeners = transcriptListeners
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

    // MARK: Speaking task events

    /// True when nothing is being said and no reply is on its way.
    private func isQuiet(at now: TimeInterval) -> Bool {
        if agentAudible || toolCallsInFlight > 0 { return false }
        if let since = awaitingReplySince, now - since < tuning.replyTimeout { return false }
        if mode == .voice, now - lastReplyAt < tuning.settleAfterReply { return false }
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
        if expectsReply { awaitingReplySince = now }
        do {
            try await driver.sendUserMessage(PushQueue.message(for: ready))
        } catch {
            // Never lose a question or a confirmation: back to the front, sent after reconnecting.
            Self.logger.error("Task event not sent: \(String(describing: error), privacy: .public)")
            let failedAt = clock()
            withQueue { $0.putBack(ready, at: failedAt) }
            if expectsReply { awaitingReplySince = nil }
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
