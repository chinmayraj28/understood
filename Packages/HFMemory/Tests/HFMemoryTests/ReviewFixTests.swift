import Foundation
import HFCore
import Testing
@testable import HFMemory

private let meetGoal = "Set up a Google Meet with Priya tomorrow at 3"
private let emailGoal = "Email Priya about lunch"
private let priyaOptions = ["Priya Shah", "Priya Patel"]

/// Fix 1: one answer already helps next time, as a suggestion to check, never as an assumption.
@Suite("Unconfirmed suggestions")
struct SuggestionTests {
    /// The first task asks the open question; memory stores a candidate.
    private func memoryAfterFirstAnswer() async throws -> (TestStore, Memory) {
        let test = try TestStore(seedBuiltIns: true)
        let memory = Memory(store: test.store)
        _ = await memory.hints(forGoal: meetGoal)
        await memory.learn(fromQuestion: "Which Priya do you want to invite?", options: priyaOptions, answer: "Shah",
                           goal: meetGoal)
        await memory.taskEnded(goal: meetGoal, status: .done, summary: "Invite sent", steps: [], seconds: 30)
        await memory.waitForBackgroundWork()
        return (test, memory)
    }

    @Test func aCandidateIsOfferedAsAYesOrNoQuestion() async throws {
        let (test, memory) = try await memoryAfterFirstAnswer()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.status == .candidate)
        let hints = await memory.hints(forGoal: emailGoal)
        #expect(hints.contains(
            "Last time \"Priya\" meant Priya Shah (not yet confirmed: ask \"Priya Shah, like last time?\")."))
        #expect(!hints.contains("Names:"))  // not stated as a fact
    }

    @Test func aYesPromotesTheCandidate() async throws {
        let (test, memory) = try await memoryAfterFirstAnswer()
        _ = await memory.hints(forGoal: emailGoal)
        await memory.learn(fromQuestion: "Priya Shah, like last time?", options: [], answer: "Yes, that's her",
                           goal: emailGoal)
        await memory.waitForBackgroundWork()
        let fact = try #require(try test.store.lookup(.alias, key: "Priya"))
        #expect(fact.value == "Priya Shah" && fact.status == .active)
        let next = await memory.hints(forGoal: "WhatsApp Priya: see you at 6")
        #expect(next.contains("Names: \"Priya\" is Priya Shah."))
    }

    @Test func aNoRetiresTheCandidate() async throws {
        let (test, memory) = try await memoryAfterFirstAnswer()
        _ = await memory.hints(forGoal: emailGoal)
        await memory.learn(fromQuestion: "Priya Shah, like last time?", options: [], answer: "No, the other one",
                           goal: emailGoal)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya") == nil)
        #expect(try test.store.history(key: "Priya").first?.retiredReason == "corrected")
        #expect(!(await memory.hints(forGoal: emailGoal)).contains("Priya Shah"))
    }

    @Test func anUnclearAnswerChangesNothing() async throws {
        let (test, memory) = try await memoryAfterFirstAnswer()
        _ = await memory.hints(forGoal: emailGoal)
        await memory.learn(fromQuestion: "Priya Shah, like last time?", options: [], answer: "hmm, I'm not sure",
                           goal: emailGoal)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.status == .candidate)
    }

    @Test func aYesToARiskyStepNeverPromotesAnything() async throws {
        let (test, memory) = try await memoryAfterFirstAnswer()
        _ = await memory.hints(forGoal: emailGoal)
        await memory.learn(fromQuestion: "Send the email to Priya Shah?", options: [], answer: "yes", goal: emailGoal)
        await memory.learn(fromQuestion: "Priya Shah, like last time?", options: [], answer: "yes", goal: emailGoal,
                           isConfirmation: true)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.status == .candidate)
    }

    @Test func aYesWithoutAnOfferedSuggestionIsNeverLearned() async throws {
        let test = try TestStore()
        let memory = Memory(store: test.store)
        try test.store.remember(.alias, key: "Priya", value: "Priya Shah")  // a candidate memory never offered
        await memory.learn(fromQuestion: "Priya Shah, like last time?", options: [], answer: "yes", goal: emailGoal)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.status == .candidate)
    }

    @Test func theOfferRecordIsDroppedWhenTheTaskEnds() async throws {
        let test = try TestStore(seedBuiltIns: true)
        let memory = Memory(store: test.store)
        _ = await memory.hints(forGoal: "Start a Google Meet now")
        #expect(memory.offerCount == 1)
        await memory.taskEnded(goal: "Start a Google Meet now", status: .cancelled, summary: "", steps: [], seconds: 1)
        #expect(memory.offerCount == 0)
    }
}

/// Fix 2: secrets never reach the episode log or a learning prompt.
@Suite("Secrets in task text")
struct TaskTextPrivacyTests {
    @Test func theEpisodeLogNeverKeepsASecret() throws {
        let test = try TestStore()
        try test.store.logEpisode(goal: "Type my PIN 4821 into the bank app", executor: "screen", status: "done",
                                  summary: "Typed 4821 in the PIN field, then opened Accounts", steps: 3, seconds: 9)
        let episode = try #require(try test.store.recentEpisodes(limit: 1).first)
        #expect(episode.goal == "[private]")
        #expect(episode.summary == "[private], then opened Accounts")
        test.store.close()
        #expect(try Data(contentsOf: test.fileURL).range(of: Data("4821".utf8)) == nil)
    }

    @Test func reflectionNeverSendsASecretToTheModel() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: reflectReply(save: false))
        let memory = Memory(store: test.store, model: model)
        await memory.taskEnded(goal: "Pay with card 4111 1111 1111 1111 on the shop site", status: .done,
                               summary: "Entered the verification code 482913 and paid",
                               steps: ["Typed 4111 1111 1111 1111 in the card field", "Typed 482913", "Clicked Pay"],
                               seconds: 40)
        await memory.waitForBackgroundWork()
        let input = try #require(model.calls.first?.input)
        for secret in ["4111", "482913"] { #expect(!input.contains(secret), "leaked \(secret)") }
        #expect(input.contains("- Clicked Pay"))
    }

    @Test func theExchangePromptNeverCarriesASecretFromTheGoal() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: lastingReply())
        let learner = Learner(store: test.store, model: model)
        await learner.learn(question: "Personal or work account?", answer: "work",
                            goal: "Log in with password hunter2, then set up a meet")
        let input = try #require(model.calls.first?.input)
        #expect(!input.contains("hunter2"))
        #expect(input.contains("then set up a meet"))
    }
}

/// Fix 3: a drain always covers a learn call that has returned.
@Suite("Background hand-off")
struct BackgroundHandOffTests {
    @Test func drainAlwaysCoversAReturnedLearnCall() async throws {
        for round in 0..<50 {
            let test = try TestStore()
            let memory = Memory(store: test.store)
            await memory.learn(fromQuestion: "Which Mark?", options: ["Mark Jones", "Mark Smith"], answer: "Jones",
                               goal: "Reply to Mark's email \(round)")
            await memory.waitForBackgroundWork()
            #expect(try test.store.lookupLive(.alias, key: "Mark")?.value == "Mark Jones", "round \(round)")
        }
    }

    @Test func drainWaitsForJobsQueuedWhileDraining() async throws {
        let worker = BackgroundWorker()
        let counter = FailureCounter()  // reused as a simple thread-safe counter
        worker.enqueue {
            try? await Task.sleep(nanoseconds: 20_000_000)
            worker.enqueue { counter.add() }  // queued while a drain is already waiting
            counter.add()
        }
        await worker.drain()
        #expect(counter.count == 2)
    }
}

/// The contract's options, and the fallback when they are missing.
@Suite("Options offered by the task")
struct OfferedOptionsTests {
    @Test func optionsWinOverTheQuestionsWording() async throws {
        let test = try TestStore()
        let memory = Memory(store: test.store)
        await memory.learn(fromQuestion: "Which Priya do you want to invite to the meeting?", options: priyaOptions,
                           answer: "Patel", goal: meetGoal)
        await memory.waitForBackgroundWork()
        #expect(try test.store.lookupLive(.alias, key: "Priya")?.value == "Priya Patel")
    }

    @Test func aLongQuestionIsUnderstoodWithoutOptions() {
        let proposal = ExchangeRules.nameChoice(
            question: "Which Priya do you want to invite, Priya Shah or Priya Patel?", answer: "Shah", goal: meetGoal)
        #expect(proposal == ProposedFact(kind: .alias, key: "Priya", value: "Priya Shah"))
    }
}

/// Open point 3: a failure with no recipe can still teach something, as a candidate only.
@Suite("Learning from a failure with no recipe")
struct FailureWithoutRecipeTests {
    @Test func aFailureLeavesACandidateRecipeWithItsPitfall() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: reflectReply(
            save: true, task: "rename a file in finder", app: "finder",
            how: "Click the file once in Finder, press Return to edit the name, type it, press Return.",
            pitfall: "Double-clicking opens the file; click once, then press Return."))
        let facts = await Learner(store: test.store, model: model).reflect(
            goal: "Rename the budget file", status: .failed, summary: "It kept opening the file", steps: [],
            recipeIDs: [])
        let recipe = try #require(facts.first)
        #expect(recipe.kind == .recipe && recipe.status == .candidate)
        #expect(recipe.pitfalls == ["Double-clicking opens the file; click once, then press Return."])
        let hints = try test.store.memoryHints(forGoal: "Rename a file in Finder")
        #expect(hints.text.contains("(not yet confirmed; check it)"))
        #expect(hints.text.contains("Watch out: Double-clicking opens the file"))
    }

    @Test func aFailureNeverPromotesAnExistingRecipe() async throws {
        let test = try TestStore()
        let existing = try test.store.remember(.recipe, key: "rename a file in finder",
                                               value: "Click the file once and press Return.", scope: "finder")
        let model = FakeModel(reply: reflectReply(
            save: true, task: "rename a file in finder", app: "finder", how: "Click the file once and press Return.",
            pitfall: "The file was in a different folder."))
        _ = await Learner(store: test.store, model: model).reflect(
            goal: "Rename the budget file", status: .failed, summary: "Couldn't find it", steps: [], recipeIDs: [])
        let after = try #require(try test.store.get(existing.id))
        #expect(after.status == .candidate && after.sightings == 1)  // a failure is not a second sighting
        #expect(after.pitfalls == ["The file was in a different folder."])
    }

    @Test func aFailureWithNothingUsefulStoresNothing() async throws {
        let test = try TestStore()
        let model = FakeModel(reply: reflectReply(save: false, task: "", how: "", pitfall: ""))
        #expect(await Learner(store: test.store, model: model).reflect(
            goal: "Do something odd", status: .failed, summary: "x", steps: [], recipeIDs: []).isEmpty)
        #expect(try test.store.allLive().isEmpty)
    }
}

/// Fix 5: the facts checked on this Mac are in the recipes.
@Suite("Recipes carry what was checked on this Mac")
struct CheckedRecipeFactTests {
    @Test func whatsAppRecipeNamesTheRealControls() throws {
        let recipe = try #require(BuiltInRecipe.bundled().first { $0.id == "whatsapp.send_message" })
        #expect(recipe.version >= 2)
        #expect(recipe.how.contains("\"Compose message\""))
        #expect(recipe.how.contains("\"Voice message\" until text is typed, then \"Send\""))
        #expect(recipe.how.contains("only after the user confirms"))
    }

    @Test func spotlightRecipesSayHowToCloseIt() {
        for recipe in BuiltInRecipe.bundled() where recipe.how.contains("Spotlight") {
            #expect(recipe.how.contains("press Escape twice"), "\(recipe.id)")
        }
    }
}
