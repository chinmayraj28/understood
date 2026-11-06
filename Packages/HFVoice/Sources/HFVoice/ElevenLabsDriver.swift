import Combine
import ElevenLabs
import Foundation
import HFCore
import os

/// What a conversation needs before it can connect: a LiveKit token for a voice conversation,
/// or a signed websocket URL for a text one. Fetching one takes 0.15 to 0.3 s (measured on
/// 6 Nov), which would be added to every wake. So one is fetched ahead of time, after each
/// conversation closes, and used by the next wake if it is still fresh.
///
/// Each prefetched credential is used once. Tokens are valid for 15 minutes (the token's own
/// `exp` minus `nbf` was 900 s); one older than `maximumAge` is thrown away and a new one
/// fetched while connecting, as before.
actor ConnectionCredentials {
    private let api: ElevenLabsAPI
    private let maximumAge: TimeInterval
    private var cached: (key: String, value: String, fetchedAt: Date)?
    private var fetching: Task<String?, Never>?
    private var fetchingKey: String?

    init(api: ElevenLabsAPI, maximumAge: TimeInterval = 600) {
        self.api = api
        self.maximumAge = maximumAge
    }

    private static func key(agentID: String, textOnly: Bool) -> String { "\(agentID)|\(textOnly)" }

    /// Fetches one for the next conversation, unless a fresh one is waiting already.
    func prefetch(agentID: String, textOnly: Bool) async {
        let key = Self.key(agentID: agentID, textOnly: textOnly)
        if let cached, cached.key == key, Date().timeIntervalSince(cached.fetchedAt) < maximumAge { return }
        if fetchingKey == key, let fetching { _ = await fetching.value; return }
        let api = self.api
        let task = Task<String?, Never> {
            try? await (textOnly ? api.signedURL(agentID: agentID) : api.conversationToken(agentID: agentID))
        }
        fetching = task
        fetchingKey = key
        let value = await task.value
        // If a conversation took this fetch while it was on its way, it is used already: keep nothing.
        guard let current = fetching, current == task else { return }
        fetching = nil
        fetchingKey = nil
        if let value { cached = (key, value, Date()) }
    }

    /// A credential for a conversation starting now: the prefetched one if it is fresh, else a new one.
    func take(agentID: String, textOnly: Bool) async throws -> String {
        let key = Self.key(agentID: agentID, textOnly: textOnly)
        if fetchingKey == key, let task = fetching {
            // Take over the fetch on its way, so the same credential is never used twice.
            fetching = nil
            fetchingKey = nil
            if let value = await task.value { return value }
        }
        if let cached, cached.key == key, Date().timeIntervalSince(cached.fetchedAt) < maximumAge {
            self.cached = nil
            return cached.value
        }
        return try await textOnly ? api.signedURL(agentID: agentID) : api.conversationToken(agentID: agentID)
    }
}

/// `ConversationDriving` on the ElevenLabs Swift SDK.
///
/// Voice sessions use WebRTC (LiveKit), whose macOS audio runs through Apple's
/// voice-processing input, the echo canceller that stops the agent hearing itself
/// on laptop speakers. Text sessions use a websocket and no microphone.
@MainActor
final class ElevenLabsDriver: ConversationDriving {
    private let credentials: ConnectionCredentials
    private var conversation: Conversation?
    private var observers: Set<AnyCancellable> = []
    private var endedByUs = false
    private var reportedEnd = false
    nonisolated private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    init(credentials: ConnectionCredentials) { self.credentials = credentials }

    convenience init(api: ElevenLabsAPI) { self.init(credentials: ConnectionCredentials(api: api)) }

    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws {
        // The SDK calls these from the main actor, in the order the server sent them. Handle
        // them right there, so a transcript is always handled before the tool call that follows
        // it. A separate Task per callback would not guarantee that order.
        let emit: @Sendable (ConversationSignal) -> Void = { signal in
            if Thread.isMainThread {
                MainActor.assumeIsolated { onSignal(signal) }
            } else {
                Task { @MainActor in onSignal(signal) }
            }
        }
        let config = ConversationConfig(
            conversationOverrides: ConversationOverrides(textOnly: start.textOnly),
            dynamicVariables: start.dynamicVariables,
            onDisconnect: { [weak self] reason in
                Task { @MainActor in self?.reportEnd(Self.describe(reason), emit: emit) }
            },
            onError: { error in Self.logger.error("Conversation error: \(String(describing: error), privacy: .public)") },
            onAgentResponse: { text, _ in emit(.agentResponse(text)) },
            onUserTranscript: { text, _ in emit(.userTranscript(text)) },
            onAgentToolResponse: { _ in emit(.toolAnswered) },
            onAgentToolRequest: { _ in emit(.toolRequested) },
            onInterruption: { _ in emit(.interruption) },
            onVadScore: { score in emit(.voiceActivity(score)) },
            onUnhandledClientToolCall: { call in
                emit(.toolCall(name: call.toolName, callID: call.toolCallId, parameters: call.parametersData))
            }
        )
        let auth: ElevenLabsConfiguration
        let credentials = self.credentials
        let agentID = start.agentID
        if start.textOnly {
            auth = try ElevenLabsConfiguration.signedWebSocketURL(try await credentials.take(agentID: agentID, textOnly: true))
        } else {
            // The SDK fetches the token first, then connects the room and turns the microphone on.
            // Failing here when the session was closed meanwhile stops it before the microphone.
            let closedCheck = ClosedCheck(self)
            auth = .customTokenProvider({
                let token = try await credentials.take(agentID: agentID, textOnly: false)
                if await closedCheck.isClosed() { throw CancellationError() }
                return token
            })
        }
        // Closed while getting ready: never open the room (and the microphone) for nothing.
        if endedByUs { throw CancellationError() }
        let conversation = try await ElevenLabs.startConversation(auth: auth, config: config)
        Self.track(conversation)
        self.conversation = conversation
        if endedByUs {
            // `end()` was called while this was still connecting: end it now, so nothing is left open.
            await end()
            return
        }
        if !start.textOnly {
            // In voice mode the SDK knows when the agent's audio is playing.
            conversation.$agentState
                .removeDuplicates()
                .sink { state in
                    switch state {
                    case .listening: emit(.agentActivity(.listening))
                    case .speaking: emit(.agentActivity(.speaking))
                    case .thinking: emit(.agentActivity(.thinking))
                    }
                }
                .store(in: &observers)
        }
        // Backstop for an end that arrives without onDisconnect.
        conversation.$state
            .sink { [weak self] state in
                if case .ended = state { Task { @MainActor in self?.reportEnd("The conversation ended.", emit: emit) } }
            }
            .store(in: &observers)
        if let metrics = conversation.startupMetrics {
            Self.logger.notice("Startup: total \(metrics.total ?? -1, privacy: .public) s, token \(metrics.tokenFetch ?? -1, privacy: .public) s, room \(metrics.roomConnect ?? -1, privacy: .public) s, agent \(metrics.agentReady ?? -1, privacy: .public) s, init \(metrics.conversationInit ?? -1, privacy: .public) s")
        }
    }

    func sendUserMessage(_ text: String) async throws {
        try await active().sendMessage(text)
    }

    func sendContext(_ text: String) async throws {
        try await active().updateContext(text)
    }

    func sendToolResult(callID: String, text: String, isError: Bool) async throws {
        // The String overload sends the text as it is: a JSON string, as the server needs.
        try await active().sendToolResult(for: callID, result: text, isError: isError)
    }

    func end() async {
        endedByUs = true
        observers.removeAll()
        let ending = conversation
        conversation = nil
        // Ends the room or the socket. In voice mode that unpublishes the microphone track,
        // so LiveKit's audio engine lets go of the microphone for the wake listener.
        await ending?.endConversation()
    }

    private func active() throws -> Conversation {
        guard let conversation, conversation.state.isActive else {
            throw SpeakableError("The voice connection is not ready.")
        }
        return conversation
    }

    private func reportEnd(_ reason: String, emit: @Sendable (ConversationSignal) -> Void) {
        guard !endedByUs, !reportedEnd else { return }
        reportedEnd = true
        emit(.disconnected(reason: reason))
    }

    nonisolated private static func describe(_ reason: DisconnectionReason) -> String {
        switch reason {
        case .agent: return "The voice service ended the session."
        case .user: return "The session was ended."
        case .error: return "The voice connection dropped."
        }
    }

    /// Lets the SDK's token callback, which runs off the main actor, ask whether the session
    /// was closed meanwhile, without holding on to the driver.
    private final class ClosedCheck: @unchecked Sendable {
        private weak var driver: ElevenLabsDriver?
        init(_ driver: ElevenLabsDriver) { self.driver = driver }
        @MainActor func isClosed() -> Bool { driver?.endedByUs ?? true }
    }

    // MARK: Checking that nothing is left behind

    private final class WeakConversation {
        weak var conversation: Conversation?
        init(_ conversation: Conversation) { self.conversation = conversation }
    }
    private static var tracked: [WeakConversation] = []

    private static func track(_ conversation: Conversation) {
        tracked.removeAll { $0.conversation == nil }
        tracked.append(WeakConversation(conversation))
    }

    /// How many SDK conversations created by this process still exist. After every session
    /// has closed, this should be 0: a closed conversation that stays in memory would keep
    /// its socket or room, and in voice mode perhaps the microphone.
    static var conversationsStillInMemory: Int {
        tracked.removeAll { $0.conversation == nil }
        return tracked.count
    }

    /// How many of them are still connected or connecting.
    static var conversationsStillActive: Int {
        tracked.filter { conversation in
            guard let state = conversation.conversation?.state else { return false }
            return state.isActive || state == .connecting
        }.count
    }
}
