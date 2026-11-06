import CoreGraphics
import Foundation
import HFCore
import HFTasks
import Testing

// The rig wires the packages together the way the app's composition root will:
// TaskRunner + TaskTools, the hands' halt and resume as the runner's hooks, one
// ActivityBus shared by everyone. Each collaborator is the real package type
// where it exists, and a fake from this file where it does not yet.

// MARK: - Recording helpers

/// A thread-safe list.
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

func secondsSince(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Everything posted to one ActivityBus, in order. Subscribes synchronously, so
/// nothing posted after `init` is missed.
final class ActivityLog: @unchecked Sendable {
    let bus = ActivityBus()
    private let log = Log<ActivityEvent>()
    private var listener: Task<Void, Never>?

    init() {
        let stream = bus.events()
        let log = self.log
        listener = Task { for await event in stream { log.append(event) } }
    }
    deinit { listener?.cancel() }

    var events: [ActivityEvent] { log.items }

    func waitFor(timeout: Double = 2, _ predicate: @escaping (ActivityEvent) -> Bool) async -> Bool {
        await waitUntil(timeout: timeout) { self.events.contains(where: predicate) }
    }

    /// The events with the noisy hand positions reduced to names, for comparing sequences.
    var names: [String] {
        events.map { event in
            switch event {
            case .taskStarted: "taskStarted"
            case .progress(let text): "progress: \(text)"
            case .waitingForAnswer(let question): "waitingForAnswer: \(question)"
            case .heldForConfirmation(let action): "heldForConfirmation: \(action)"
            case .taskEnded(let status, _): "taskEnded: \(status.rawValue)"
            case .halted: "halted"
            case .pointerMoving: "pointerMoving"
            case .clicked: "clicked"
            case .typing: "typing"
            case .scrolled: "scrolled"
            default: "\(event)"
            }
        }
    }
}

/// The task events the voice session would receive.
final class EventRecorder: @unchecked Sendable {
    private let log = Log<TaskEvent>()
    var sink: TaskEventSink { { [log] event in log.append(event) } }
    var events: [TaskEvent] { log.items }
    var lines: [String] { events.map { "\($0.kind.rawValue)/\($0.status.rawValue)/\($0.text)" } }

    func waitFor(_ kind: TaskEventKind, number: Int = 1, timeout: Double = 2) async -> TaskEvent? {
        let found = await waitUntil(timeout: timeout) { self.events.filter { $0.kind == kind }.count >= number }
        return found ? events.filter { $0.kind == kind }[number - 1] : nil
    }
}

// MARK: - Fakes that stand in for packages not wired in yet

/// Hands that act on nothing, but glide in small steps and check the halt flag
/// between them, like the real ones. Posts the same activity the real hands post.
final class FakeHands: Hands, @unchecked Sendable {
    private let lock = NSLock()
    private var halted = false
    private var position = CGPoint.zero
    let actions = Log<String>()
    let bus: ActivityBus
    /// Called after each recorded action, so a test can change the world at an exact moment
    /// (an updater popping up between two key presses). Set it before the task starts.
    var afterAction: (@Sendable (String) -> Void)?

    private func record(_ action: String) {
        actions.append(action)
        afterAction?(action)
    }
    /// Size of one glide step. The real hands check the flag every few milliseconds.
    let stepSeconds = 0.005

    init(bus: ActivityBus) { self.bus = bus }

    func halt() { lock.lock(); halted = true; lock.unlock(); actions.append("halt") }
    func resume() { lock.lock(); halted = false; lock.unlock(); actions.append("resume") }
    var isHalted: Bool { lock.lock(); defer { lock.unlock() }; return halted }
    var pointerPosition: CGPoint { lock.lock(); defer { lock.unlock() }; return position }

    private func checkHalt() throws { if isHalted { throw Halted() } }

    func move(to point: CGPoint, duration: TimeInterval?) async throws {
        try checkHalt()
        let total = duration ?? 0.02
        bus.post(.pointerMoving(to: point, duration: total))
        var waited = 0.0
        while waited < total {
            try await sleepIgnoringCancellation(stepSeconds)  // the flag, not Swift cancellation, stops the hands
            try checkHalt()
            waited += stepSeconds
        }
        setPosition(point)
    }

    private func setPosition(_ point: CGPoint) { lock.lock(); position = point; lock.unlock() }

    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {
        try await move(to: point, duration: nil)
        try checkHalt()
        record("click \(Int(point.x)),\(Int(point.y))")
        bus.post(.clicked(at: point))
    }

    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws {
        try await move(to: start, duration: nil)
        try await move(to: end, duration: duration)
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws {
        try checkHalt()
        record("scroll \(dx),\(dy)")
        bus.post(.scrolled)
    }

    func key(_ combo: String) async throws {
        try checkHalt()
        record("key \(combo)")
    }

    func typeText(_ text: String, allowReturn: Bool) async throws {
        if !allowReturn, text.contains("\n") { throw SpeakableError("That text has a line break, which would send it.") }
        bus.post(.typing)
        for character in text {
            try checkHalt()
            _ = character
            try await sleepIgnoringCancellation(0.001)
        }
        record("type \(text)")
    }
}

func sleepIgnoringCancellation(_ seconds: Double) async throws {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// Stands in for HFDecisions' SafetyGate: a control whose words include send, save,
/// invite, delete or pay needs a yes, and so does anything it cannot see.
struct KeywordGate: SafetyGating {
    func check(_ action: ScreenAction) async -> Decision<Risk> {
        guard let target = action.target else { return Decision(label: .needsConfirmation, confidence: 1, source: .rule) }
        let risky = !Set(target.words).isDisjoint(with: ["send", "save", "invite", "delete", "pay"])
        return Decision(label: risky ? .needsConfirmation : .safe, confidence: 1, source: .keywords)
    }
}

// MARK: - The scripted executor: BUILD_PLAN 4b on the screen

/// Plays "Set up a Google Meet with Priya tomorrow at 3 and invite her" the way
/// the screen agent will: report, ask which Priya, click and type into the
/// guests field (safe), then hold the Send click for a spoken yes.
struct InviteFlowExecutor: TaskExecuting {
    let hands: any Hands
    let gliding: Double  // how long the final glide to Send takes
    static let guestsField = CGPoint(x: 400, y: 300)
    static let sendButton = CGPoint(x: 900, y: 120)
    static let window = "Google Calendar - Invite guests"
    static let guestsAction = ScreenAction(kind: .click, target: UIElementInfo(
        role: .textField, label: "Add guests", app: "Google Chrome", window: window,
        frame: CGRect(x: 300, y: 280, width: 200, height: 40)))
    static let sendAction = ScreenAction(kind: .click, target: UIElementInfo(
        role: .button, label: "Send", app: "Google Chrome", window: window,
        frame: CGRect(x: 870, y: 105, width: 60, height: 30)))
    static let sendQuestion = "Send the invite to Priya Shah for tomorrow at 3pm?"

    init(hands: any Hands, gliding: Double = 0.02) {
        self.hands = hands
        self.gliding = gliding
    }

    func run(goal: String, context: TaskContext) async throws -> String {
        context.report("Opening Google Calendar")
        try context.step()
        let who = try await context.askUser("Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])
        try context.step()
        guard try await context.confirm(Self.guestsAction, spokenQuestion: nil) else {
            return "I stopped before adding the guest."
        }
        try await hands.click(at: Self.guestsField)
        try await hands.typeText(who)
        try context.step()
        let question = Self.sendQuestion.replacingOccurrences(of: "Priya Shah", with: who)
        guard try await context.confirm(Self.sendAction, spokenQuestion: question) else {
            return "I didn't send the invite."
        }
        try await hands.move(to: Self.sendButton, duration: gliding)
        try await hands.click(at: Self.sendButton)
        return "Sent the invite to \(who)."
    }
}

// MARK: - The rig

/// The app's wiring, in miniature.
final class Rig: @unchecked Sendable {
    let activity: ActivityLog
    let recorder = EventRecorder()
    let hands: FakeHands
    let runner: TaskRunner
    let tools: [String: ToolSpec]

    /// - Parameter activity: the bus to share with other parts (the voice session, the listening
    ///   cycle), as the app shares one. A fresh one by default.
    init(
        activity: ActivityLog? = nil,
        gate: any SafetyGating = KeywordGate(),
        classifier: (any AnswerClassifying)? = nil,
        memory: (any MemoryProviding)? = nil,
        configure: (inout TaskRunner.Configuration) -> Void = { _ in },
        alsoSendEventsTo extraSink: TaskEventSink? = nil,
        executor: (FakeHands) -> any TaskExecuting
    ) {
        let activity = activity ?? ActivityLog()
        self.activity = activity
        hands = FakeHands(bus: activity.bus)
        var configuration = TaskRunner.Configuration()
        configuration.tick = 0.01
        configuration.cancelGrace = 0.2
        configuration.progressInterval = 0
        configure(&configuration)
        let hands = self.hands
        runner = TaskRunner(
            executor: executor(hands), gate: gate, answerClassifier: classifier, memory: memory,
            sink: { [sink = recorder.sink] event in sink(event); extraSink?(event) }, configuration: configuration,
            onCancel: { hands.halt() },
            onTaskEnd: { _, _ in hands.resume() },
            activityBus: activity.bus)
        tools = Dictionary(uniqueKeysWithValues: TaskTools.make(runner: runner).map { ($0.name, $0) })
    }

    deinit { runner.shutdown() }

    /// Calls a voice tool the way the voice session will.
    @discardableResult
    func call(_ tool: String, _ parameters: JSONObject = [:]) async -> JSONObject {
        guard let spec = tools[tool] else {
            Issue.record("no tool named \(tool)")
            return [:]
        }
        let result = await spec.handler(parameters)
        // The voice session sends results to ElevenLabs as JSON, so they must encode.
        #expect((try? JSONEncoder().encode(result)) != nil, "\(tool) result must be JSON")
        return result
    }
}

extension JSONObject {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    var isOK: Bool { self["ok"]?.boolValue == true }
}

/// An executor that runs a different script for each task, in order.
final class ScriptedFlow: TaskExecuting, @unchecked Sendable {
    typealias Script = @Sendable (TaskContext) async throws -> String
    private let lock = NSLock()
    private var scripts: [Script]
    init(_ first: @escaping Script, then rest: Script...) { scripts = [first] + rest }
    private func nextScript() -> Script? {
        lock.lock()
        defer { lock.unlock() }
        return scripts.isEmpty ? nil : scripts.removeFirst()
    }
    func run(goal: String, context: TaskContext) async throws -> String {
        guard let script = nextScript() else { return "Nothing scripted." }
        return try await script(context)
    }
}

extension Rig {
    /// `start_task` from synchronous code; true if a task started.
    func call_sync_start(_ goal: String) -> Bool { runner.start(goal: goal).isOK }
}
