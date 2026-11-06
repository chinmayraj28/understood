import Foundation
import HFCore
import os

/// Hears every sentence the user says and cancels the running task on "stop".
///
/// `heard(_:)` is called from the voice session for every user sentence and
/// returns at once; nothing in it waits for the network.
///
/// 1. No task running: nothing happens, and Jev is not called.
/// 2. An exact stop phrase ("stop", "cancel", "never mind", "stop... stop it",
///    "uh, wait") cancels immediately, without the network. While the assistant is
///    waiting for an answer, only phrases that end the whole task ("stop", "stop
///    everything", "cancel the task", "abort") do; "no, don't" is then an answer. This is safe because
///    the whole sentence must be the phrase: "stop the music" and "don't stop"
///    never match. The worst false alarm is the user saying exactly "stop" to
///    someone else, which costs a restart; waiting ~200 ms for Jev on every real
///    "stop" while the pointer keeps moving costs more.
/// 3. Anything else goes to the utterance classifier in the background, and
///    `cancel` is called the moment it says cancel.
///
/// Two guards keep it from cancelling the wrong task:
/// - The task id is captured when the sentence arrives. When Jev's answer comes
///   back (up to 0.8 s later), it cancels only if that same task is still the
///   current one. "Please stop doing that" while task A runs can never cancel a
///   task B that started in the meantime.
/// - If a cancel was already issued after the sentence was spoken, a late answer
///   for that sentence is ignored, so one "stop" never cancels twice.
///
/// **Ordering rule.** `isAwaitingAnswer()` is read at the moment `heard(_:)` is
/// called, so the voice session must call `heard(text)` *before* the same
/// sentence is passed to `answer_task`. Otherwise the question may already be
/// answered and "no, don't" would be judged as if nothing were being asked.
/// Calling transcript listeners as soon as a transcript arrives satisfies this.
///
/// It posts nothing to the activity bus: the task runner owns `.halted`.
public final class StopWatcher: @unchecked Sendable {
    private let classifier: UtteranceClassifying
    private let isTaskRunning: @Sendable () -> Bool
    private let isAwaitingAnswer: @Sendable () -> Bool
    private let cancel: @Sendable () -> Void
    private let currentTaskID: @Sendable () -> String?

    /// Every check-and-cancel runs here, one at a time, so two answers can never both cancel.
    private let actingQueue = DispatchQueue(label: "com.handsfree.stopwatcher", qos: .userInteractive)
    private let lock = NSLock()
    private var lastCancelAt: UInt64 = 0  // DispatchTime uptime nanoseconds
    private var cancelledTaskIDs: Set<String> = []
    private var inFlight = 0
    private var sentenceNumber = 0
    private var latestDecision: Decision<Intent>?
    private static let logger = Logger(subsystem: "com.handsfree", category: "HFDecisions")

    /// - Parameters:
    ///   - classifier: usually `Classifiers`.
    ///   - isTaskRunning: true while a task is running or paused waiting for the user.
    ///   - isAwaitingAnswer: true while the assistant waits for the user's reply.
    ///   - cancel: stops the running task (the app passes the runner's cancel, which halts the hands).
    ///   - currentTaskID: the running task's id (nil when none), so a late answer can never cancel a newer task.
    public init(
        classifier: UtteranceClassifying,
        isTaskRunning: @escaping @Sendable () -> Bool,
        isAwaitingAnswer: @escaping @Sendable () -> Bool,
        currentTaskID: @escaping @Sendable () -> String?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.classifier = classifier
        self.isTaskRunning = isTaskRunning
        self.isAwaitingAnswer = isAwaitingAnswer
        self.cancel = cancel
        self.currentTaskID = currentTaskID
    }

    /// The most recent decision, for the panel.
    public var lastDecision: Decision<Intent>? {
        lock.lock()
        defer { lock.unlock() }
        return latestDecision
    }

    /// Call for every user sentence. Returns at once.
    ///
    /// Returns the decision when the local rule decided instantly, or nil when
    /// nothing is running or the classifier's answer will arrive in the background.
    @discardableResult
    public func heard(_ text: String) -> Decision<Intent>? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isTaskRunning() else { return nil }
        let spokenAt = DispatchTime.now().uptimeNanoseconds
        let taskID = currentTaskID()
        let context = UtteranceContext(taskRunning: true, awaitingAnswer: isAwaitingAnswer())
        let number = nextSentenceNumber()

        if let instant = UtteranceRules.instantDecision(text, awaitingAnswer: context.awaitingAnswer) {
            remember(instant)
            if instant.label == .cancel {
                actingQueue.async { self.cancelIfStillRight(number, taskID: taskID, spokenAt: spokenAt, reason: instant.reason) }
            }
            return instant
        }

        beginWork()
        Task.detached(priority: .userInitiated) { [self] in
            let decision = await classifier.classifyUtterance(text, context: context)
            remember(decision)
            Self.logger.info(
                "stop watch #\(number): \(decision.label.rawValue, privacy: .public) (\(decision.source.rawValue, privacy: .public), \(Int(decision.latencyMilliseconds)) ms) \(decision.reason, privacy: .public)")
            if decision.label == .cancel {
                actingQueue.async {
                    self.cancelIfStillRight(number, taskID: taskID, spokenAt: spokenAt, reason: decision.reason)
                    self.endWork()
                }
            } else {
                endWork()
            }
        }
        return nil
    }

    /// Waits until every sentence handed in so far has been dealt with. For tests and shutdown.
    public func waitUntilIdle(timeoutSeconds: Double = 5) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1e9)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            // Drain anything already queued for acting.
            await withCheckedContinuation { continuation in actingQueue.async { continuation.resume() } }
            if !isBusy() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: - Internals

    /// Runs on `actingQueue`. Cancels only if the task that was running when the
    /// sentence was spoken is still the one running, and nobody cancelled since.
    private func cancelIfStillRight(_ number: Int, taskID: String?, spokenAt: UInt64, reason: String) {
        lock.lock()
        let alreadyCancelledSince = lastCancelAt > spokenAt
        let alreadyCancelledThisTask = taskID.map { cancelledTaskIDs.contains($0) } ?? false
        lock.unlock()
        if alreadyCancelledSince || alreadyCancelledThisTask {
            Self.logger.info("stop watch #\(number): already cancelled; skipping")
            return
        }
        guard isTaskRunning() else { return }
        // Only the task that was current when the sentence was heard may be cancelled.
        guard currentTaskID() == taskID else {
            Self.logger.info("stop watch #\(number): a different task is running now; not cancelling it")
            return
        }
        lock.lock()
        lastCancelAt = DispatchTime.now().uptimeNanoseconds
        if let taskID { cancelledTaskIDs.insert(taskID) }
        lock.unlock()
        Self.logger.info("stop watch #\(number): cancelling (\(reason, privacy: .public))")
        cancel()
    }

    private func nextSentenceNumber() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sentenceNumber += 1
        return sentenceNumber
    }

    private func remember(_ decision: Decision<Intent>) {
        lock.lock()
        latestDecision = decision
        lock.unlock()
    }

    private func isBusy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight > 0
    }

    private func beginWork() {
        lock.lock()
        inFlight += 1
        lock.unlock()
    }

    private func endWork() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
}
