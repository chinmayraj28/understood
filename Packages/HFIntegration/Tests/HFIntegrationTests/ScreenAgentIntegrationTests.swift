import CoreGraphics
import Foundation
import HFCore
import HFScreenAgent
import HFTasks
import Testing

// The full chain in one place: start_task -> the real TaskRunner -> the real
// ScreenAgent -> its real safety backstop -> the runner's confirm -> a held Send
// click -> a spoken yes -> the hands. Only the model, the eyes, the labels and
// the hands are fakes.

/// A screen of 1440 x 900 points, shot at the same size so image pixels equal points.
struct FakeEyes: Eyes {
    var screenSize: CGSize { CGSize(width: 1440, height: 900) }
    func grab(maxLongEdge: Int) async throws -> Shot {
        Shot(png: Data([0x89, 0x50, 0x4E, 0x47]), pixelWidth: 1440, pixelHeight: 900,
             screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900))
    }
    func grab(region: CGRect, maxLongEdge: Int) async throws -> Shot {
        Shot(png: Data([0x89, 0x50, 0x4E, 0x47]), pixelWidth: Int(region.width), pixelHeight: Int(region.height),
             screenRect: region)
    }
}

/// Google Calendar's invite dialog: a guests field (which keeps focus) and a Send button.
struct FakeCalendarLabels: Labels {
    static let guests = InviteFlowExecutor.guestsAction.target!
    static let send = InviteFlowExecutor.sendAction.target!

    func element(at point: CGPoint) async -> UIElementInfo? {
        [Self.guests, Self.send].first { $0.frame.contains(point) }
    }
    func focusedElement() async -> UIElementInfo? { Self.guests }
    func frontmost() async -> (app: String, window: String) { ("Google Chrome", InviteFlowExecutor.window) }
    func visibleControls(limit: Int) async -> [UIElementInfo] { [Self.guests, Self.send] }
}

/// Plays back one scripted reply per model turn and records every request.
final class ScriptedModel: MessagesCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[JSONValue]]
    private(set) var requests: [JSONValue] = []
    let thinkingSeconds: Double

    init(thinkingSeconds: Double = 0, turns: [[JSONValue]]) {
        self.turns = turns
        self.thinkingSeconds = thinkingSeconds
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var lastRequest: JSONValue? { lock.lock(); defer { lock.unlock() }; return requests.last }

    private func record(_ body: JSONValue) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        requests.append(body)
        return turns.isEmpty ? [Self.own("end", "task_finished", ["success": true, "summary": "Done."])] : turns.removeFirst()
    }

    func createMessage(_ body: JSONValue) async throws -> JSONValue {
        let content = record(body)
        if thinkingSeconds > 0 { try await Task.sleep(nanoseconds: UInt64(thinkingSeconds * 1e9)) }  // honours cancellation, like URLSession
        return ["stop_reason": "tool_use", "content": .array(content)]
    }

    static func computer(_ id: String, _ name: String, _ input: JSONObject = [:]) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "toolset_name": "computer", "input": .object(input)]
    }
    static func own(_ id: String, _ name: String, _ input: JSONObject) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": .object(input)]
    }

    /// BUILD_PLAN 4b, as Claude would play it on screen.
    static func inviteFlow(finalSummary: String = "Sent the invite to Priya Shah.") -> [[JSONValue]] {
        [
            [own("p1", "report_progress", ["message": "Opening Google Calendar"]),
             own("q1", "ask_user", ["question": "Priya Shah or Priya Patel?", "options": ["Priya Shah", "Priya Patel"]])],
            [computer("c1", "left_click", ["coordinate": [400, 300]]),
             computer("c2", "type", ["text": "Priya Shah"])],
            [computer("c3", "left_click", ["coordinate": [900, 120]])],
            [own("f1", "task_finished", ["success": true, "summary": .string(finalSummary)])],
        ]
    }
}

/// Wraps a gate and records every description it was asked about.
final class RecordingGate: SafetyGating, @unchecked Sendable {
    let inner: any SafetyGating
    let asked = Log<String>()
    init(_ inner: any SafetyGating) { self.inner = inner }
    func check(_ action: ScreenAction) async -> Decision<Risk> {
        asked.append(action.description)
        return await inner.check(action)
    }
}

@Suite(.serialized) struct ScreenAgentIntegrationTests {

    static let goal = TaskFlowTests.goal

    static func agentRig(model: ScriptedModel, gate: RecordingGate = RecordingGate(KeywordGate())) -> Rig {
        Rig(gate: gate) { hands in
            ScreenAgent(
                hands: hands, eyes: FakeEyes(), labels: FakeCalendarLabels(), client: model,
                configuration: ScreenAgentConfiguration(model: "claude-sonnet-5-5", settleSeconds: 0))
        }
    }

    @Test("Full chain: start_task, a question, a held Send click, a spoken yes, done")
    func fullChain() async throws {
        let model = ScriptedModel(turns: ScriptedModel.inviteFlow())
        let gate = RecordingGate(KeywordGate())
        let rig = Self.agentRig(model: model, gate: gate)

        #expect(await rig.call("start_task", ["goal": .string(Self.goal)]).string("status") == "running")
        let question = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        #expect(question.text == "Priya Shah or Priya Patel?" && question.options == ["Priya Shah", "Priya Patel"])
        await rig.call("answer_task", ["answer": "Priya Shah"])

        let confirmation = try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
        #expect(confirmation.text.hasPrefix("Send \"Priya Shah\""), "the read-back names what will be sent: \(confirmation.text)")
        #expect(rig.hands.actions.items.contains("type Priya Shah"))
        #expect(!rig.hands.actions.items.contains("click 900,120"), "Send must not be clicked before the yes")

        await rig.call("answer_task", ["answer": "yes"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.status == .done && result.text == "Sent the invite to Priya Shah.")
        #expect(rig.hands.actions.items.filter { $0.hasPrefix("click") } == ["click 400,300", "click 900,120"])

        // The gate saw both clicks, structured, and never the typed text.
        #expect(gate.asked.items == [
            "Click text field \"Add guests\" in Google Chrome, window \"Google Calendar - Invite guests\"",
            "Click button \"Send\" in Google Chrome, window \"Google Calendar - Invite guests\"",
        ])
        #expect(!gate.asked.items.contains { $0.contains("Priya Shah") })
        // One step per model turn.
        #expect(rig.runner.status()["steps"] == 4 && model.requestCount == 4)
        #expect(rig.recorder.lines.first == "progress/running/Starting: \(Self.goal)")
        #expect(rig.recorder.lines.contains("progress/running/Opening Google Calendar"))
    }

    @Test("Declined: no click, and the model is told the person said no")
    func declined() async throws {
        let model = ScriptedModel(turns: ScriptedModel.inviteFlow(finalSummary: "I didn't send the invite."))
        let rig = Self.agentRig(model: model)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
        await rig.call("answer_task", ["answer": "no, wait, change the time to four"])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.text == "I didn't send the invite.")
        #expect(!rig.hands.actions.items.contains("click 900,120"))
        // The correction reached the model word for word, through lastAnswer.
        let lastRequest = try #require(model.lastRequest)
        let encoded = String(data: try JSONEncoder().encode(lastRequest), encoding: .utf8) ?? ""
        #expect(encoded.contains("The person said no to this"))
        #expect(encoded.contains("change the time to four"))
    }

    @Test("Stop during the Send confirmation: nothing clicked, the model is not called again")
    func cancelAtConfirmation() async throws {
        let model = ScriptedModel(turns: ScriptedModel.inviteFlow())
        let rig = Self.agentRig(model: model)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
        let requestsBefore = model.requestCount
        await rig.call("cancel_task")
        #expect(rig.hands.actions.items.contains("halt"))
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.requestCount == requestsBefore)
        #expect(!rig.hands.actions.items.contains("click 900,120"))
        #expect(rig.recorder.events.filter { $0.kind == .result }.map(\.status) == [.cancelled])
    }

    @Test("Stop while the model is thinking ends the task within a second")
    func cancelWhileThinking() async throws {
        let model = ScriptedModel(thinkingSeconds: 10, turns: ScriptedModel.inviteFlow())
        let rig = Self.agentRig(model: model)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        #expect(await waitUntil { model.requestCount == 1 })
        let begin = ContinuousClock.now
        await rig.call("cancel_task")
        #expect(await waitUntil(timeout: 1) { rig.hands.actions.items.last == "resume" }, "the agent unwound and the hands were released")
        #expect(secondsSince(begin) < 1)
        #expect(rig.runner.status()["stuck"] == nil)
    }

    @Test("A plain reply twice fails the task with Claude's own words; it is never success")
    func plainReplyTwiceFails() async throws {
        let plain: [JSONValue] = [["type": "text", "text": "I couldn't find Priya in your contacts. Maybe she isn't saved."]]
        let model = ScriptedModel(turns: [plain, plain])
        let rig = Self.agentRig(model: model)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        let result = try #require(await rig.recorder.waitFor(.result, timeout: 5))
        #expect(result.status == .failed, "\"\(result.text)\" was reported as \(result.status.rawValue)")
        #expect(result.text.hasPrefix("I couldn't find Priya in your contacts."), "said: \(result.text)")
        #expect(model.requestCount == 2, "one nudge, then give up")
    }

    @Test("A plain reply once is nudged, and the task carries on to finish")
    func plainReplyOnceIsNudged() async throws {
        let plain: [JSONValue] = [["type": "text", "text": "Let me look for the guests field."]]
        let model = ScriptedModel(turns: [plain] + ScriptedModel.inviteFlow())
        let rig = Self.agentRig(model: model)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        let nudged = String(data: try JSONEncoder().encode(model.lastRequest), encoding: .utf8) ?? ""
        #expect(nudged.contains("You replied without using a tool"), "the second request carries the nudge")
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
        await rig.call("answer_task", ["answer": "yes"])
        #expect(await rig.recorder.waitFor(.result, timeout: 5)?.status == .done)
    }
}
