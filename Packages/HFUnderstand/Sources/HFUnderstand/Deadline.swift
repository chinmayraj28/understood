import Foundation

/// The work did not finish in time.
struct DeadlinePassed: Error, Equatable {
    let seconds: Double
}

/// Runs `operation`, but returns (by throwing `DeadlinePassed`) once `seconds` have passed,
/// even if the operation ignores cancellation.
///
/// Why not a task group: a group waits for every child before it returns, so one recogniser
/// that ignores cancellation would hold up the whole turn. Here the slow work is cancelled and
/// left behind; whichever finishes first, the result or the deadline, answers.
func withDeadline<Value: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let gate = AnswerOnce()
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    let value: Value = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.claim() { continuation.resume(throwing: DeadlinePassed(seconds: seconds)) }
            }
            gate.onCancel = { if gate.claim() { continuation.resume(throwing: CancellationError()) } }
        }
    } onCancel: {
        gate.cancel()
    }
    work?.cancel()
    timer?.cancel()
    return value
}

/// Makes sure a continuation is resumed exactly once, whoever gets there first.
private final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private var cancelled = false
    private var cancelHandler: (() -> Void)?

    /// Set inside the continuation; runs at once if the caller was already cancelled.
    var onCancel: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return cancelHandler }
        set {
            lock.lock()
            cancelHandler = newValue
            let runNow = cancelled
            lock.unlock()
            if runNow { newValue?() }
        }
    }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if answered { return false }
        answered = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancelHandler
        lock.unlock()
        handler?()
    }
}
