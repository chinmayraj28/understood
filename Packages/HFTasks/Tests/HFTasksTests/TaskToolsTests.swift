import Foundation
import HFCore
import Testing

@testable import HFTasks

/// Records calls and returns a canned result.
final class FakeRunner: TaskRunning, @unchecked Sendable {
    let calls = Log<String>()
    func start(goal: String) -> JSONObject { calls.append("start \(goal)"); return ["ok": true, "called": "start"] }
    func answer(_ answer: String, taskID: String?) -> JSONObject {
        calls.append("answer \(answer) \(taskID ?? "nil")")
        return ["ok": true, "called": "answer"]
    }
    func cancel(taskID: String?) -> JSONObject { calls.append("cancel \(taskID ?? "nil")"); return ["ok": true] }
    func status() -> JSONObject { calls.append("status"); return ["ok": true, "status": "idle"] }
    var isRunning: Bool { false }
    var isAwaitingAnswer: Bool { false }
}

func toolsByName(_ runner: any TaskRunning) -> [String: ToolSpec] {
    Dictionary(uniqueKeysWithValues: TaskTools.make(runner: runner).map { ($0.name, $0) })
}

// Scenarios 45 to 50 of docs/TASKS.md.
@Suite(.serialized) struct TaskToolsTests {

    @Test("45. Four tools with valid schemas")
    func fourTools() throws {
        let tools = toolsByName(FakeRunner())
        #expect(Set(tools.keys) == ["start_task", "answer_task", "cancel_task", "task_status"])
        for tool in tools.values {
            #expect(tool.tier == .task)
            #expect(tool.parameters["type"] == "object" && tool.parameters["properties"]?.objectValue != nil)
            #expect(tool.description.count > 80)
            _ = try JSONEncoder().encode(tool.parameters)
        }
        #expect(tools["start_task"]?.parameters["required"] == ["goal"])
        #expect(tools["answer_task"]?.parameters["required"] == ["answer"])
    }

    @Test("46. Descriptions carry the rules")
    func descriptions() {
        let tools = toolsByName(FakeRunner())
        let start = tools["start_task"]!.description.lowercased()
        for phrase in ["quick tools", "self-contained", "every detail", "never tell the user a task is finished", "busy"] {
            #expect(start.contains(phrase), "start_task should mention \(phrase)")
        }
        #expect(tools["answer_task"]!.description.lowercased().contains("never answer yes on the user's behalf"))
        #expect(tools["cancel_task"]!.description.lowercased().contains("stop"))
    }

    @Test("47. Handlers pass through to the runner")
    func passThrough() async {
        let runner = FakeRunner()
        let tools = toolsByName(runner)
        _ = await tools["start_task"]!.handler(["goal": "Start an instant Meet"])
        _ = await tools["answer_task"]!.handler(["answer": "Priya Shah", "task_id": "t1"])
        _ = await tools["answer_task"]!.handler(["answer": "yes"])
        _ = await tools["answer_task"]!.handler(["answer": "no", "task_id": "  "])
        _ = await tools["cancel_task"]!.handler([:])
        _ = await tools["task_status"]!.handler([:])
        #expect(runner.calls.items == [
            "start Start an instant Meet", "answer Priya Shah t1", "answer yes nil", "answer no nil", "cancel nil",
            "status",
        ])
    }

    @Test("48. Bad parameters are refused without calling the runner", arguments: [
        ("start_task", JSONObject()),
        ("start_task", ["goal": ""]),
        ("start_task", ["goal": 42]),
        ("start_task", ["goal": nil]),
        ("answer_task", JSONObject()),
        ("answer_task", ["answer": "   "]),
    ])
    func badParameters(tool: String, parameters: JSONObject) async {
        let runner = FakeRunner()
        let result = await toolsByName(runner)[tool]!.handler(parameters)
        #expect(!result.isOK && result.string("error") != nil)
        #expect(runner.calls.items.isEmpty)
    }

    @Test("49. Every handler answers with a dictionary that has ok")
    func alwaysADictionary() async {
        for tool in toolsByName(FakeRunner()).values {
            let result = await tool.handler(["unexpected": ["nested": true]])
            #expect(result["ok"]?.boolValue != nil, "\(tool.name)")
        }
    }

    @Test("50. A real runner through the tools, and every result is JSON")
    func realRunnerThroughTools() async throws {
        let executor = ScriptedExecutor { _, context in
            let who = try await context.askUser("Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])
            let approved = try await context.confirm(clickAction("Send the invite to \(who)"), spokenQuestion: nil)
            return approved ? "Sent the invite to \(who)." : "Not sent."
        }
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        let tools = toolsByName(runner)
        var results: [JSONObject] = []

        results.append(await tools["start_task"]!.handler(["goal": "Invite Priya to a Meet tomorrow at 3pm"]))
        #expect(results.last?.string("status") == "running")
        results.append(await tools["start_task"]!.handler(["goal": "something else"]))
        #expect(results.last?.string("status") == "busy")
        _ = await recorder.waitFor(.question)
        results.append(await tools["task_status"]!.handler([:]))
        #expect(results.last?.string("status") == "needs_input")
        results.append(await tools["answer_task"]!.handler(["answer": "Priya Shah"]))
        _ = await recorder.waitFor(.confirmation)
        results.append(await tools["answer_task"]!.handler(["answer": "yes"]))
        _ = await recorder.waitFor(.result)
        results.append(await tools["task_status"]!.handler([:]))
        #expect(results.last?.string("summary") == "Sent the invite to Priya Shah.")
        results.append(await tools["cancel_task"]!.handler([:]))
        #expect(results.last?.string("status") == "not_running")
        results.append(await tools["answer_task"]!.handler(["answer": "yes"]))
        #expect(results.last?.isOK == false)
        for result in results { _ = try JSONEncoder().encode(result) }
    }
}
