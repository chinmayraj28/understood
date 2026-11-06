import Foundation
import HFCore

/// The concrete `TaskContext` the executor receives. Every call goes through the
/// runner, which checks first that the task is still live: once a task has ended,
/// its context is revoked and can never ask, confirm or count a step again.
public final class RunnerTaskContext: TaskContext, @unchecked Sendable {
    public let taskID: String
    public let goal: String
    public let memoryHints: String
    private unowned let runner: TaskRunner
    let record: TaskRecord

    init(runner: TaskRunner, record: TaskRecord, memoryHints: String) {
        self.runner = runner
        self.record = record
        self.taskID = record.id
        self.goal = record.goal
        self.memoryHints = memoryHints
    }

    /// The user's exact words in their most recent answer, so an executor can act
    /// on "wait, change the time to 4" after `confirm` returned false.
    public var lastAnswer: String { runner.withLock { record.lastAnswer } }

    public func askUser(_ question: String, options: [String]) async throws -> String {
        try await runner.askUser(record, question: question, options: options)
    }

    public func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool {
        try await runner.confirm(record, action: action, spokenQuestion: spokenQuestion)
    }

    public func report(_ progress: String) { runner.report(record, progress) }

    public func step() throws { try runner.step(record) }
}

extension TaskRunner {

    func askUser(_ record: TaskRecord, question: String, options: [String]) async throws -> String {
        let question = SpokenText.clean(question, limit: 300).nonEmpty ?? "What should I do?"
        let options = Array(options.map { SpokenText.clean($0, limit: 80) }.filter { !$0.isEmpty }.prefix(6))
        let answer = try await waitForAnswer(
            record, kind: .question, text: question, options: options, spokenQuestion: question,
            actionDescription: "", isReask: false)
        try resumeRunning(record, text: "Got it: \(answer).")
        if let memory {
            let goal = record.goal
            Task.detached { await memory.learn(fromQuestion: question, options: options, answer: answer, goal: goal) }
        }
        return answer
    }

    /// The gate judges the structured `ScreenAction`; its one-sentence `description`
    /// (built in HFCore, nowhere else) is what `status()` shows and what the fallback
    /// spoken question is made from.
    func confirm(_ record: TaskRecord, action screenAction: ScreenAction, spokenQuestion: String?) async throws -> Bool {
        let action = SpokenText.clean(screenAction.description, limit: 300).nonEmpty ?? "Go ahead with the next step"
        try ensureLive(record)
        let gate = self.gate
        let risk = await valueWithin(seconds: configuration.gateTimeout) { await gate.check(screenAction) }
        // A safe verdict must never reach a task that was stopped while the gate thought.
        try ensureLive(record)
        if risk?.label == .safe { return true }

        let spoken = spokenQuestion.map { SpokenText.clean($0, limit: 300) }?.nonEmpty
            ?? SpokenText.fallbackQuestion(forAction: action)
        let firstReply = try await waitForAnswer(
            record, kind: .confirmation, text: spoken, options: ["yes", "no"], spokenQuestion: spoken,
            actionDescription: action, isReask: false)
        var verdict = await judge(firstReply, question: spoken)
        if verdict == .unclear {
            // One misheard reply should not throw away a task, so ask once more in plainer words.
            let plainer = "Sorry, I didn't catch that. \(spoken) Please say yes or no."
            let secondReply = try await waitForAnswer(
                record, kind: .confirmation, text: plainer, options: ["yes", "no"], spokenQuestion: spoken,
                actionDescription: action, isReask: true)
            verdict = await judge(secondReply, question: spoken)
        }
        let resumeText: String
        switch verdict {
        case .yes: resumeText = "Going ahead."
        case .no: resumeText = "OK, I won't do that."
        case .correction: resumeText = "OK, I haven't done it."
        case .unclear: resumeText = "I didn't hear a clear yes, so I haven't done it."  // only after the re-ask
        }
        try resumeRunning(record, text: resumeText)
        return verdict == .yes
    }

    /// The word list runs first; a "no" or a correction is a veto the classifier
    /// cannot override. Otherwise the classifier decides, and if it is missing,
    /// slow or broken, the word list's verdict stands.
    func judge(_ reply: String, question: String) async -> ReplyVerdict {
        let fromWords = ReplyJudge.wordList(reply)
        if fromWords == .no || fromWords == .correction { return fromWords }
        guard let classifier = answerClassifier else { return fromWords }
        let decision = await valueWithin(seconds: configuration.classifyTimeout) {
            await classifier.classifyAnswer(reply, question: question)
        }
        guard let decision else { return fromWords }
        switch decision.label {
        case .yes: return .yes
        case .no: return .no
        case .unclear: return .unclear
        }
    }

    /// Moves to `needsInput` (or, for a re-ask, stays there and asks again) and
    /// waits for `answer(...)`. Throws `CancellationError` if the task ends first.
    func waitForAnswer(
        _ record: TaskRecord, kind: TaskEventKind, text: String, options: [String], spokenQuestion: String,
        actionDescription: String, isReask: Bool
    ) async throws -> String {
        let answer: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                lock.lock()
                defer { lock.unlock() }
                guard record.isLive, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let expectedStatus: TaskStatus = isReask ? .needsInput : .running
                guard record.status == expectedStatus, record.pending == nil || isReask else {
                    continuation.resume(throwing: SpeakableError("The task tried to ask two things at once."))
                    return
                }
                record.pending = PendingAnswer(
                    kind: kind, text: text, spokenQuestion: spokenQuestion, actionDescription: actionDescription,
                    options: options, askedAt: clock(), continuation: continuation)
                if isReask {
                    // Not a state change: the task stays in needsInput with its clock paused.
                    emit(TaskEvent(taskID: record.id, kind: kind, status: .needsInput, text: text, options: options))
                } else {
                    transition(record, to: .needsInput, kind: kind, text: text, options: options)
                }
            }
        } onCancel: { [self] in
            lock.lock()
            let waiting = record.pending?.continuation
            record.pending?.continuation = nil
            lock.unlock()
            waiting?.resume(throwing: CancellationError())
        }
        withLock { record.lastAnswer = answer }
        return answer
    }

    /// Back to `running` after an answer, with a line saying what was decided.
    func resumeRunning(_ record: TaskRecord, text: String) throws {
        try withLock {
            record.pending = nil
            guard transition(record, to: .running, kind: .progress, text: text) else { throw CancellationError() }
        }
    }

    func ensureLive(_ record: TaskRecord) throws {
        if Task.isCancelled { throw CancellationError() }
        try withLock { if !record.isLive { throw CancellationError() } }
    }

    /// Keeps the line for summaries, and emits it at most once per progress interval.
    func report(_ record: TaskRecord, _ text: String) {
        let text = SpokenText.clean(text, limit: 200)
        guard !text.isEmpty else { return }
        withLock {
            guard record.isLive else { return }
            if record.progressLog.last != text {
                record.progressLog.append(text)
                if record.progressLog.count > 12 { record.progressLog.removeFirst(record.progressLog.count - 12) }
            }
            guard text != record.lastProgressEmitted else { return }
            record.queuedProgress = text
            flushProgress(record)
        }
    }

    /// Sends the newest held-back progress line if the interval allows. Also called every tick.
    func flushProgress(_ record: TaskRecord) {
        withLock {
            let text = record.queuedProgress
            let now = clock()
            guard !text.isEmpty, record.status == .running,
                now - record.lastProgressEmitAt >= configuration.progressInterval
            else { return }
            record.queuedProgress = ""
            record.lastProgressEmitAt = now
            record.lastProgressEmitted = text
            emit(TaskEvent(taskID: record.id, kind: .progress, status: .running, text: text))
        }
    }

    func step(_ record: TaskRecord) throws {
        try withLock {
            guard record.isLive else { throw CancellationError() }
            if record.stepLimitHit || record.steps >= configuration.maxSteps {
                record.stepLimitHit = true
                throw StepLimitReached(limit: configuration.maxSteps)
            }
            record.steps += 1
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
