import Foundation
import HFCore
import HFDecisions
import HFMemory
import HFTasks
import Testing

// The real Memory (HFMemory) behind the runner: an answered question and a
// finished task go in, and hints come back out for the next task for the same
// person. No language model: only the built-in rules learn.
@Suite(.serialized) struct MemoryIntegrationTests {

    static let goal = "Invite Priya to a meeting tomorrow at 3"

    /// A fresh store in its own folder (opening a store sets its folder to 0700).
    static func freshMemory() throws -> (Memory, MemoryStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try MemoryStore(fileURL: folder.appendingPathComponent("memory.db"))
        try store.seedBuiltInRecipes(BuiltInRecipe.bundled())
        return (Memory(store: store, model: nil), store, folder)
    }

    /// Wraps the 4b executor so each task's memory hints are recorded.
    struct HintRecordingExecutor: TaskExecuting {
        let inner: any TaskExecuting
        let hints: Log<String>
        func run(goal: String, context: TaskContext) async throws -> String {
            hints.append(context.memoryHints)
            return try await inner.run(goal: goal, context: context)
        }
    }

    /// Runs one full 4b task through the tools and waits for it to end.
    static func runInviteTask(_ rig: Rig, number: Int) async throws {
        await rig.call("start_task", ["goal": .string(goal)])
        _ = try #require(await rig.recorder.waitFor(.question, number: number, timeout: 5))
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = try #require(await rig.recorder.waitFor(.confirmation, number: number, timeout: 5))
        await rig.call("answer_task", ["answer": "yes"])
        _ = try #require(await rig.recorder.waitFor(.result, number: number, timeout: 5))
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
    }

    /// The 4b flow, reading memory's hints the way the screen agent's prompt tells Claude to:
    /// a known name needs no question; an unconfirmed one is checked with memory's own
    /// yes-or-no question; otherwise the open question is asked.
    struct MemoryAwareInviteExecutor: TaskExecuting {
        let hands: any Hands
        let hints: Log<String>
        let asked: Log<String>

        func run(goal: String, context: TaskContext) async throws -> String {
            let memoryHints = context.memoryHints
            hints.append(memoryHints)
            context.report("Opening Google Calendar")
            try context.step()
            let options = ["Priya Shah", "Priya Patel"]
            var who: String?
            if memoryHints.contains("\"Priya\" is Priya Shah") {
                who = "Priya Shah"
            } else if let range = memoryHints.range(of: #"ask "([^"]+)""#, options: .regularExpression) {
                let question = String(memoryHints[range].dropFirst(5).dropLast())
                asked.append(question)
                let reply = try await context.askUser(question, options: ["yes", "no"])
                if reply.lowercased().hasPrefix("yes") { who = "Priya Shah" }
            }
            if who == nil {
                asked.append("Priya Shah or Priya Patel?")
                let reply = try await context.askUser("Priya Shah or Priya Patel?", options: options)
                who = options.first { $0.localizedCaseInsensitiveContains(reply) } ?? reply
            }
            let name = who!
            try context.step()
            guard try await context.confirm(InviteFlowExecutor.guestsAction, spokenQuestion: nil) else { return "Stopped." }
            try await hands.click(at: InviteFlowExecutor.guestsField)
            try await hands.typeText(name)
            guard try await context.confirm(InviteFlowExecutor.sendAction, spokenQuestion: "Send the invite to \(name)?") else {
                return "I didn't send the invite."
            }
            try await hands.click(at: InviteFlowExecutor.sendButton)
            return "Sent the invite to \(name)."
        }
    }

    /// What memory knows about Priya, in a form that can be compared before and after a step.
    static func priyaFacts(_ store: MemoryStore) -> [String] {
        ((try? store.allLive()) ?? []).filter { $0.fact.key.lowercased().contains("priya") }.map {
            "\($0.fact.kind.rawValue) \($0.fact.key)=\($0.fact.value) \($0.fact.status.rawValue) conf=\($0.fact.confidence) seen=\($0.sightings)"
        }.sorted()
    }

    /// Answers the Send confirmation with a yes and checks memory did not change because of it.
    static func sayYesToSendAndCheckMemoryUnchanged(_ rig: Rig, memory: Memory, store: MemoryStore, number: Int) async throws {
        _ = try #require(await rig.recorder.waitFor(.confirmation, number: number, timeout: 5))
        await memory.waitForBackgroundWork()
        let before = priyaFacts(store)
        await rig.call("answer_task", ["answer": "yes"])
        _ = try #require(await rig.recorder.waitFor(.result, number: number, timeout: 5))
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
        try? await Task.sleep(nanoseconds: 100_000_000)  // let the detached taskEnded call reach memory
        await memory.waitForBackgroundWork()
        #expect(priyaFacts(store) == before, "a yes to Send must not change what memory knows")
    }

    @Test("Memory story end to end: ask, then suggest and confirm, then know")
    func memoryStory() async throws {
        let (memory, store, folder) = try Self.freshMemory()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        let hints = Log<String>()
        let asked = Log<String>()
        let classifiers = Classifiers(client: nil)
        let rig = Rig(gate: SafetyGate(classifier: classifiers), classifier: classifiers, memory: memory) {
            MemoryAwareInviteExecutor(hands: $0, hints: hints, asked: asked)
        }

        // Task 1: nothing known about Priya, so the open question; the user says just "Shah".
        await rig.call("start_task", ["goal": .string(Self.goal)])
        let first = try #require(await rig.recorder.waitFor(.question, number: 1, timeout: 5))
        #expect(first.text == "Priya Shah or Priya Patel?" && first.options == ["Priya Shah", "Priya Patel"])
        #expect(hints.items[0].lowercased().contains("google calendar"), "built-in recipe expected: \(hints.items[0])")
        await rig.call("answer_task", ["answer": "Shah"])
        // The runner passed the offered options, so "Shah" is understood as Priya Shah.
        #expect(await waitUntil(timeout: 3) { (try? store.lookupLive(.alias, key: "priya"))??.fact.value == "Priya Shah" })
        #expect(try store.lookupLive(.alias, key: "priya")?.fact.status == .candidate)
        try await Self.sayYesToSendAndCheckMemoryUnchanged(rig, memory: memory, store: store, number: 1)
        #expect(await waitUntil(timeout: 3) { ((try? store.recentEpisodes(limit: 5)) ?? []).count == 1 })

        // Task 2: the hints carry the suggestion, the executor asks memory's yes-or-no question, a yes promotes it.
        await rig.call("start_task", ["goal": .string(Self.goal)])
        let second = try #require(await rig.recorder.waitFor(.question, number: 2, timeout: 5))
        #expect(hints.items[1].contains("Last time \"Priya\" meant Priya Shah"), "task 2 hints: \(hints.items[1])")
        #expect(second.text == "Priya Shah, like last time?")
        await rig.call("answer_task", ["answer": "yes"])
        #expect(await waitUntil(timeout: 3) { (try? store.lookupLive(.alias, key: "priya"))??.fact.status == .active })
        try await Self.sayYesToSendAndCheckMemoryUnchanged(rig, memory: memory, store: store, number: 2)

        // Task 3: known, so no question at all.
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = try #require(await rig.recorder.waitFor(.confirmation, number: 3, timeout: 5))
        #expect(hints.items[2].contains("\"Priya\" is Priya Shah"), "task 3 hints: \(hints.items[2])")
        #expect(rig.recorder.events.filter { $0.kind == .question }.count == 2, "task 3 must not ask which Priya")
        #expect(asked.items == ["Priya Shah or Priya Patel?", "Priya Shah, like last time?"])
        try await Self.sayYesToSendAndCheckMemoryUnchanged(rig, memory: memory, store: store, number: 3)
        #expect(rig.recorder.events.last?.text == "Sent the invite to Priya Shah.")

        // Nothing anywhere was learned from a confirmation.
        #expect(!((try? store.allLive()) ?? []).contains { $0.fact.value.lowercased() == "yes" })
    }

    @Test("A no to memory's suggestion retires it, and the open question comes back")
    func suggestionRejected() async throws {
        let (memory, store, folder) = try Self.freshMemory()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        let hints = Log<String>()
        let asked = Log<String>()
        let rig = Rig(memory: memory) { MemoryAwareInviteExecutor(hands: $0, hints: hints, asked: asked) }

        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = try #require(await rig.recorder.waitFor(.question, number: 1, timeout: 5))
        await rig.call("answer_task", ["answer": "Shah"])
        _ = try #require(await rig.recorder.waitFor(.confirmation, number: 1, timeout: 5))
        await rig.call("answer_task", ["answer": "yes"])
        _ = try #require(await rig.recorder.waitFor(.result, number: 1, timeout: 5))
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
        await memory.waitForBackgroundWork()

        await rig.call("start_task", ["goal": .string(Self.goal)])
        #expect(await rig.recorder.waitFor(.question, number: 2, timeout: 5)?.text == "Priya Shah, like last time?")
        await rig.call("answer_task", ["answer": "no, the other one"])
        // The executor falls back to the open question in the same task.
        #expect(await rig.recorder.waitFor(.question, number: 3, timeout: 5)?.text == "Priya Shah or Priya Patel?")
        #expect(await waitUntil(timeout: 3) { (try? store.lookupLive(.alias, key: "priya"))??.fact.value != "Priya Shah" })
        await rig.call("cancel_task")
    }

    @Test("Memory that is slow never holds a task up")
    func slowMemoryDoesNotBlock() async throws {
        struct SlowMemory: MemoryProviding {
            func hints(forGoal goal: String) async -> String {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume(returning: "late") }
                }
            }
            func summaryForPrompt(maxCharacters: Int) async -> String { "" }
            func learn(fromQuestion question: String, options: [String], answer: String, goal: String) async {}
            func taskEnded(goal: String, status: TaskStatus, summary: String, steps: [String], seconds: Double) async {}
        }
        let hints = Log<String>()
        let rig = Rig(memory: SlowMemory(), configure: { $0.memoryTimeout = 0.2 }) {
            HintRecordingExecutor(inner: InviteFlowExecutor(hands: $0), hints: hints)
        }
        let begin = ContinuousClock.now
        await rig.call("start_task", ["goal": .string(Self.goal)])
        #expect(await rig.recorder.waitFor(.question) != nil)
        #expect(secondsSince(begin) < 1)
        #expect(hints.items == [""])
    }

    @Test("A PIN spoken in a goal is not stored in the task log")
    func noSecretsInEpisodes() async throws {
        let (memory, store, folder) = try Self.freshMemory()
        defer { store.close(); try? FileManager.default.removeItem(at: folder) }
        let rig = Rig(memory: memory) { _ in ScriptedFlow { _ in "Done." } }
        await rig.call("start_task", ["goal": "Type my PIN 4821 into the bank app"])
        _ = await rig.recorder.waitFor(.result)
        #expect(await waitUntil(timeout: 3) { ((try? store.recentEpisodes(limit: 5)) ?? []).count == 1 })
        let episode = try #require(try store.recentEpisodes(limit: 5).first)
        #expect(!episode.goal.contains("4821"), "stored goal: \(episode.goal)")
        #expect(!episode.summary.contains("4821"))
    }
}
