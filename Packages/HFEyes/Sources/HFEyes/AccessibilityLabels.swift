import CoreGraphics
import Foundation
import HFCore

/// The agent's labels: read-only lookups that say what is under a point and what has focus,
/// as HFCore `UIElementInfo` (a shared role, a human-readable label, the developer identifier).
///
/// The safety gate judges these before every click and every key press that can commit
/// something. The wording it shows is built in HFCore (`ScreenAction`), not here.
///
/// Bounded: every lookup runs on ONE dedicated worker thread and the caller waits at most
/// `timeout`. A lookup that times out returns nil, which the gate treats as an unknown target,
/// never as safe. While a lookup is stuck on the worker past its deadline (an app that does not
/// answer), new lookups are refused at once with nil instead of queueing or starting threads,
/// so a frozen app holds one thread at most however often the agent retries.
///
/// Labels may hold private text (a message bubble's words). Nothing in this package logs them.
public final class AccessibilityLabels: Labels, @unchecked Sendable {
    private let source: AccessibilitySource
    private let worker: LookupWorker
    private let timeout: TimeInterval
    private let controlsTimeout: TimeInterval

    /// - Parameters:
    ///   - source: where the tree comes from. Defaults to the real macOS accessibility API.
    ///     Creating it changes nothing in any app.
    ///   - timeout: wall-clock limit for one lookup. Default 0.4 s.
    ///   - controlsTimeout: wall-clock limit for listing the visible controls. Default 2 s.
    public init(
        source: AccessibilitySource = SystemAccessibilitySource(),
        timeout: TimeInterval = 0.4,
        controlsTimeout: TimeInterval = 2.0
    ) {
        self.source = source
        self.worker = LookupWorker()
        self.timeout = timeout
        self.controlsTimeout = controlsTimeout
    }

    public func element(at point: CGPoint) async -> UIElementInfo? {
        let source = self.source
        let hit = await worker.run(timeout: timeout) { source.hit(at: point) } ?? nil
        guard let hit else { return nil }
        return ControlNamer.info(ControlNamer.target(of: hit), hit: hit)
    }

    public func focusedElement() async -> UIElementInfo? {
        let source = self.source
        let hit = await worker.run(timeout: timeout) { source.focused() } ?? nil
        guard let hit else { return nil }
        return ControlNamer.info(hit.node, hit: hit)
    }

    public func frontmost() async -> (app: String, window: String) {
        let source = self.source
        let front = await worker.run(timeout: timeout) { source.front() }
        return front.map { (ControlNamer.clean($0.app), ControlNamer.clean($0.window)) } ?? ("", "")
    }

    /// The bundle identifier of the app that holds the keyboard: the same app `frontmost()` names,
    /// including a protected prompt that exposes nothing to accessibility. "" when unknown or timed out.
    public func frontmostBundleIdentifier() async -> String {
        let source = self.source
        return await worker.run(timeout: timeout) { source.frontBundleIdentifier() } ?? ""
    }

    public func visibleControls(limit: Int) async -> [UIElementInfo] {
        let source = self.source
        let hits = await worker.run(timeout: controlsTimeout) { source.controls(limit: limit) } ?? []
        return hits.map { ControlNamer.info($0.node, hit: $0) }
    }

    /// Asks Chrome-family browsers and Electron apps to expose their web pages, so web buttons can be
    /// named. A write to other apps: the app calls it once at start-up (this runs on a background
    /// thread, never the caller's) and calls `restoreWebContentSwitches()` at quit. Returns "App: switch" per app.
    public func enableWebContent() async -> [String] {
        let source = self.source
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: source.enableWebContent()) }
        }
    }

    /// Switches off what `enableWebContent()` switched on, leaving the user's apps as they were.
    @discardableResult
    public func restoreWebContentSwitches() -> [String] { source.restoreWebContentSwitches() }
}

/// One serial worker for blocking accessibility calls, with a deadline per call.
///
/// Lookups queue on one thread. If a lookup is still running after its deadline (an app that
/// does not answer), the worker counts as stuck and every new lookup returns nil at once,
/// without queueing, until the stuck one comes back. A hard cap also bounds the queue.
final class LookupWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.handsfree.HFEyes.lookups", qos: .userInitiated)
    private let lock = NSLock()
    private var queued = 0  // submitted and not yet finished
    private var stuck = 0  // finished their deadline before their work: still on the worker
    let maximumQueued: Int

    init(maximumQueued: Int = 8) { self.maximumQueued = maximumQueued }

    /// Runs `work` on the worker and waits at most `timeout`. Nil on timeout, or at once while the
    /// worker is stuck on an earlier lookup or too much is already waiting.
    func run<Value>(timeout: TimeInterval, _ work: @escaping @Sendable () -> Value) async -> Value? {
        guard reserve() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let call = Call()  // which came first, the answer or the deadline; guarded by `lock`
            queue.async {
                let value = work()
                self.lock.lock()
                self.queued -= 1
                let answeredInTime = !call.timedOut
                if call.timedOut { self.stuck -= 1 } else { call.answered = true }
                self.lock.unlock()
                if answeredInTime { continuation.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lock.lock()
                let late = !call.answered
                if late {
                    call.timedOut = true
                    self.stuck += 1
                }
                self.lock.unlock()
                if late { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Call: @unchecked Sendable {
        var answered = false
        var timedOut = false
    }

    /// Lookups queued or running, and how many of them are past their deadline. For tests.
    var counts: (queued: Int, stuck: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (queued, stuck)
    }

    private func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stuck == 0, queued < maximumQueued else { return false }
        queued += 1
        return true
    }
}
