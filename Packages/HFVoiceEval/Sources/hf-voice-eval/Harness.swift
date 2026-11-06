import CoreGraphics
import Foundation
import HFCore
import HFDecisions
import HFHands
import HFMemory
import HFTasks
import HFVoice

// Runs one labelled conversation through the real voice session (text mode, real ElevenLabs
// agent), with the app's real tool definitions. Quick tools record and return a plausible result
// without touching the Mac; memory tools are real, on a scratch database; task tools are the real
// TaskRunner with a scripted executor, so its questions, confirmations and results reach the
// agent exactly as in the app (`VoiceSession.push`, as `[APP]` messages).

/// Hands that do nothing: only used to build the quick tools' definitions.
struct NoHands: Hands {
    func halt() {}
    func resume() {}
    var isHalted: Bool { false }
    var pointerPosition: CGPoint { .zero }
    func move(to point: CGPoint, duration: TimeInterval?) async throws {}
    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {}
    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws {}
    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws {}
    func key(_ combo: String) async throws {}
    func typeText(_ text: String, allowReturn: Bool) async throws {}
}

/// A list any thread can append to.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CaseResult.Event] = []
    private var lastAt: Double = 0
    let start = ProcessInfo.processInfo.systemUptime
    var now: Double { ProcessInfo.processInfo.systemUptime - start }

    func add(_ kind: String, _ text: String) {
        lock.withLock {
            let at = ProcessInfo.processInfo.systemUptime - start
            events.append(.init(at: at, kind: kind, text: text))
            lastAt = at
        }
    }
    var all: [CaseResult.Event] { lock.withLock { events } }
    var lastEventAt: Double { lock.withLock { lastAt } }
}

/// The task the screen agent would do, scripted per case.
struct ScriptedTask: TaskExecuting {
    let script: EvalCase.TaskScript
    let recorder: Recorder

    static let sendAction = ScreenAction(kind: .click, target: UIElementInfo(
        role: .button, label: "Send", app: "WhatsApp", window: "WhatsApp",
        frame: CGRect(x: 900, y: 700, width: 40, height: 40)))

    func run(goal: String, context: TaskContext) async throws -> String {
        let delay = script.delay ?? 3
        func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        switch script.kind {
        case "question":
            try await pause(delay)
            let answer = try await context.askUser(script.question ?? "Which one?", options: script.options ?? [])
            try await pause(1)
            return (script.summary ?? "Done.").replacingOccurrences(of: "{answer}", with: answer)
        case "confirm":
            try await pause(delay)
            guard try await context.confirm(Self.sendAction, spokenQuestion: script.question) else {
                return "I didn't send it."
            }
            try await pause(1)
            return script.summary ?? "Sent."
        case "fails":
            try await pause(delay)
            throw SpeakableError(script.summary ?? "I couldn't find that on the screen.")
        case "long":
            context.report("Working on it")
            while true { try await pause(0.05) }
        default:  // done
            try await pause(delay)
            return script.summary ?? "Done."
        }
    }
}

@MainActor
struct Harness {
    let settings: Settings
    let configuration: AgentConfiguration
    let quiet: Double  // seconds without news that end a turn
    let longest: Double  // the most a turn may take

    /// The app's tool definitions, with handlers that need nothing real. Used for the agent update.
    static func definitions() -> [ToolSpec] {
        let store = try! MemoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hf-eval-defs-\(UUID()).db"))
        let runner = TaskRunner(executor: ScriptedTask(script: .init(kind: "done", delay: 0, summary: nil, question: nil, options: nil), recorder: Recorder()),
                                gate: SafetyGate(classifier: Classifiers(client: nil)), sink: { _ in })
        return QuickTools.make(hands: NoHands()) + MemoryTools.make(memory: Memory(store: store)) + TaskTools.make(runner: runner)
            + [SleepTool.make(isTaskActive: { false }, requestSleep: { .goingToSleep })]
    }

    func run(_ testCase: EvalCase) async -> CaseResult {
        let recorder = Recorder()
        let bus = ActivityBus()
        let session = VoiceSession(
            settings: settings, mode: .text, bus: bus, configuration: configuration, syncAgentOnStart: false)

        // Tasks: the real runner, the case's script as the executor, its events spoken through the session.
        let script = testCase.task ?? .init(kind: "done", delay: 3, summary: "Done.", question: nil, options: nil)
        let classifiers = Classifiers(client: nil)
        let runner = TaskRunner(
            executor: ScriptedTask(script: script, recorder: recorder),
            gate: SafetyGate(classifier: classifiers), answerClassifier: classifiers,
            sink: { event in
                if event.kind != .progress { recorder.add("push", "\(event.kind.rawValue): \(event.text)") }
                session.push(event)
            },
            activityBus: bus)
        let watcher = StopWatcher(
            classifier: classifiers, isTaskRunning: { runner.isRunning }, isAwaitingAnswer: { runner.isAwaitingAnswer },
            currentTaskID: { runner.status()["task_id"]?.stringValue }, cancel: { _ = runner.cancel(taskID: nil) })

        let store = try! MemoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("hf-eval-\(UUID()).db"))
        var tools = QuickTools.make(hands: NoHands()).map { stub($0, testCase: testCase, recorder: recorder) }
        tools += MemoryTools.make(memory: Memory(store: store)).map { wrap($0, testCase: testCase, recorder: recorder) }
        tools += TaskTools.make(runner: runner).map { wrap($0, testCase: testCase, recorder: recorder) }
        tools.append(wrap(SleepTool.make(
            isTaskActive: { runner.isRunning || runner.isAwaitingAnswer },
            requestSleep: { .goingToSleep }), testCase: testCase, recorder: recorder))

        session.addReplyListener { text in recorder.add("agent", text) }
        session.prepare(tools: tools, memorySummary: testCase.memory ?? "Nothing yet.") { sentence in watcher.heard(sentence) }

        var timings: [CaseResult.Timing] = []
        let first = testCase.firstUtterance ?? ""
        if !first.isEmpty { recorder.add("user", first + "  (with the wake phrase)") }
        let sentAt = recorder.now
        await session.open(firstUtterance: first)
        guard await session.waitUntilConnected(timeout: 20) else {
            await session.close()
            runner.shutdown()
            return CaseResult(id: testCase.id, category: testCase.category, passed: false,
                              failures: ["could not connect"], events: recorder.all, timings: [], replies: [], calls: [])
        }
        recorder.add("note", "connected")
        if !first.isEmpty {
            await settle(recorder: recorder, runner: runner, session: session, longTask: script.kind == "long")
            timings.append(timing(for: first, sentAt: sentAt, events: recorder.all))
        }

        for turn in testCase.turns {
            switch turn {
            case .wait(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            case .say(let text):
                recorder.add("user", text)
                let sentAt = recorder.now
                do { try await session.sendText(text) } catch { recorder.add("note", "not sent: \(error)") }
                await settle(recorder: recorder, runner: runner, session: session, longTask: script.kind == "long")
                timings.append(timing(for: text, sentAt: sentAt, events: recorder.all))
            }
        }
        await session.close()
        runner.shutdown()

        let events = recorder.all
        var result = CaseResult(
            id: testCase.id, category: testCase.category, passed: true, failures: [], events: events, timings: timings,
            replies: events.filter { $0.kind == "agent" }.map(\.text),
            calls: events.filter { $0.kind == "tool" }.map(\.text))
        result.failures = Scoring.failures(testCase, events: events)
        result.passed = result.failures.isEmpty
        return result
    }

    /// Waits until nothing has happened for `quiet` seconds, no task is about to report, and no
    /// task news is still waiting in the session's queue to be said.
    private func settle(recorder: Recorder, runner: TaskRunner, session: VoiceSession, longTask: Bool) async {
        let began = recorder.now
        var newsWaiting = false
        while recorder.now - began < longest {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let idleFor = recorder.now - recorder.lastEventAt
            let taskBusy = runner.isRunning && !runner.isAwaitingAnswer && !longTask
            let unspoken = session.activity.hasUnspokenNews
            if unspoken && !newsWaiting { newsWaiting = true }
            if !unspoken && newsWaiting {
                newsWaiting = false
                recorder.add("note", "queued news sent")
            }
            if idleFor >= quiet && !taskBusy && !unspoken { return }
        }
        recorder.add("note", "turn still busy after \(Int(longest)) s")
    }

    private func timing(for turn: String, sentAt: Double, events: [CaseResult.Event]) -> CaseResult.Timing {
        let after = events.filter { $0.at >= sentAt }
        let words = after.first { $0.kind == "agent" }.map { $0.at - sentAt }
        let call = after.first { $0.kind == "tool" }.map { $0.at - sentAt }
        return .init(turn: turn, firstWords: words, toolCall: call)
    }

    // MARK: Tools

    /// A quick tool that records the call and returns a plausible result, touching nothing.
    private func stub(_ spec: ToolSpec, testCase: EvalCase, recorder: Recorder) -> ToolSpec {
        ToolSpec(name: spec.name, description: spec.description, parameters: spec.parameters, tier: spec.tier,
                 timeoutSeconds: spec.timeoutSeconds) { parameters in
            recorder.add("tool", "\(spec.name) \(Self.describe(parameters))")
            let result = Self.stubResult(spec.name, parameters, override: testCase.toolResults?[spec.name])
            recorder.add("result", "\(spec.name) → \(Self.describe(result))")
            return result
        }
    }

    /// A real tool, with its calls and results recorded.
    private func wrap(_ spec: ToolSpec, testCase: EvalCase, recorder: Recorder) -> ToolSpec {
        ToolSpec(name: spec.name, description: spec.description, parameters: spec.parameters, tier: spec.tier,
                 timeoutSeconds: spec.timeoutSeconds) { parameters in
            recorder.add("tool", "\(spec.name) \(Self.describe(parameters))")
            let result: JSONObject
            if let override = testCase.toolResults?[spec.name] {
                result = Self.stubResult(spec.name, parameters, override: override)
            } else {
                result = await spec.handler(parameters)
            }
            recorder.add("result", "\(spec.name) → \(Self.describe(result))")
            return result
        }
    }

    nonisolated static func stubResult(_ name: String, _ parameters: JSONObject, override: EvalCase.StubResult?) -> JSONObject {
        if let error = override?.error { return ToolResult.failure(error) }
        if let fields = override?.fields { return ToolResult.ok(fields.mapValues { .string($0) }) }
        let value = { (key: String) in parameters[key]?.stringValue ?? parameters[key].map { "\($0)" } ?? "" }
        switch name {
        case "set_volume": return ToolResult.ok(["volume_percent": .number(Double(value("percent")) ?? 40), "muted": false])
        case "set_brightness": return ToolResult.ok(["brightness_percent": .number(Double(value("percent")) ?? 60)])
        case "media_control": return ToolResult.ok(["pressed": .string(value("action"))])
        case "scroll": return ToolResult.ok(["scrolled": .string(value("direction"))])
        case "open_app": return ToolResult.ok(["app": .string(value("name")), "in_front": true])
        case "open_url": return ToolResult.ok(["opened": .string(value("url")), "browser": "Google Chrome", "in_front": true])
        case "where_am_i": return ToolResult.ok(["front_app": "Google Chrome", "window": "YouTube", "other_apps": ["Mail", "WhatsApp"]])
        case "read_text": return ToolResult.ok(["text": "Your order has shipped and will arrive on Friday."])
        case "take_screenshot": return ToolResult.ok(["saved_to": "Desktop"])
        default: return ToolResult.ok([:])
        }
    }

    nonisolated static func describe(_ object: JSONObject) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(object)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
