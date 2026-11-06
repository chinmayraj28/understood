import Foundation
import HFCore
import Testing

@testable import HFTasks

// Small fakes and helpers shared by the tests. No network, no real apps.

/// A sink that remembers every event and the queue it arrived on.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TaskEvent] = []
    private var queueLabels: Set<String> = []
    var delay: TimeInterval = 0

    var sink: TaskEventSink {
        { [self] event in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let label = String(cString: __dispatch_queue_get_label(nil))
            lock.lock()
            recorded.append(event)
            queueLabels.insert(label)
            lock.unlock()
        }
    }

    var events: [TaskEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
    var labels: Set<String> { lock.lock(); defer { lock.unlock() }; return queueLabels }
    func count(_ kind: TaskEventKind) -> Int { events.filter { $0.kind == kind }.count }

    /// Waits for the first event matching `predicate`.
    func waitFor(
        timeout: Double = 2, _ predicate: @escaping (TaskEvent) -> Bool
    ) async -> TaskEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = events.first(where: predicate) { return event }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return events.first(where: predicate)
    }

    func waitFor(_ kind: TaskEventKind, timeout: Double = 2) async -> TaskEvent? {
        await waitFor(timeout: timeout) { $0.kind == kind }
    }

    /// Waits for the n-th event of a kind (1-based).
    func waitFor(_ kind: TaskEventKind, number: Int, timeout: Double = 2) async -> TaskEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = events.filter { $0.kind == kind }
            if matching.count >= number { return matching[number - 1] }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }
}

/// A clock the test moves by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double = 1000
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: Double) { lock.lock(); current += seconds; lock.unlock() }
    var function: @Sendable () -> TimeInterval { { [self] in now() } }
}

/// A thread-safe true/false flag.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func wait(timeout: Double = 2) async -> Bool {
        await waitUntil(timeout: timeout) { self.isSet }
    }
}

/// A thread-safe list, for recording calls.
final class Log<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Item] = []
    func append(_ item: Item) { lock.lock(); stored.append(item); lock.unlock() }
    var items: [Item] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Polls a condition every 2 ms. Returns whether it became true in time.
func waitUntil(timeout: Double = 2, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

/// Blocks the calling thread, the way a badly written executor would hold its thread.
func blockThread(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

/// Sleeps for real time, ignoring Swift task cancellation, the way a badly
/// written executor would.
func uncancellableSleep(_ seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// Anything mentioning send, delete or pay needs a yes; everything else is safe.
final class FakeGate: SafetyGating, @unchecked Sendable {
    let checked = Log<String>()
    let hangs: Bool
    init(hangs: Bool = false) { self.hangs = hangs }

    func check(_ action: ScreenAction) async -> Decision<Risk> {
        let actionDescription = action.description
        checked.append(actionDescription)
        if hangs { await uncancellableSleep(5) }
        let lowered = actionDescription.lowercased()
        let risky = ["send", "delete", "pay"].contains { lowered.contains($0) }
        return Decision(label: risky ? .needsConfirmation : .safe, confidence: 0.99, source: .rule)
    }
}

/// An answer classifier that always gives the same label, or hangs.
struct FakeClassifier: AnswerClassifying {
    var label: Answer
    var hangs = false
    func classifyAnswer(_ answer: String, question: String) async -> Decision<Answer> {
        if hangs { await uncancellableSleep(5) }
        return Decision(label: label, confidence: 0.97, source: .jev)
    }
}

/// Memory that records what it is told.
final class FakeMemory: MemoryProviding, @unchecked Sendable {
    let hintText: String
    let slowSeconds: Double
    let learned = Log<[String]>()
    let ended = Log<String>()
    let endedSteps = Log<[String]>()
    init(hints: String = "- alias priya: Priya Shah (in calendar)", slowSeconds: Double = 0) {
        self.hintText = hints
        self.slowSeconds = slowSeconds
    }
    func hints(forGoal goal: String) async -> String {
        if slowSeconds > 0 { await uncancellableSleep(slowSeconds) }
        return hintText
    }
    func summaryForPrompt(maxCharacters: Int) async -> String { "" }
    func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async {
        learned.append([question, answer, goal])
    }
    func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async {
        ended.append("\(goal)|\(status.rawValue)|\(summary)")
        endedSteps.append(steps)
    }
}

/// An executor written as a closure, so each test can say exactly what it does.
struct ScriptedExecutor: TaskExecuting {
    let body: @Sendable (String, TaskContext) async throws -> String
    init(_ body: @escaping @Sendable (String, TaskContext) async throws -> String) { self.body = body }
    func run(goal: String, context: TaskContext) async throws -> String { try await body(goal, context) }
}

/// A click on a button with this label, as the screen agent would describe it.
func clickAction(_ label: String, app: String = "Google Calendar", window: String = "") -> ScreenAction {
    ScreenAction(kind: .click, target: UIElementInfo(role: .button, label: label, app: app, window: window, frame: .zero))
}

/// Short timings so tests are fast. Progress is not rate-limited unless a test asks.
func testConfiguration(_ adjust: (inout TaskRunner.Configuration) -> Void = { _ in }) -> TaskRunner.Configuration {
    var configuration = TaskRunner.Configuration()
    configuration.tick = 0.01
    configuration.cancelGrace = 0.1
    configuration.progressInterval = 0
    configuration.gateTimeout = 0.2
    configuration.classifyTimeout = 0.2
    configuration.memoryTimeout = 0.2
    adjust(&configuration)
    return configuration
}

/// A runner wired to fakes. Remember to call `shutdown()`.
func makeRunner(
    _ executor: any TaskExecuting,
    gate: any SafetyGating = FakeGate(),
    classifier: (any AnswerClassifying)? = nil,
    memory: (any MemoryProviding)? = nil,
    recorder: EventRecorder = EventRecorder(),
    clock: FakeClock? = nil,
    activityBus: ActivityBus = ActivityBus(),
    configure: (inout TaskRunner.Configuration) -> Void = { _ in },
    onCancel: (@Sendable () -> Void)? = nil,
    onTaskEnd: (@Sendable (String, TaskStatus) -> Void)? = nil
) -> (TaskRunner, EventRecorder) {
    let runner = TaskRunner(
        executor: executor, gate: gate, answerClassifier: classifier, memory: memory, sink: recorder.sink,
        configuration: testConfiguration(configure), onCancel: onCancel, onTaskEnd: onTaskEnd,
        activityBus: activityBus, clock: clock?.function ?? { @Sendable in ProcessInfo.processInfo.systemUptime })
    return (runner, recorder)
}

extension JSONObject {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    var isOK: Bool { self["ok"]?.boolValue == true }
}

func elapsed(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - Executors used by several tests

/// BUILD_PLAN 4b: asks which Priya, then asks before sending the invite.
final class InviteExecutor: TaskExecuting, @unchecked Sendable {
    let sent = Flag()
    let cleanedUp = Flag()
    let confirmResult = Log<Bool>()

    func run(goal: String, context: TaskContext) async throws -> String {
        defer { cleanedUp.set() }
        context.report("Opening Google Calendar")
        try context.step()
        let who = try await context.askUser("Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])
        try context.step()
        let confirmed = try await context.confirm(
            clickAction("Send", window: "Invite \(who)"), spokenQuestion: nil)
        confirmResult.append(confirmed)
        guard confirmed else { return "I didn't send the invite." }
        sent.set()
        return "Sent the invite to \(who)."
    }
}

/// Runs until cancelled and cleans up properly.
final class ForeverExecutor: TaskExecuting, @unchecked Sendable {
    let askFirst: Bool
    let started = Flag()
    let cleanedUp = Flag()
    let sawCancellation = Flag()
    let answers = Log<String>()
    init(askFirst: Bool = false) { self.askFirst = askFirst }

    func run(goal: String, context: TaskContext) async throws -> String {
        defer { cleanedUp.set() }
        return try await withTaskCancellationHandler {
            context.report("Opening Chrome")
            if askFirst { answers.append(try await context.askUser("Work or personal account?", options: [])) }
            started.set()
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        } onCancel: {
            sawCancellation.set()
        }
    }
}

/// Ignores cancellation entirely; after it is stopped it tries to get a yes.
final class StubbornExecutor: TaskExecuting, @unchecked Sendable {
    let started = Flag()
    let release = Flag()
    let lateConfirm = Log<String>()

    func run(goal: String, context: TaskContext) async throws -> String {
        started.set()
        while !release.isSet {
            await uncancellableSleep(0.005)
            if Task.isCancelled, lateConfirm.items.isEmpty {
                do {
                    let approved = try await context.confirm(clickAction("Send the message to everyone"), spokenQuestion: nil)
                    lateConfirm.append(approved ? "approved" : "declined")
                } catch {
                    lateConfirm.append("refused")
                }
            }
        }
        return "finished anyway"
    }
}

/// Only asks for one confirmation.
final class ConfirmOnlyExecutor: TaskExecuting, @unchecked Sendable {
    let action: ScreenAction
    let spokenQuestion: String?
    let results = Log<Bool>()
    let lastAnswers = Log<String>()
    /// Clicks a button with this label.
    convenience init(_ buttonLabel: String = "Send the message to Mum", spokenQuestion: String? = nil) {
        self.init(action: clickAction(buttonLabel), spokenQuestion: spokenQuestion)
    }
    init(action: ScreenAction, spokenQuestion: String? = nil) {
        self.action = action
        self.spokenQuestion = spokenQuestion
    }
    func run(goal: String, context: TaskContext) async throws -> String {
        let approved = try await context.confirm(action, spokenQuestion: spokenQuestion)
        results.append(approved)
        if let runnerContext = context as? RunnerTaskContext { lastAnswers.append(runnerContext.lastAnswer) }
        return approved ? "Sent." : "Not sent."
    }
}
