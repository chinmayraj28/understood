//
//  TaskOwnsHandsTests.swift
//  HandsfreeTests
//
//  While a task runs or waits for an answer, quick tools that use the pointer or keyboard are refused.
//

import Foundation
import HFCore
import Testing

@Suite("A task owns the hands")
struct TaskOwnsHandsTests {
    /// Records what each fake tool did, as the real hands would.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        var all: [String] { lock.withLock { entries } }
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    }

    private func tool(_ name: String, tier: ToolSpec.Tier = .quick, log: Log) -> ToolSpec {
        ToolSpec(name: name, description: "d", parameters: ["type": "object"], tier: tier) { parameters in
            log.add("\(name) \(parameters["text"]?.stringValue ?? "")".trimmingCharacters(in: .whitespaces))
            return ToolResult.ok()
        }
    }

    private func tools(_ runner: FakeRunner, log: Log) -> [String: ToolSpec] {
        let quick = ["type_text", "scroll", "press_keys", "set_volume", "where_am_i"].map { tool($0, log: log) }
        let others = [tool("answer_task", tier: .task, log: log), tool("cancel_task", tier: .task, log: log),
                      tool("task_status", tier: .task, log: log), tool("remember", tier: .meta, log: log),
                      tool("go_to_sleep", tier: .meta, log: log)]
        let guarded = TaskOwnsHands.guarding(quick + others, isTaskActive: { CycleWiring.isTaskActive(runner) })
        return Dictionary(uniqueKeysWithValues: guarded.map { ($0.name, $0) })
    }

    @Test("type_text while a task waits for a yes is refused, and nothing is typed")
    func typeTextWhileWaitingForYes() async {
        let runner = FakeRunner(), log = Log()
        runner.isAwaitingAnswer = true
        let result = await tools(runner, log: log)["type_text"]!.handler(["text": "Send 'late' to Amma?"])
        #expect(log.all.isEmpty, "nothing typed into the field the task is paused over")
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue == "A task is in progress. Say the question aloud, or use answer_task or cancel_task.")
    }

    @Test("scroll while a task runs is refused")
    func scrollWhileRunning() async {
        let runner = FakeRunner(), log = Log()
        runner.isRunning = true
        let result = await tools(runner, log: log)["scroll"]!.handler(["direction": "down"])
        #expect(log.all.isEmpty && result["error"]?.stringValue == TaskOwnsHands.sentence)
    }

    @Test("set_volume and read-only tools still work while a task runs: they cannot reach the task's field")
    func volumeAndReadingAllowed() async {
        let runner = FakeRunner(), log = Log()
        runner.isRunning = true
        let all = tools(runner, log: log)
        #expect(await all["set_volume"]!.handler(["percent": 30])["ok"]?.boolValue == true)
        #expect(await all["where_am_i"]!.handler([:])["ok"]?.boolValue == true)
        #expect(log.all == ["set_volume", "where_am_i"])
    }

    @Test("answer_task, cancel_task, task_status, memory and go_to_sleep are never refused")
    func taskAndMemoryToolsAllowed() async {
        let runner = FakeRunner(), log = Log()
        runner.isAwaitingAnswer = true
        let all = tools(runner, log: log)
        for name in ["answer_task", "cancel_task", "task_status", "remember", "go_to_sleep"] {
            #expect(await all[name]!.handler([:])["ok"]?.boolValue == true, "\(name)")
        }
        #expect(log.all.count == 5)
    }

    @Test("Once the task ends, everything works again")
    func allowedAfterTheTask() async {
        let runner = FakeRunner(), log = Log()
        let all = tools(runner, log: log)
        runner.isRunning = true
        _ = await all["press_keys"]!.handler([:])
        #expect(log.all.isEmpty)
        runner.isRunning = false
        runner.isAwaitingAnswer = false
        for name in ["type_text", "scroll", "press_keys"] {
            #expect(await all[name]!.handler([:])["ok"]?.boolValue == true, "\(name)")
        }
        #expect(log.all.count == 3)
    }

    @Test("Every real quick tool is either refused during a task or known to be harmless")
    func everyRealQuickToolIsClassified() throws {
        // The repo's list of the quick tools (checked against HFHands by its own tests).
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quick_tools.json")
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]] ?? []
        let names = Set(list.compactMap { $0["name"] as? String })
        #expect(names.count == 13)
        let refused = names.filter { !TaskOwnsHands.allowedDuringTask.contains($0) }
        #expect(refused == ["type_text", "press_keys", "shortcut", "pointer", "scroll", "open_app", "open_url"])
        #expect(TaskOwnsHands.allowedDuringTask.isSubset(of: names), "no allowance for a tool that does not exist")
    }
}
