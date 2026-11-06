import Foundation

public enum TaskStatus: String, Sendable {
    case running
    case needsInput = "needs_input"  // paused, waiting for the user to answer
    case done
    case failed
    case cancelled

    /// True once the task can no longer change state.
    public var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
}

public enum TaskEventKind: String, Sendable {
    case progress  // "Opening WhatsApp"
    case question  // "Priya Shah or Priya Patel?"
    case confirmation  // "Send 'running late' to Amma?"
    case result  // the task ended: done, failed or cancelled
}

/// Something the task runner wants the voice agent to know or say.
public struct TaskEvent: Sendable, Equatable {
    public let taskID: String
    public let kind: TaskEventKind
    public let status: TaskStatus
    /// A progress line, the question to ask, or the final summary. Always speakable.
    public let text: String
    /// Suggested answers for a question, if any.
    public let options: [String]

    public init(taskID: String, kind: TaskEventKind, status: TaskStatus, text: String, options: [String] = []) {
        self.taskID = taskID
        self.kind = kind
        self.status = status
        self.text = text
        self.options = options
    }
}

/// Receives every task event. May be called from any thread.
public typealias TaskEventSink = @Sendable (TaskEvent) -> Void

/// Thrown by `TaskContext.step()` when the task has used all its steps.
public struct StepLimitReached: Error, Sendable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

/// What the screen agent is given to talk to the outside world.
///
/// The agent never speaks to the user or calls the safety gate directly. It goes
/// through this object, so every task pauses, asks and stops in the same way.
public protocol TaskContext: AnyObject, Sendable {
    var taskID: String { get }
    var goal: String { get }
    /// What we know about the user that may help with this goal: preferences and
    /// a recipe or two. Advice for the agent, not orders.
    var memoryHints: String { get }
    /// The user's most recent reply to a question or confirmation, word for word.
    /// After a declined confirmation this holds what they actually said, such as
    /// "wait, change the time to four", so the agent can act on a correction.
    /// Empty until the user has answered something.
    var lastAnswer: String { get }

    /// Pauses the task, asks the user out loud, and returns their answer.
    func askUser(_ question: String, options: [String]) async throws -> String

    /// Runs the safety gate on an action that is about to happen.
    ///
    /// - Parameters:
    ///   - action: what the gate judges, built in code from what is really under
    ///     the pointer or holding keyboard focus at that moment (see `Labels.clickAction`).
    ///   - spokenQuestion: what the user hears if the action needs confirming,
    ///     e.g. `Send "running late" to Amma?`. When nil, a sentence is built from
    ///     the action's description.
    /// - Returns: true if the action may go ahead (it was safe, or the user gave
    ///   a clear yes); false if the user did not.
    func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool

    /// Tells the user what is happening, in a few words.
    func report(_ progress: String)

    /// Counts one agent step. Throws `StepLimitReached` past the limit.
    func step() throws
}

/// Something that can carry out a spoken goal. The screen agent is the one implementation.
public protocol TaskExecuting: Sendable {
    /// Carries out the goal and returns one short sentence to say to the user.
    ///
    /// Must stop promptly when its Swift task is cancelled, and must leave the
    /// pointer and keyboard released. On failure it throws `SpeakableError`.
    func run(goal: String, context: TaskContext) async throws -> String
}
