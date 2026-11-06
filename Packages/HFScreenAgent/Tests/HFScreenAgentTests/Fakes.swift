import AppKit
import CoreGraphics
import Foundation
import HFCore
@testable import HFScreenAgent

// Test doubles for everything the screen agent talks to. None of them touches
// the network, the real screen, the pointer or the keyboard.

/// Records what the hands were asked to do.
final class FakeHands: Hands, @unchecked Sendable {
    enum Call: Equatable {
        case move(CGPoint)
        case click(CGPoint, MouseButton, Int, [KeyModifier])
        case drag(CGPoint, CGPoint)
        case scroll(Int, Int, CGPoint?)
        case key(String)
        case type(String, Bool)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _halted = false
    private(set) var haltCount = 0
    private(set) var resumeCount = 0
    /// Makes every action take this long, checking the halt flag as it goes, like the real hands.
    var actionSeconds: Double = 0
    /// When set, every action throws this.
    var failure: Error?
    /// Called when a glide finishes, so a test can change what is under the pointer.
    var onMove: ((CGPoint) -> Void)?
    /// Called after a key press, so a test can move focus the way the real app would.
    var onKey: ((String) -> Void)?
    /// Called after typing, so a test can make another window grab focus.
    var onType: ((String) -> Void)?

    var calls: [Call] { lock.withLock { _calls } }
    /// Everything except glides: the clicks, keys, typing and scrolls.
    var presses: [Call] { calls.filter { if case .move = $0 { return false } else { return true } } }
    var isHalted: Bool { lock.withLock { _halted } }
    var pointerPosition: CGPoint { CGPoint(x: 10, y: 10) }

    func halt() { lock.withLock { _halted = true; haltCount += 1 } }
    func resume() { lock.withLock { _halted = false; resumeCount += 1 } }

    private func perform(_ call: Call) async throws {
        if let failure { throw failure }
        let steps = Int(actionSeconds / 0.01)
        for _ in 0..<steps {
            if isHalted { throw Halted() }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if isHalted { throw Halted() }
        lock.withLock { _calls.append(call) }
    }

    func move(to point: CGPoint, duration: TimeInterval?) async throws {
        try await perform(.move(point))
        onMove?(point)
    }
    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {
        try await perform(.click(point, button, count, modifiers))
    }
    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws { try await perform(.drag(start, end)) }
    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws { try await perform(.scroll(dx, dy, point)) }
    func key(_ combo: String) async throws {
        try await perform(.key(combo))
        onKey?(combo)
    }
    func typeText(_ text: String, allowReturn: Bool) async throws {
        if text.contains(where: \.isNewline) && !allowReturn { throw SpeakableError("newline refused") }
        try await perform(.type(text, allowReturn))
        onType?(text)
    }
}

/// A screen of 1440x900 points shown as a 1280x800 image (a 16:10 Mac).
final class FakeEyes: Eyes, @unchecked Sendable {
    let screenSize = CGSize(width: 1440, height: 900)
    var failure: Error?
    private(set) var grabCount = 0

    func grab(maxLongEdge: Int) async throws -> Shot {
        if let failure { throw failure }
        grabCount += 1
        return Shot(png: Data([0x89, 0x50, 0x4E, 0x47]), pixelWidth: 1280, pixelHeight: 800,
                    screenRect: CGRect(origin: .zero, size: screenSize))
    }

    func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot {
        Shot(png: Data([0x89, 0x50]), pixelWidth: 640, pixelHeight: 400, screenRect: region)
    }
}

/// Names whatever is at a point, from a list of rectangles in screen points.
final class FakeLabels: Labels, @unchecked Sendable {
    var controls: [(rect: CGRect, element: UIElementInfo)] = []
    var front = (app: "WhatsApp", window: "Amma")
    /// The front app's bundle identifier, so protected-window tests use the identifier path.
    var frontBundleIdentifier = "net.whatsapp.WhatsApp"
    /// What has keyboard focus. Nil means it cannot be found out.
    var focus: UIElementInfo? = UIElementInfo(role: .textField, label: "Type a message", app: "WhatsApp", window: "Amma", frame: .zero)

    /// Adds a control at a rectangle.
    func add(_ rect: CGRect, _ role: ScreenRole, _ label: String, identifier: String = "", app: String? = nil, window: String? = nil) {
        controls.append((rect, UIElementInfo(role: role, label: label, identifier: identifier, app: app ?? front.app,
                                             window: window ?? front.window, frame: rect)))
    }

    func element(at point: CGPoint) async -> UIElementInfo? { controls.first { $0.rect.contains(point) }?.element }
    func focusedElement() async -> UIElementInfo? { focus }
    func frontmost() async -> (app: String, window: String) { front }
    func frontmostBundleIdentifier() async -> String { frontBundleIdentifier }
    func visibleControls(limit: Int) async -> [UIElementInfo] { controls.map(\.element) }
}

/// A TaskContext that answers from scripts and records everything.
final class FakeContext: TaskContext, @unchecked Sendable {
    let taskID = "t1"
    let goal: String
    var memoryHints = ""
    var maxSteps = 25
    var confirmAnswer = true
    var userAnswer = "Priya Shah"
    /// What the person said last, as the runner would record it.
    var lastAnswer = ""

    private(set) var steps = 0
    private(set) var confirms: [(description: String, spoken: String?)] = []
    private(set) var actions: [ScreenAction] = []
    private(set) var questions: [(question: String, options: [String])] = []
    private(set) var reports: [String] = []

    init(goal: String = "Message Amma that I'm running late") { self.goal = goal }

    func askUser(_ question: String, options: [String]) async throws -> String {
        questions.append((question, options))
        return userAnswer
    }

    func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool {
        actions.append(action)
        confirms.append((action.description, spokenQuestion))
        return confirmAnswer
    }

    func report(_ progress: String) { reports.append(progress) }

    func step() throws {
        steps += 1
        if steps > maxSteps { throw StepLimitReached(limit: maxSteps) }
    }
}

/// Plays back scripted Messages API responses and records every request body.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(status: Int, body: JSONValue)]
    private(set) var requests: [URLRequest] = []
    /// How long each response takes; cancellation is honoured while waiting.
    var delaySeconds: Double = 0

    init(_ responses: [(status: Int, body: JSONValue)]) { queue = responses }

    convenience init(turns: [JSONValue]) { self.init(turns.map { (200, $0) }) }

    var bodies: [JSONValue] {
        lock.withLock { requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        if delaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
        let next: (status: Int, body: JSONValue)? = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        guard let next else { throw URLError(.notConnectedToInternet) }
        let data = try JSONEncoder().encode(next.body)
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: [:])!
        return (data, response)
    }
}

// MARK: - Building model responses

/// One assistant turn made of tool calls. Computer actions carry `toolset_name`.
func turn(_ blocks: [JSONValue], stopReason: String = "tool_use") -> JSONValue {
    ["type": "message", "role": "assistant", "content": .array(blocks), "stop_reason": .string(stopReason),
     "usage": ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 0]]
}

func computer(_ name: String, _ input: JSONObject = [:], id: String = UUID().uuidString) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "toolset_name": "computer", "input": .object(input)]
}

func tool(_ name: String, _ input: JSONObject, id: String = UUID().uuidString) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": .object(input)]
}

func finished(_ summary: String, success: Bool = true) -> JSONValue {
    tool("task_finished", ["success": .bool(success), "summary": .string(summary)])
}

/// A pixel in the 1280x800 image that maps to the given screen point (1440x900 screen).
func pixel(forScreen point: CGPoint) -> JSONValue {
    [.number(point.x * 1280 / 1440), .number(point.y * 800 / 900)]
}

func makeAgent(
    transport: ScriptedTransport, hands: FakeHands = FakeHands(), eyes: FakeEyes = FakeEyes(), labels: FakeLabels = FakeLabels(),
    maxHoldSeconds: Double = 4, holdWhile: @escaping @Sendable () -> Bool = { false }, activity: ActivityBus = ActivityBus()
) -> ScreenAgent {
    let client = ClaudeClient(apiKey: "test-key", transport: transport, retryBaseDelay: 0)
    let configuration = ScreenAgentConfiguration(
        model: "claude-sonnet-5-5", settleSeconds: 0, maxHoldSeconds: maxHoldSeconds, systemPrompt: "test prompt")
    return ScreenAgent(hands: hands, eyes: eyes, labels: labels, client: client, configuration: configuration, holdWhile: holdWhile, activity: activity)
}

/// A switch tests can flip from outside while the agent reads it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

/// All tool_result blocks in the last request, by tool_use_id.
func lastResults(_ transport: ScriptedTransport) -> [String: JSONValue] {
    guard let last = transport.bodies.last, let messages = last["messages"]?.arrayValue,
        let blocks = messages.last?["content"]?.arrayValue
    else { return [:] }
    var byID: [String: JSONValue] = [:]
    for block in blocks where block["type"]?.stringValue == "tool_result" {
        if let id = block["tool_use_id"]?.stringValue { byID[id] = block }
    }
    return byID
}

func resultText(_ block: JSONValue?) -> String {
    (block?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: " ")
}
