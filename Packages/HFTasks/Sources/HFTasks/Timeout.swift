import Foundation

/// Runs `operation` and returns its value, or nil if it has not answered within
/// `seconds`, or if the calling task is cancelled.
///
/// Unlike a task group, this returns on time even when the operation ignores
/// cancellation: the operation runs in its own task and is simply left behind.
/// The gate, the reply classifier and memory all go through this, so none of
/// them can stall a task.
func valueWithin<Value: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    let box = ResolveOnce<Value?>()
    var worker: Task<Void, Never>?
    var timer: Task<Void, Never>?
    let result = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            box.install(continuation)
            worker = Task { box.resolve(await operation()) }
            timer = Task {
                try? await Task.sleep(nanoseconds: nanoseconds(seconds))
                box.resolve(nil)
            }
        }
    } onCancel: {
        box.resolve(nil)
    }
    worker?.cancel()
    timer?.cancel()
    return result
}

func nanoseconds(_ seconds: Double) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
}

/// Resumes a continuation exactly once, whoever gets there first. A value that
/// arrives before the continuation is installed is kept and handed over on install.
final class ResolveOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolvedValue: Value?
    private var isResolved = false

    func install(_ newContinuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if isResolved, let value = resolvedValue {
            lock.unlock()
            newContinuation.resume(returning: value)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    func resolve(_ value: Value) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        resolvedValue = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
