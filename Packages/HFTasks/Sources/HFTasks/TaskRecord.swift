import Foundation
import HFCore

/// One question or confirmation waiting for the user.
final class PendingAnswer {
    let kind: TaskEventKind  // .question or .confirmation
    /// What the user was asked (for a re-ask, the plainer wording).
    let text: String
    /// For a confirmation, the original spoken question, used in the cancel summary.
    let spokenQuestion: String
    /// For a confirmation, the raw action description the gate judged.
    let actionDescription: String
    let options: [String]
    /// Clock time when it was asked, for the question timeout.
    let askedAt: Double
    /// Set by `answer(...)`. Once set, a second answer is refused.
    var answer: String?
    /// The executor waiting for this answer. Taken (set to nil) when it is resumed,
    /// so it is resumed exactly once.
    var continuation: CheckedContinuation<String, Error>?

    init(
        kind: TaskEventKind, text: String, spokenQuestion: String, actionDescription: String,
        options: [String], askedAt: Double, continuation: CheckedContinuation<String, Error>
    ) {
        self.kind = kind
        self.text = text
        self.spokenQuestion = spokenQuestion
        self.actionDescription = actionDescription
        self.options = options
        self.askedAt = askedAt
        self.continuation = continuation
    }
}

/// Everything the runner knows about one task. Only touched while holding the runner's lock.
final class TaskRecord: @unchecked Sendable {
    let id: String
    let goal: String

    /// nil only for the instant before the task's first transition to `.running`.
    var status: TaskStatus?
    var steps = 0
    /// Running time banked so far. Time spent waiting for the user is never added.
    var bankedSeconds: Double = 0
    /// Clock time the task last entered `.running`; nil while it is not running.
    var runningSince: Double?
    var pending: PendingAnswer?
    var summary = ""
    var lastAnswer = ""
    var stepLimitHit = false

    var progressLog: [String] = []  // last 12 lines, for summaries
    var lastProgressEmitAt = -Double.infinity
    var lastProgressEmitted = ""
    var queuedProgress = ""  // a rate-limited line, sent when the interval allows

    /// The executor's own task. Cancelled when the runner stops the task.
    var executorTask: Task<Void, Never>?
    /// True from the moment the executor is launched until its `run` returns or throws.
    var executorAlive = false
    /// When the runner asked the executor to stop, for the grace period.
    var stopRequestedAt: ContinuousClock.Instant?
    /// The executor did not stop within the grace period and was left behind.
    var isAbandoned = false
    /// `onTaskEnd` has been queued for this task (it is called once).
    var taskEndQueued = false
    /// The task that waits for limits and watches a stopped executor.
    var supervisorTask: Task<Void, Never>?

    init(id: String, goal: String) {
        self.id = id
        self.goal = goal
    }

    var isLive: Bool { status == .running || status == .needsInput }
    var isFinal: Bool { status?.isFinal ?? false }
}
