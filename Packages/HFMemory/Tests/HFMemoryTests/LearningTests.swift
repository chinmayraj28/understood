import Foundation
import HFCore
import Testing
@testable import HFMemory

private let priyaQuestion = "I found two Priyas. Priya Shah or Priya Patel?"
private let meetGoal = "Set up a Google Meet with Priya tomorrow at 3"

@Suite("Learning from answers")
struct ExchangeLearningTests {
    @Test func priyaIsLearnedAsCandidateThenPromoted() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store, model: nil)
        let first = try #require(await learner.learn(question: priyaQuestion, answer: "Shah", goal: meetGoal))
        #expect(first.kind == .alias && first.key == "priya" && first.value == "Priya Shah")
        #expect(first.status == .candidate)
        #expect(first.evidence.hasPrefix("Asked:"))
        let second = try #require(await learner.learn(question: priyaQuestion, answer: "Priya Shah",
                                                      goal: "WhatsApp Priya: see you at 6"))
        #expect(second.id == first.id && second.status == .active)
    }

    @Test func modelExtractsALastingPreference() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: lastingReply())
        let learner = Learner(store: test.store, model: model)
        let fact = try #require(await learner.learn(question: "Which account should I use, personal or work?",
                                                    answer: "work, it's always work", goal: meetGoal))
        #expect(fact.kind == .preference && fact.key == "google_account" && fact.value == "work")
        #expect(fact.status == .candidate && fact.source == .learned)
        let call = try #require(model.calls.first)
        #expect(call.instructions.hasPrefix("You help a voice assistant"))
        #expect(call.input.contains("The user answered: work, it's always work"))
        #expect(call.schema == LearningPrompts.bundled?.exchangeSchema)
    }

    @Test func modelMayStillSayDefault() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store, model: FakeModel(reply: lastingReply(kind: "default")))
        let fact = await learner.learn(question: "Personal or work account?", answer: "work", goal: meetGoal)
        #expect(fact?.kind == .preference)
    }

    @Test func modelOneOffIsNotStored() async throws {
        let test = try TestStore()
        let reply: JSONValue = ["lasting": false, "kind": "none", "key": "", "value": "", "scope": "", "reason": "x"]
        let learner = Learner(store: test.store, model: FakeModel(reply: reply))
        #expect(await learner.learn(question: "What time?", answer: "3pm", goal: meetGoal) == nil)
        #expect(try test.store.allLive().isEmpty)
    }

    @Test func modelValueMustBeGroundedInWhatWasSaid() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store,
                              model: FakeModel(reply: lastingReply(kind: "alias", key: "Priya", value: "Priya Kapoor")))
        #expect(await learner.learn(question: "Which Priya do you mean?", answer: "the one from work", goal: meetGoal) == nil)
    }

    @Test func modelCannotStoreMessageWording() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store, model: FakeModel(
            reply: lastingReply(kind: "note", key: "usual message", value: "running late, start without me")))
        #expect(await learner.learn(question: "Do you usually say this?", answer: "I often say that",
                                    goal: "WhatsApp Mum: running late, start without me") == nil)
    }

    @Test func modelCannotStoreASkipConfirmationPreference() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store,
                              model: FakeModel(reply: lastingReply(kind: "style", key: "confirmations", value: "off")))
        #expect(await learner.learn(question: "How do you like confirmations?",
                                    answer: "I'm fed up of them, turn them off", goal: meetGoal) == nil)
        #expect(try test.store.allLive().isEmpty)
    }

    @Test func aYesToAConfirmationNeverReachesTheModel() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: lastingReply(kind: "style", key: "sending", value: "always"))
        let learner = Learner(store: test.store, model: model)
        for (question, answer) in [("Send it?", "yes"), ("Ready to post this?", "go ahead"),
                                   ("Shall I post this or save it as a draft?", "post it")] {
            #expect(await learner.learn(question: question, answer: answer, goal: meetGoal) == nil)
        }
        #expect(await learner.learn(question: "Personal or work account?", answer: "work", goal: meetGoal,
                                    isConfirmation: true) == nil)
        #expect(model.calls.isEmpty)
        #expect(try test.store.allLive().isEmpty)
    }

    @Test func modelFailuresAreSwallowed() async throws {
        let test = try TestStore()
        for reply in [nil, JSONValue.string("not an object"), ["weird": 1]] as [JSONValue?] {
            let learner = Learner(store: test.store, model: FakeModel(reply: reply))
            #expect(await learner.learn(question: "Which browser?", answer: "Chrome always", goal: meetGoal) == nil)
        }
    }

    @Test func withoutAModelOnlyTheRulesLearn() async throws {
        let test = try TestStore()
        let learner = Learner(store: test.store, model: nil)
        #expect(await learner.learn(question: "Which browser?", answer: "Chrome always", goal: meetGoal) == nil)
    }

    @Test func preFilterSkipsClearOneOffs() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: lastingReply())
        let learner = Learner(store: test.store, model: model, lastingPreFilter: { _, _, _ in 0.05 })
        #expect(await learner.learn(question: "Which slot?", answer: "the later one", goal: meetGoal) == nil)
        #expect(model.calls.isEmpty)
    }

    @Test func preFilterThatIsUnsureOrDownFallsThroughToTheModel() async throws {
        for preFilter in [{ @Sendable (_: String, _: String, _: String) async -> Double? in nil },
                          { @Sendable (_: String, _: String, _: String) async -> Double? in 0.6 }] {
            let test = try TestStore()
            let model = FakeModel(reply: lastingReply())
            let learner = Learner(store: test.store, model: model, lastingPreFilter: preFilter)
            #expect(await learner.learn(question: "Personal or work account?", answer: "work", goal: meetGoal) != nil)
            #expect(model.calls.count == 1)
        }
    }
}

@Suite("Learning from finished tasks")
struct ReflectionTests {
    @Test func successSavesALearnedRecipe() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: reflectReply(task: "open the team budget sheet", how: "In Chrome open sheets.google.com and click Team budget."))
        let learner = Learner(store: test.store, model: model)
        let facts = await learner.reflect(goal: "Open the team budget", status: .done, summary: "Opened it",
                                          steps: ["Opened Chrome", "Clicked Team budget"], recipeIDs: [])
        let recipe = try #require(facts.first)
        #expect(recipe.kind == .recipe && recipe.scope == "chrome" && recipe.status == .candidate)
        let call = try #require(model.calls.first)
        #expect(call.input.contains("Outcome: succeeded"))
        #expect(call.input.contains("- Clicked Team budget"))
        #expect(call.schema == LearningPrompts.bundled?.reflectSchema)
    }

    @Test func aRecipeTheBuiltInAlreadySaysIsNotDuplicated() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let builtIn = try #require(try test.store.allLive().first { $0.builtInID == "chrome.instant_meet" })
        let model = FakeModel(reply: reflectReply(how: builtIn.value))
        let learner = Learner(store: test.store, model: model)
        let facts = await learner.reflect(goal: "Start a Google Meet now", status: .done, summary: "Started",
                                          steps: [], recipeIDs: [builtIn.id])
        #expect(facts.isEmpty)
        #expect(try test.store.get(builtIn.id)?.successes == 1)  // the outcome was still recorded
        #expect(model.calls.first?.input.contains("Recipes the agent was given: [{\"how\":") == true)
        #expect(model.calls.first?.input.contains("start an instant google meet") == true)
    }

    @Test func failureLowersTrustAndAttachesAPitfall() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let recipe = try #require(try test.store.allLive().first { $0.builtInID == "whatsapp.send_message" })
        let model = FakeModel(reply: reflectReply(save: false, pitfall: "The search field is under the chat list title."))
        let learner = Learner(store: test.store, model: model)
        let facts = await learner.reflect(goal: "WhatsApp Mum: running late", status: .failed, summary: "Couldn't find the chat",
                                          steps: [], recipeIDs: [recipe.id])
        #expect(facts.isEmpty)
        let after = try #require(try test.store.get(recipe.id))
        #expect(after.failures == 1 && after.confidence < recipe.confidence)
        #expect(after.pitfalls == ["The search field is under the chat list title."])
        #expect(model.calls.first?.input.contains("running late") == false)  // the goal was redacted
        let hints = try test.store.memoryHints(forGoal: "WhatsApp Mum: on my way")
        #expect(hints.text.contains("  Watch out: The search field is under the chat list title."))
    }

    @Test func cancelledTasksTeachNothing() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let recipe = try #require(try test.store.allLive().first(where: \.isBuiltIn))
        let model = FakeModel(reply: reflectReply())
        let learner = Learner(store: test.store, model: model)
        #expect(await learner.reflect(goal: "Start a meet", status: .cancelled, summary: "", steps: [],
                                      recipeIDs: [recipe.id]).isEmpty)
        #expect(model.calls.isEmpty)
        #expect(try test.store.get(recipe.id)?.confidence == recipe.confidence)
    }

    @Test func recipeThatRepeatsTheMessageIsDropped() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: reflectReply(
            task: "send a whatsapp message",
            how: "Open WhatsApp, search Amma, type running late, start dinner without me, press Return"))
        let learner = Learner(store: test.store, model: model)
        #expect(await learner.reflect(goal: "WhatsApp Mum: running late, start dinner without me", status: .done,
                                      summary: "Sent", steps: [], recipeIDs: []).isEmpty)
    }

    @Test func preferencesAreKeptOnlyWhenStatedAsStanding() async throws {
        let preference: JSONValue = ["kind": "preference", "key": "google account", "value": "work", "scope": ""]
        let test = try TestStore()
        let oneOff = await Learner(store: test.store, model: FakeModel(reply: reflectReply(preferences: [preference])))
            .reflect(goal: "Set up a meet using my work account", status: .done, summary: "ok", steps: [], recipeIDs: [])
        #expect(oneOff.map(\.kind) == [.recipe])
        let standing = await Learner(store: test.store, model: FakeModel(reply: reflectReply(preferences: [preference])))
            .reflect(goal: "Set up a meet, and always use my work account", status: .done, summary: "ok", steps: [],
                     recipeIDs: [])
        #expect(standing.contains { $0.kind == .preference })
    }

    @Test func secretRecipesAndPermissionPreferencesAreRefused() async throws {
        let test = try TestStore()
        let preference: JSONValue = ["kind": "style", "key": "confirmations", "value": "off", "scope": ""]
        let model = FakeModel(reply: reflectReply(how: "Log in with password hunter2 then click Join",
                                                  preferences: [preference]))
        let facts = await Learner(store: test.store, model: model)
            .reflect(goal: "Always join my standup meeting", status: .done, summary: "ok", steps: [], recipeIDs: [])
        #expect(facts.isEmpty)
        #expect(try test.store.allLive().isEmpty)
    }

    @Test func reflectFailuresAreSwallowed() async throws {
        let test = try TestStore()
        #expect(await Learner(store: test.store, model: FakeModel(reply: nil))
            .reflect(goal: "Start a meet", status: .done, summary: "ok", steps: [], recipeIDs: []).isEmpty)
        #expect(await Learner(store: test.store, model: nil)
            .reflect(goal: "Start a meet", status: .done, summary: "ok", steps: [], recipeIDs: []).isEmpty)
    }
}

@Suite("Memory as MemoryProviding")
struct MemoryProvidingTests {
    @Test func hintsThenTaskEndedRecordsTheOutcomeOfTheOfferedRecipe() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let memory = Memory(store: test.store, model: FakeModel(reply: reflectReply(save: false)))
        let goal = "Start a Google Meet now"
        let hints = await memory.hints(forGoal: goal)
        #expect(hints.contains("How to start an instant google meet"))
        await memory.taskEnded(goal: goal, status: .done, summary: "Meeting started", steps: ["Opened meet.new"],
                               seconds: 9)
        await memory.waitForBackgroundWork()
        let recipe = try #require(try test.store.allLive().first { $0.builtInID == "chrome.instant_meet" })
        #expect(recipe.successes == 1)
        #expect(try test.store.recentEpisodes().first?.goal == goal)
    }

    @Test func learnReturnsAtOnceAndLearnsInTheBackground() async throws {
        let test = try TestStore()
        let gate = Gate()
        let model = SlowModel(gate: gate, reply: lastingReply())
        let memory = Memory(store: test.store, model: model)
        await memory.learn(fromQuestion: "Personal or work account?", options: [], answer: "work", goal: meetGoal)
        #expect(try test.store.allLive().isEmpty)  // the caller did not wait for learning
        gate.open()
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.preference, key: "google account")?.value == "work")
    }

    @Test func withoutAModelEverythingElseStillWorks() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let memory = Memory(store: test.store)
        try test.store.remember(.style, key: "confirmations", value: "brief", source: .explicit)
        #expect(await memory.summaryForPrompt(maxCharacters: 500).contains("confirmations: brief"))
        #expect(await memory.hints(forGoal: "WhatsApp Mum: hi").contains("WhatsApp"))
        await memory.learn(fromQuestion: priyaQuestion, options: [], answer: "Shah", goal: meetGoal)
        await memory.taskEnded(goal: meetGoal, status: .done, summary: "ok", steps: [], seconds: 1)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.value == "Priya Shah")  // the rule still learns
    }

    @Test func aBrokenStoreNeverBreaksTheCaller() async throws {
        let test = try TestStore()
        let memory = Memory(store: test.store, model: FakeModel(reply: lastingReply()))
        test.store.close()
        #expect(await memory.hints(forGoal: "anything") == "")
        #expect(await memory.summaryForPrompt(maxCharacters: 500) == "")
        await memory.learn(fromQuestion: "Personal or work account?", options: [], answer: "work", goal: meetGoal)
        await memory.taskEnded(goal: meetGoal, status: .failed, summary: "x", steps: [], seconds: 1)
        await memory.waitForBackgroundWork()
    }
}

/// A one-way latch for holding a background job until the test lets it go.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() async { await withCheckedContinuation { continuation in
        DispatchQueue.global().async { self.semaphore.wait(); continuation.resume() }
    } }
}

/// A model that waits at a gate before answering.
struct SlowModel: StructuredLanguageModel {
    let gate: Gate
    let reply: JSONValue
    func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue {
        await gate.wait()
        return reply
    }
}
