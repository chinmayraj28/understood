import Foundation

/// What a sentence from the user means while a task may be running.
public enum Intent: String, Sendable, CaseIterable {
    case cancel  // halt what the assistant is doing: "stop", "wait, don't"
    case command  // a new instruction, even if it contains "stop": "stop the music"
    case other  // an answer, chat, or background speech
}

/// Whether an action may go ahead without asking the user first.
public enum Risk: String, Sendable, CaseIterable {
    case safe
    case needsConfirmation = "needs_confirmation"
}

/// How the user replied when asked to confirm something.
public enum Answer: String, Sendable, CaseIterable {
    case yes
    case no
    case unclear  // anything that is not a clear yes or no; never treated as yes
}

/// Where a decision came from, so it can be shown and audited.
public enum DecisionSource: String, Sendable {
    case jev  // the classifier answered
    case keywords  // the fallback word list decided
    case rule  // a fixed rule decided without asking the classifier
}

/// The result of one classification.
public struct Decision<Label: Sendable & Equatable>: Sendable, Equatable {
    public let label: Label
    public let confidence: Double  // 0...1
    public let source: DecisionSource
    public let latencyMilliseconds: Double
    public let reason: String

    public init(
        label: Label,
        confidence: Double,
        source: DecisionSource,
        latencyMilliseconds: Double = 0,
        reason: String = ""
    ) {
        self.label = label
        self.confidence = confidence
        self.source = source
        self.latencyMilliseconds = latencyMilliseconds
        self.reason = reason
    }
}

/// What the stop watcher knows about the moment a sentence was spoken.
public struct UtteranceContext: Sendable, Equatable {
    /// A task is running or paused waiting for the user.
    public var taskRunning: Bool
    /// The assistant has just asked a question and is waiting for the reply.
    /// A bare "no" in this state is an answer, not a cancel.
    public var awaitingAnswer: Bool
    /// The question the assistant is waiting on, when there is one, so a reply can be read in its light.
    public var question: String?

    public init(taskRunning: Bool, awaitingAnswer: Bool = false, question: String? = nil) {
        self.taskRunning = taskRunning
        self.awaitingAnswer = awaitingAnswer
        self.question = question
    }
}

// The three fast decisions. HFDecisions implements all of them with Jev and a
// keyword fallback. None of them throws: on any failure they fall back and say
// so in `source`.

public protocol UtteranceClassifying: Sendable {
    func classifyUtterance(_ text: String, context: UtteranceContext) async -> Decision<Intent>
}

public protocol RiskClassifying: Sendable {
    /// Judges an on-screen action that is about to happen.
    /// Never fails open: low confidence, an error or a timeout mean `.needsConfirmation`.
    func classifyRisk(_ action: ScreenAction) async -> Decision<Risk>
}

public protocol AnswerClassifying: Sendable {
    /// Reads the user's reply to a confirmation. Anything uncertain is `.unclear`.
    func classifyAnswer(_ answer: String, question: String) async -> Decision<Answer>
}

/// The safety gate: `RiskClassifying` plus fixed rules and an audit log.
public protocol SafetyGating: Sendable {
    func check(_ action: ScreenAction) async -> Decision<Risk>
}
