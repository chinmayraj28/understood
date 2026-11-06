import Foundation
import HFCore
import Testing
@testable import HFMemory

/// The tools, by name, bound to a fresh memory.
private struct ToolBox {
    let test: TestStore
    let tools: [String: ToolSpec]

    init(seedBuiltIns: Bool = false) throws {
        test = try TestStore(seedBuiltIns: seedBuiltIns)
        tools = Dictionary(uniqueKeysWithValues: MemoryTools.make(memory: Memory(store: test.store)).map { ($0.name, $0) })
    }

    func call(_ name: String, _ parameters: JSONObject = [:]) async -> JSONObject {
        await tools[name]!.handler(parameters)
    }
}

@Suite("Memory voice tools")
struct MemoryToolsTests {
    @Test func specsFollowTheContract() async throws {
        let box = try ToolBox()
        #expect(Set(box.tools.keys) == ["remember", "recall", "forget", "forget_everything", "correct_memory",
                                        "recent_tasks"])
        for spec in box.tools.values {
            #expect(spec.tier == .meta)
            #expect(spec.parameters["type"]?.stringValue == "object")
            let properties = Set(spec.parameters["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let required = Set(spec.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(required.isSubset(of: properties))
            #expect(spec.description.count > 80)
            let result = await spec.handler([:])  // empty parameters must not crash
            #expect(result["ok"]?.boolValue != nil)
            if result["ok"]?.boolValue == false { #expect((result["error"]?.stringValue?.count ?? 999) < 200) }
        }
    }

    @Test func handlersSurviveGarbageAndABrokenStore() async throws {
        let box = try ToolBox()
        for name in box.tools.keys {
            for parameters: JSONObject in [["kind": 5, "key": .null, "value": [1, 2]], ["count": "lots"],
                                           ["confirmed": "yes"], ["about": ["a": 1]]] {
                #expect(await box.call(name, parameters)["ok"] != nil)
            }
        }
        box.test.store.close()
        #expect(await box.call("recall") == ToolResult.failure(MemoryTools.genericFailure))
    }

    @Test func rememberAndRecall() async throws {
        let box = try ToolBox()
        let saved = await box.call("remember", ["kind": "alias", "key": "Mum", "value": "Amma", "app": "WhatsApp"])
        #expect(saved["say"]?.stringValue == "Got it. I'll remember \"Mum\" means Amma on WhatsApp.")
        #expect(try box.test.store.lookup(.alias, key: "mum", scope: "whatsapp")?.source == .explicit)
        _ = await box.call("remember", ["kind": "preference", "key": "google account", "value": "work"])
        let who = await box.call("recall", ["about": "my mum"])
        #expect(who["count"]?.intValue == 1 && who["say"]?.stringValue?.contains("Amma") == true)
        let everything = await box.call("recall")
        #expect(everything["count"]?.intValue == 2)
        #expect(everything["say"]?.stringValue?.hasPrefix("I know 2 things") == true)
        #expect((everything["say"]?.stringValue?.count ?? 999) < 300)
    }

    @Test func recallNeverListsRecipes() async throws {
        let box = try ToolBox(seedBuiltIns: true)
        #expect(await box.call("recall")["say"]?.stringValue == "I don't remember anything about you yet.")
        #expect(await box.call("recall", ["about": "whatsapp"])["count"]?.intValue == 0)
    }

    @Test func rememberReportsWhatItReplaced() async throws {
        let box = try ToolBox()
        _ = await box.call("remember", ["kind": "preference", "key": "music app", "value": "Spotify"])
        let result = await box.call("remember", ["kind": "preference", "key": "music app", "value": "Apple Music"])
        #expect(result["replaced"]?.stringValue == "music app: Spotify")
        #expect(result["say"]?.stringValue?.contains("That replaces") == true)
    }

    @Test func rememberAcceptsLooseKindWords() async throws {
        let box = try ToolBox()
        _ = await box.call("remember", ["kind": "contact", "key": "Dad", "value": "Appa"])
        _ = await box.call("remember", ["kind": "default", "key": "browser", "value": "Chrome"])
        _ = await box.call("remember", ["kind": "whatever", "key": "dog", "value": "Rex"])
        #expect(try box.test.store.lookup(.alias, key: "Dad")?.value == "Appa")
        #expect(try box.test.store.lookup(.preference, key: "browser")?.value == "Chrome")
        #expect(try box.test.store.lookup(.note, key: "dog")?.value == "Rex")
    }

    @Test(arguments: [
        ["kind": "note", "key": "bank password", "value": "hunter2"],
        ["kind": "note", "key": "card", "value": "4111 1111 1111 1111"],
        ["kind": "style", "key": "confirmations", "value": "off"],
        ["kind": "style", "key": "sending", "value": "don't ask me before sending"],
    ] as [JSONObject])
    func rememberRefusesSecretsAndPermission(_ parameters: JSONObject) async throws {
        let box = try ToolBox()
        let result = await box.call("remember", parameters)
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue?.isEmpty == false)
        #expect(try box.test.store.allLive().isEmpty)
    }

    @Test func recallFlagsUnconfirmedThings() async throws {
        let box = try ToolBox()
        try box.test.store.remember(.alias, key: "Priya", value: "Priya Shah")
        let everything = await box.call("recall")
        #expect(everything["count"]?.intValue == 0 && everything["learning"]?.intValue == 1)
        #expect(everything["say"]?.stringValue?.contains("still checking 1 thing") == true)
        #expect(await box.call("recall", ["about": "Priya"])["say"]?.stringValue?.contains("not sure yet") == true)
    }

    @Test func forgetOneTopic() async throws {
        let box = try ToolBox()
        _ = await box.call("remember", ["kind": "alias", "key": "Priya", "value": "Priya Shah"])
        _ = await box.call("remember", ["kind": "alias", "key": "Mum", "value": "Amma"])
        let result = await box.call("forget", ["about": "Priya"])
        #expect(result["forgotten"]?.intValue == 1)
        #expect(result["say"]?.stringValue?.contains("Priya Shah") == true)
        #expect(try box.test.store.lookup(.alias, key: "Priya") == nil)
        #expect(await box.call("forget", ["about": "Priya"])["forgotten"]?.intValue == 0)
        let everything = await box.call("forget", ["about": "everything"])
        #expect(everything["ok"]?.boolValue == false)
        #expect(everything["error"]?.stringValue?.contains("forget_everything") == true)
    }

    @Test func forgetEverythingNeedsAnAskedAndAnsweredQuestion() async throws {
        let box = try ToolBox(seedBuiltIns: true)
        _ = await box.call("remember", ["kind": "alias", "key": "Mum", "value": "Amma"])
        let jump = await box.call("forget_everything", ["confirmed": true])  // skipped the question
        #expect(jump["ok"]?.boolValue == false && jump["needs_confirmation"]?.boolValue == true)
        #expect(await box.call("forget_everything", ["confirmed": true])["ok"]?.boolValue == false)  // no time to ask
        let ask = await box.call("forget_everything")
        #expect(ask["needs_confirmation"]?.boolValue == true)
        #expect(ask["say"]?.stringValue?.contains("can't be undone") == true)
        box.test.clock.advance(6)
        #expect(await box.call("forget_everything", ["confirmed": "yes"])["done"]?.boolValue == false)  // not a real true
        box.test.clock.advance(6)
        let done = await box.call("forget_everything", ["confirmed": true])
        #expect(done["done"]?.boolValue == true && done["forgotten"]?.intValue == 1)
        let left = try box.test.store.allLive()
        #expect(!left.isEmpty && left.allSatisfy { $0.isBuiltIn })  // the starter recipes came back
    }

    @Test func correctionAfterALearnedNameWasOffered() async throws {
        let box = try ToolBox(seedBuiltIns: true)
        let learner = Learner(store: box.test.store, model: nil)
        await learner.learn(question: priyaQuestionForTools, answer: "Shah", goal: meetGoalForTools)
        await learner.learn(question: priyaQuestionForTools, answer: "Shah", goal: meetGoalForTools)
        let hints = try box.test.store.memoryHints(forGoal: "Email Priya about lunch")
        #expect(hints.text.contains("\"Priya\" is Priya Shah"))
        let result = await box.call("correct_memory", ["about": "Priya", "right_value": "Priya Patel"])
        #expect(result["use_now"]?.stringValue == "Priya Patel")
        #expect(result["say"]?.stringValue?.contains("stopped assuming") == true)
        #expect(try box.test.store.lookup(.alias, key: "Priya") == nil)  // no longer applied silently
        let live = try #require(try box.test.store.lookupLive(.alias, key: "Priya"))
        #expect(live.value == "Priya Patel" && live.status == .candidate)
        let oldID = try #require(result["fact_id"]?.intValue)
        #expect(try box.test.store.get(Int64(oldID))?.status == .retired)
    }

    @Test func correctionWithoutDetailsTargetsTheLastOfferedFact() async throws {
        let box = try ToolBox()
        _ = await box.call("remember", ["kind": "alias", "key": "Mum", "value": "Amma"])
        _ = await box.call("remember", ["kind": "alias", "key": "Priya", "value": "Priya Shah"])
        _ = try box.test.store.memoryHints(forGoal: "Email Priya about lunch")
        let result = await box.call("correct_memory")
        #expect(result["corrected"]?.stringValue?.contains("Priya Shah") == true)
        #expect(try box.test.store.lookup(.alias, key: "Mum")?.confidence == MemoryLimits.explicitConfidence)
    }

    @Test func correctionOfAnExplicitFactKeepsItButLowersTrust() async throws {
        let box = try ToolBox()
        _ = await box.call("remember", ["kind": "alias", "key": "Priya", "value": "Priya Shah"])
        let result = await box.call("correct_memory", ["about": "Priya", "right_value": "Priya Patel"])
        #expect(result["say"]?.stringValue?.contains("this time") == true)
        let fact = try #require(try box.test.store.lookup(.alias, key: "Priya"))
        #expect(fact.value == "Priya Shah" && fact.confidence < MemoryLimits.explicitConfidence)
    }

    @Test func correctionWithNothingToCorrect() async throws {
        let box = try ToolBox()
        let result = await box.call("correct_memory", ["about": "Bob"])
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue?.contains("not sure which") == true)
    }

    @Test func recentTasks() async throws {
        let box = try ToolBox()
        #expect(await box.call("recent_tasks")["say"]?.stringValue == "I haven't done any tasks yet.")
        try box.test.store.logEpisode(goal: "Open Spotify", executor: "screen", status: "done", summary: "Opened Spotify",
                                      steps: 1, seconds: 0.5)
        try box.test.store.logEpisode(goal: "WhatsApp Mum: running late", executor: "screen", status: "done",
                                      summary: "", steps: 3, seconds: 6)
        let result = await box.call("recent_tasks", ["count": 2])
        let goals = result["tasks"]?.arrayValue?.compactMap { $0["goal"]?.stringValue }
        #expect(goals == ["WhatsApp Mum: [message]", "Open Spotify"])
        #expect(result["say"]?.stringValue?.contains("running late") == false)
    }
}

private let priyaQuestionForTools = "I found two Priyas. Priya Shah or Priya Patel?"
private let meetGoalForTools = "Set up a Google Meet with Priya tomorrow at 3"
