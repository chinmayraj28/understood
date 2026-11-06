import Foundation

/// What the agent is doing, as far as turn-taking is concerned.
public enum AgentActivity: Sendable, Equatable {
    case listening, speaking, thinking
}

/// Everything the live conversation reports back to the session.
public enum ConversationSignal: Sendable, Equatable {
    case userTranscript(String)
    case agentResponse(String)
    case agentActivity(AgentActivity)
    /// 0...1, how likely it is that the user is speaking. Arrives several times a second.
    case voiceActivity(Double)
    /// The user started talking over the agent or over a running tool.
    case interruption
    case toolCall(name: String, callID: String, parameters: Data)
    case toolRequested
    case toolAnswered
    /// The agent ended its turn without speaking (ElevenLabs' built-in skip_turn tool). No reply follows.
    case silentTurn
    /// The conversation ended without the session asking it to.
    case disconnected(reason: String)
}

/// How a conversation is started.
public struct ConversationStart: Sendable, Equatable {
    public var agentID: String
    public var textOnly: Bool
    public var dynamicVariables: [String: String]

    public init(agentID: String, textOnly: Bool, dynamicVariables: [String: String]) {
        self.agentID = agentID
        self.textOnly = textOnly
        self.dynamicVariables = dynamicVariables
    }
}

/// The small slice of the ElevenLabs SDK the session uses. The live version is
/// `ElevenLabsDriver`; tests use a fake, so no test needs the network. It is public so
/// other packages can fake the voice session too, with `VoiceSession(agentID:mode:bus:tuning:makeDriver:clock:sleep:syncAgent:)`.
@MainActor
public protocol ConversationDriving: AnyObject {
    /// Connects and returns once the conversation is ready. Signals arrive on the main actor.
    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws
    func sendUserMessage(_ text: String) async throws
    func sendContext(_ text: String) async throws
    /// `text` is JSON text. It must be a string on the wire, never an object.
    func sendToolResult(callID: String, text: String, isError: Bool) async throws
    func end() async
}
