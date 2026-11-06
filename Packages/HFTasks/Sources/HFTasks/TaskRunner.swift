import Foundation
import HFCore
import os

/// What the task voice tools need from a runner. `TaskRunner` is the real one;
/// tests pass a fake.
public protocol TaskRunning: Sendable {
    func start(goal: String) -> JSONObject
    func answer(_ answer: String, taskID: String?) -> JSONObject
    func cancel(taskID: String?) -> JSONObject
    func status() -> JSONObject
    var isRunning: Bool { get }
    var isAwaitingAnswer: Bool { get }
}

/// Runs one spoken goal at a time in the background of the conversation.
///
/// How it is built, and why (docs/TASKS.md has the full specification):
///
/// - It is a class guarded by one lock, not an actor. Every public method is
///   synchronous and quick, so `cancel()` runs straight away on the caller's
///   thread: it halts the hands, marks the task cancelled and emits the result
///   without waiting for anything. A blocked executor cannot delay it.
/// - The executor runs in its own detached task. Swift cancellation is
///   cooperative, so the runner cancels it, gives it a grace period to unwind,
///   and then abandons it if it will not stop. A stopped task's context is
///   revoked, so the executor can never ask, confirm or count steps again.
/// - The hands are released (`onTaskEnd`) only when no executor is alive, and a
///   new executor is never launched while an old one is still alive. So a
///   runaway executor can never move the pointer after a stop.
/// - Events go to the sink on a private serial queue, in the order the state
///   changed. A slow sink delays nothing else.
public final class TaskRunner: TaskRunning, @unchecked Sendable {

    /// Limits and timings. The defaults are the product's; tests shrink them.
    public struct Configuration: Sendable {
        /// Successful `context.step()` calls allowed.
        public var maxSteps: Int = 25
        /// Running time allowed. Time spent waiting for the user is not counted.
        public var maxSeconds: Double = 180
        /// How long one question or confirmation waits for an answer.
        public var questionTimeout: Double = 120
        /// How long a stopped executor gets to unwind before it is abandoned.
        public var cancelGrace: Double = 2
        /// Minimum gap between progress events from `report`.
        public var progressInterval: Double = 4
        /// How often limits are checked and a stopped executor is watched.
        public var tick: Double = 0.1
        /// No gate answer in this time means "ask the user".
        public var gateTimeout: Double = 3
        /// No classifier answer in this time means "use the word list".
        public var classifyTimeout: Double = 1.5
        /// No memory answer in this time means "no hints".
        public var memoryTimeout: Double = 1

        public init() {}

        /// The product defaults, with the step and time limits taken from settings.
        public init(settings: Settings) {
            self.init()
            maxSteps = settings.maxTaskSteps
            maxSeconds = settings.maxTaskSeconds
        }
    }

    let executor: any TaskExecuting
    let gate: any SafetyGating
    let answerClassifier: (any AnswerClassifying)?
    let memory: (any MemoryProviding)?
    let sink: TaskEventSink
    let configuration: Configuration
    let onCancel: (@Sendable () -> Void)?
    let onTaskEnd: (@Sendable (String, TaskStatus) -> Void)?
    let activityBus: ActivityBus
    let clock: @Sendable () -> TimeInterval

    let lock = NSRecursiveLock()
    var current: TaskRecord?
    var nextTaskNumber = 1
    var isClosed = false
    /// Tasks whose executor has been launched and has not yet returned.
    var liveExecutors: [String: TaskRecord] = [:]
    /// `onTaskEnd` calls held back while some executor is still alive.
    var heldTaskEnds: [(taskID: String, status: TaskStatus)] = []

    let deliveryQueue = DispatchQueue(label: "com.handsfree.tasks.events")
    static let deliveryQueueKey = DispatchSpecificKey<Bool>()
    let logger = Logger(subsystem: "com.handsfree", category: "tasks")

    /// - Parameters:
    ///   - executor: carries out the goal (the screen agent).
    ///   - gate: judges every action before it happens. Anything but a clear `.safe` means ask.
    ///   - answerClassifier: reads a reply to a confirmation (Jev). Without it, the word list decides.
    ///   - memory: hints for the goal, learning from answers, and the task log. Never slows a task.
    ///   - sink: receives every `TaskEvent`, on the runner's own queue, in order.
    ///   - onCancel: freezes the hands (`hands.halt`). Called first when a task is stopped.
    ///     Must return at once.
    ///   - onTaskEnd: releases the hands (`hands.resume`). Called once per task, only when
    ///     no executor is alive any more.
    ///   - activityBus: where the on-screen companion listens.
    ///   - clock: seconds from a monotonic clock. Drives the limits and the progress interval.
    public init(
        executor: any TaskExecuting,
        gate: any SafetyGating,
        answerClassifier: (any AnswerClassifying)? = nil,
        memory: (any MemoryProviding)? = nil,
        sink: @escaping TaskEventSink,
        configuration: Configuration = Configuration(),
        onCancel: (@Sendable () -> Void)? = nil,
        onTaskEnd: (@Sendable (String, TaskStatus) -> Void)? = nil,
        activityBus: ActivityBus = .shared,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.executor = executor
        self.gate = gate
        self.answerClassifier = answerClassifier
        self.memory = memory
        self.sink = sink
        self.configuration = configuration
        self.onCancel = onCancel
        self.onTaskEnd = onTaskEnd
        self.activityBus = activityBus
        self.clock = clock
        deliveryQueue.setSpecific(key: Self.deliveryQueueKey, value: true)
    }

    // MARK: - Public operations

    /// Schedules a goal and returns at once.
    ///
    /// Busy while a task is running or waiting for an answer. Refused while an
    /// old executor that would not stop is still alive, because starting a new
    /// one would mean releasing the hands it might still move.
    public func start(goal: String) -> JSONObject {
        let goal = SpokenText.clean(goal, limit: 2000)
        guard !goal.isEmpty else { return ToolResult.failure("The task needs a goal.") }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return ToolResult.failure("The task runner has shut down.") }
        if let current, current.isLive {
            return ToolResult.failure(
                "Another task is still going. Ask whether to cancel it first.",
                ["status": "busy", "task_id": .string(current.id), "goal": .string(current.goal)])
        }
        if let stuck = liveExecutors.values.first(where: { $0.isAbandoned }) {
            return ToolResult.failure(Self.stuckMessage, ["status": "stuck", "task_id": .string(stuck.id)])
        }
        let record = TaskRecord(id: "t\(nextTaskNumber)", goal: goal)
        nextTaskNumber += 1
        current = record
        transition(record, to: .running, kind: .progress, text: "Starting: \(goal)", postsProgress: false)
        activityBus.post(.taskStarted(goal: goal))
        record.supervisorTask = Task.detached { [self] in await supervise(record) }
        return ToolResult.ok(["task_id": .string(record.id), "status": .string(TaskStatus.running.rawValue)])
    }

    /// Hands the user's reply to the question or confirmation the task is waiting on.
    public func answer(_ answer: String, taskID: String? = nil) -> JSONObject {
        let answer = SpokenText.clean(answer, limit: 500)
        lock.lock()
        defer { lock.unlock() }
        guard let record = current, record.status == .needsInput, let pending = record.pending else {
            let status = current?.status?.rawValue ?? "idle"
            return ToolResult.failure("No task is waiting for an answer right now.", ["status": .string(status)])
        }
        if let taskID, !taskID.isEmpty, taskID != record.id {
            return ToolResult.failure(
                "That answer is for an old task. The waiting task is \(record.id).", ["task_id": .string(record.id)])
        }
        guard !answer.isEmpty else {
            return ToolResult.failure("The answer was empty.", ["task_id": .string(record.id)])
        }
        guard pending.answer == nil, let waiting = pending.continuation else {
            return ToolResult.failure("I already have an answer for that question.", ["task_id": .string(record.id)])
        }
        pending.answer = answer
        pending.continuation = nil
        waiting.resume(returning: answer)
        return ToolResult.ok(["task_id": .string(record.id), "status": .string(TaskStatus.running.rawValue)])
    }

    /// Stops the current task now, whether it is working or waiting for an answer.
    ///
    /// In order: halt the hands, mark the task cancelled and emit its result,
    /// return the summary, then cancel the executor. A task id that does not
    /// match still cancels the current task: "stop" must never fail on a technicality.
    public func cancel(taskID: String? = nil) -> JSONObject {
        lock.lock()
        guard let record = current, record.isLive else {
            let lastID: JSONValue = current.map { .string($0.id) } ?? .null
            lock.unlock()
            return ToolResult.ok(["status": "not_running", "task_id": lastID, "summary": "There's no task running."])
        }
        haltHands()
        var summary = "Stopped."
        if let pending = record.pending, pending.kind == .confirmation {
            summary += " I did not go ahead with \"\(pending.spokenQuestion)\"."
        }
        summary += " " + SpokenText.soFar(record.progressLog)
        finish(record, .cancelled, summary: summary)
        let executorTask = record.executorTask
        var result: JSONObject = [
            "task_id": .string(record.id), "status": .string(TaskStatus.cancelled.rawValue),
            "summary": .string(record.summary),
        ]
        if let taskID, !taskID.isEmpty, taskID != record.id {
            result["note"] = .string("Task \(taskID) was not running; stopped \(record.id) instead.")
        }
        lock.unlock()
        // Outside the lock: cancelling runs the executor's cancellation handlers on this thread.
        executorTask?.cancel()
        return ToolResult.ok(result)
    }

    /// The current task, or the last one when none is running.
    public func status() -> JSONObject {
        lock.lock()
        defer { lock.unlock() }
        guard let record = current, let status = record.status else {
            return ToolResult.ok(["status": "idle", "task_id": .null, "summary": "No task has run yet."])
        }
        var result: JSONObject = [
            "task_id": .string(record.id),
            "goal": .string(record.goal),
            "status": .string(status.rawValue),
            "steps": .number(Double(record.steps)),
            "seconds": .number((runningSeconds(record) * 10).rounded() / 10),
            "progress": .array(record.progressLog.suffix(3).map { .string($0) }),
        ]
        if status == .needsInput, let pending = record.pending {
            result["question"] = .string(pending.text)
            result["options"] = .array(pending.options.map { .string($0) })
            result["waiting_for"] = pending.kind == .confirmation ? "confirmation" : "answer"
            if pending.kind == .confirmation { result["action"] = .string(pending.actionDescription) }
        }
        if status.isFinal { result["summary"] = .string(record.summary) }
        if record.isAbandoned { result["stuck"] = true }
        return ToolResult.ok(result)
    }

    /// True while a task is running or waiting for an answer.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.isLive ?? false
    }

    /// True while the task has asked something and the user has not answered yet.
    /// The stop watcher uses this: a bare "no" now is an answer, not a cancel.
    public var isAwaitingAnswer: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = current, record.status == .needsInput, let pending = record.pending else { return false }
        return pending.answer == nil
    }

    /// Cancels any task, waits up to one grace period for its executor, and
    /// delivers queued events. Safe to call twice, and from the sink.
    public func shutdown() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        var executorTask: Task<Void, Never>?
        if let record = current, record.isLive {
            haltHands()
            finish(record, .cancelled, summary: "Stopped because the assistant is shutting down.")
            record.stopRequestedAt = .now
            executorTask = record.executorTask
        }
        lock.unlock()
        executorTask?.cancel()

        let deadline = Date().addingTimeInterval(configuration.cancelGrace)
        while Date() < deadline, withLock({ !liveExecutors.isEmpty }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let supervisors: [Task<Void, Never>] = withLock {
            for record in liveExecutors.values where !record.isAbandoned {
                record.isAbandoned = true
                logger.warning("executor for \(record.id, privacy: .public) did not stop by shutdown")
            }
            return ([current].compactMap { $0 } + Array(liveExecutors.values)).compactMap(\.supervisorTask)
        }
        supervisors.forEach { $0.cancel() }

        // Deliver what is queued, unless we are on the delivery queue ourselves (the sink called us).
        if DispatchQueue.getSpecific(key: Self.deliveryQueueKey) == nil {
            let delivered = DispatchSemaphore(value: 0)
            deliveryQueue.async { delivered.signal() }
            _ = delivered.wait(timeout: .now() + 2)
        }
    }

    static let stuckMessage =
        "The last task hasn't stopped yet, so I can't safely start another one. If this keeps happening, restart Handsfree."

    // MARK: - State machine

    /// The only legal moves. Final states have none.
    static func isAllowed(from old: TaskStatus?, to new: TaskStatus) -> Bool {
        switch (old, new) {
        case (nil, .running): return true
        case (.running?, .needsInput), (.running?, .done), (.running?, .failed), (.running?, .cancelled): return true
        case (.needsInput?, .running), (.needsInput?, .failed), (.needsInput?, .cancelled): return true
        default: return false
        }
    }

    /// The only place a status changes. Refuses an illegal move and changes nothing;
    /// a legal one emits exactly one event. Caller may or may not hold the lock.
    @discardableResult
    func transition(
        _ record: TaskRecord, to new: TaskStatus, kind: TaskEventKind, text: String,
        options: [String] = [], postsProgress: Bool = true
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isAllowed(from: record.status, to: new) else {
            logger.debug("refused \(record.status?.rawValue ?? "new", privacy: .public) -> \(new.rawValue, privacy: .public)")
            return false
        }
        let now = clock()
        if record.status == .running, let since = record.runningSince {
            record.bankedSeconds += now - since
            record.runningSince = nil
        }
        if new == .running { record.runningSince = now }
        record.status = new
        emit(TaskEvent(taskID: record.id, kind: kind, status: new, text: text, options: options),
             postsProgress: postsProgress)
        return true
    }

    /// Ends a task once. A later call (a cancel racing a finish) changes nothing.
    @discardableResult
    func finish(_ record: TaskRecord, _ status: TaskStatus, summary: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let summary = SpokenText.clean(summary, limit: 400)
        // Set before the transition so the RESULT event and status() agree.
        let previousSummary = record.summary
        record.summary = summary
        guard transition(record, to: status, kind: .result, text: summary) else {
            record.summary = previousSummary
            return false
        }
        // Revoke the question: whoever was waiting wakes with a cancellation error.
        if let waiting = record.pending?.continuation {
            record.pending?.continuation = nil
            waiting.resume(throwing: CancellationError())
        }
        record.pending = nil
        if let memory {
            let goal = record.goal, steps = record.progressLog, seconds = runningSeconds(record)
            Task.detached { await memory.taskEnded(goal: goal, status: status, summary: summary, steps: steps, seconds: seconds) }
        }
        queueTaskEnd(record)
        return true
    }

    /// Queues the hands to be released for this task, once it is final and its executor has ended.
    func queueTaskEnd(_ record: TaskRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard record.isFinal, !record.executorAlive, !record.taskEndQueued, let status = record.status else { return }
        record.taskEndQueued = true
        heldTaskEnds.append((record.id, status))
        releaseHandsIfNoExecutorIsAlive()
    }

    /// Calls `onTaskEnd` for every held task, but only when no executor of any
    /// task is still alive: a runaway executor keeps the hands halted.
    func releaseHandsIfNoExecutorIsAlive() {
        lock.lock()
        defer { lock.unlock() }
        guard liveExecutors.isEmpty, !heldTaskEnds.isEmpty else { return }
        let ended = heldTaskEnds
        heldTaskEnds.removeAll()
        guard let onTaskEnd else { return }
        // Under the lock on purpose: a new executor cannot launch before the hands are released.
        for item in ended { onTaskEnd(item.taskID, item.status) }
    }

    /// Freezes the hands first, before anything else about stopping a task.
    func haltHands() {
        lock.lock()
        defer { lock.unlock() }
        onCancel?()
        activityBus.post(.halted)
    }

    /// Queues an event for the sink and tells the companion. Order is preserved
    /// because events are queued while holding the lock.
    func emit(_ event: TaskEvent, postsProgress: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let sink = self.sink
        deliveryQueue.async { sink(event) }
        switch event.kind {
        case .progress where postsProgress: activityBus.post(.progress(event.text))
        case .progress: break
        case .question: activityBus.post(.waitingForAnswer(question: event.text))
        case .confirmation: activityBus.post(.heldForConfirmation(action: event.text))
        case .result: activityBus.post(.taskEnded(status: event.status, summary: event.text))
        }
    }

    /// Running time so far. The clock stops while the task waits for the user.
    func runningSeconds(_ record: TaskRecord) -> Double {
        guard let since = record.runningSince else { return record.bankedSeconds }
        return record.bankedSeconds + (clock() - since)
    }

    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
