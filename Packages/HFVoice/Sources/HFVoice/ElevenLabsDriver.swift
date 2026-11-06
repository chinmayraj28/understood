import Combine
import ElevenLabs
import Foundation
import HFCore
import os

/// `ConversationDriving` on the ElevenLabs Swift SDK.
///
/// Voice sessions use WebRTC (LiveKit), whose macOS audio runs through Apple's
/// voice-processing input, the echo canceller that stops the agent hearing itself
/// on laptop speakers. Text sessions use a websocket and no microphone.
@MainActor
final class ElevenLabsDriver: ConversationDriving {
    private let api: ElevenLabsAPI
    private var conversation: Conversation?
    private var observers: Set<AnyCancellable> = []
    private var endedByUs = false
    private var reportedEnd = false
    nonisolated private static let logger = Logger(subsystem: "com.handsfree", category: "HFVoice")

    init(api: ElevenLabsAPI) { self.api = api }

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
        if start.textOnly {
            auth = try ElevenLabsConfiguration.signedWebSocketURL(try await api.signedURL(agentID: start.agentID))
        } else {
            let api = self.api
            let agentID = start.agentID
            auth = .customTokenProvider({ try await api.conversationToken(agentID: agentID) })
        }
        let conversation = try await ElevenLabs.startConversation(auth: auth, config: config)
        self.conversation = conversation
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
        await conversation?.endConversation()
        conversation = nil
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
}
