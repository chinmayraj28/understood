import Foundation
import HFCore

extension TaskRunner {

    /// Runs one task from start to end: wait for any old executor, gather memory
    /// hints, launch the executor in its own task, then watch the limits until the
    /// executor ends, or until a stopped executor has used up its grace period.
    func supervise(_ record: TaskRecord) async {
        // 1. Never launch while an older executor is still alive: it may still hold the hands.
        let deadline = ContinuousClock.now + .nanoseconds(Int64(nanoseconds(configuration.cancelGrace)))
        while withLock({ !liveExecutors.isEmpty }), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: nanoseconds(configuration.tick))
        }
        let blocked: Bool = withLock {
            guard !liveExecutors.isEmpty else { return false }
            for old in liveExecutors.values where !old.isAbandoned {
                old.isAbandoned = true
                logger.warning("executor for \(old.id, privacy: .public) would not stop; abandoned")
            }
            return true
        }
        if blocked {
            finish(record, .failed, summary: Self.stuckMessage)
            return
        }

        // 2. Memory hints, bounded so a slow store cannot hold the task up.
        var hints = ""
        if let memory {
            let goal = record.goal
            hints = await valueWithin(seconds: configuration.memoryTimeout) { await memory.hints(forGoal: goal) } ?? ""
        }

        // 3. Launch the executor in its own task, never on a shared actor, so it
        //    cannot block the cancel path.
        let context = RunnerTaskContext(runner: self, record: record, memoryHints: hints)
        let launched: Bool = withLock {
            guard record.isLive, !isClosed else { return false }
            record.executorAlive = true
            liveExecutors[record.id] = record
            let executor = self.executor
            let goal = record.goal
            record.executorTask = Task.detached { [self] in
                let outcome: Result<String, Error>
                do {
                    outcome = .success(try await executor.run(goal: goal, context: context))
                } catch {
                    outcome = .failure(error)
                }
                executorEnded(record, outcome: outcome)
            }
            return true
        }
        guard launched else { return }

        // 4. Watch: limits while it is live, the grace period once it has been stopped.
        while true {
            try? await Task.sleep(nanoseconds: nanoseconds(configuration.tick))
            if Task.isCancelled { return }  // shutdown
            var executorToCancel: Task<Void, Never>?
            let keepWatching: Bool = withLock {
                guard record.executorAlive else { return false }
                if record.isLive {
                    if let reason = limitSummary(record) {
                        haltHands()
                        finish(record, .failed, summary: reason)
                        record.stopRequestedAt = .now
                        executorToCancel = record.executorTask
                    } else {
                        flushProgress(record)
                    }
                    return true
                }
                // Stopped from outside (cancel or shutdown): give it the grace period.
                let stoppedAt = record.stopRequestedAt ?? .now
                record.stopRequestedAt = stoppedAt
                if ContinuousClock.now - stoppedAt >= .nanoseconds(Int64(nanoseconds(configuration.cancelGrace))) {
                    record.isAbandoned = true
                    logger.warning("executor for \(record.id, privacy: .public) ignored cancellation; abandoned")
                    return false
                }
                return true
            }
            executorToCancel?.cancel()
            if !keepWatching { return }
        }
    }

    /// The summary to end with if a limit has passed, or nil.
    func limitSummary(_ record: TaskRecord) -> String? {
        let soFar = SpokenText.soFar(record.progressLog)
        if record.stepLimitHit {
            return "I stopped because the task used all \(configuration.maxSteps) of its steps without finishing. \(soFar)"
        }
        if record.status == .running, runningSeconds(record) >= configuration.maxSeconds {
            return "I stopped because the task took longer than \(SpokenText.duration(configuration.maxSeconds)) without finishing. \(soFar)"
        }
        if record.status == .needsInput, let pending = record.pending, pending.answer == nil,
            clock() - pending.askedAt >= configuration.questionTimeout
        {
            return "I stopped waiting for an answer to \"\(pending.text)\", so I ended the task. \(soFar)"
        }
        return nil
    }

    /// Called from the executor's own task when `run` returns or throws.
    func executorEnded(_ record: TaskRecord, outcome: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        record.executorAlive = false
        liveExecutors[record.id] = nil
        if record.isLive {
            settle(record, outcome: outcome)
        } else if record.isAbandoned {
            logger.info("abandoned executor for \(record.id, privacy: .public) has finally ended")
        }
        queueTaskEnd(record)
        releaseHandsIfNoExecutorIsAlive()
    }

    /// Turns the executor's outcome into the final state.
    func settle(_ record: TaskRecord, outcome: Result<String, Error>) {
        let soFar = SpokenText.soFar(record.progressLog)
        let stepSummary =
            "I stopped because the task used all \(configuration.maxSteps) of its steps without finishing. \(soFar)"
        switch outcome {
        case .success(let summary):
            if record.stepLimitHit {
                finish(record, .failed, summary: stepSummary)
            } else {
                let cleaned = SpokenText.clean(summary, limit: 400)
                finish(record, .done, summary: cleaned.isEmpty ? "Done." : cleaned)
            }
        case .failure(let error):
            if error is StepLimitReached || record.stepLimitHit {
                finish(record, .failed, summary: stepSummary)
            } else if let speakable = error as? SpeakableError {
                finish(record, .failed, summary: "\(SpokenText.clean(speakable.spokenMessage, limit: 200)) \(soFar)")
            } else if error is CancellationError || error is Halted {
                finish(record, .failed, summary: "The task stopped unexpectedly.")
            } else {
                logger.error("executor for \(record.id, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                finish(record, .failed, summary: "Something went wrong and I couldn't finish the task. \(soFar)")
            }
        }
        // For example, the executor returned while one of its own sub-tasks held a question open.
        if record.isLive { finish(record, .failed, summary: "The task ended unexpectedly.") }
    }
}
