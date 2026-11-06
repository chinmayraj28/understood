import Foundation
import HFCore
import Testing
@testable import HFMemory

/// Runs the language-neutral cases in Fixtures/memory_cases.jsonl, the same cases the
/// Python prototype was checked against. Cases marked "live" need the real model and run
/// in LiveLearningTests instead.
@Suite("Shared cases (Fixtures/memory_cases.jsonl)")
struct SharedCaseTests {
    static let cases: [JSONObject] = {
        guard let text = try? String(contentsOf: Repo.file("Fixtures/memory_cases.jsonl"), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue
        }
    }()

    static func cases(ofType type: String) -> [JSONObject] {
        cases.filter { $0["type"]?.stringValue == type && $0["verified"]?.stringValue != "live" }
    }

    static func strings(_ value: JSONValue?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    @Test func theCaseFileIsThereAndComplete() {
        #expect(Self.cases.count >= 130, "Fixtures/memory_cases.jsonl missing or unreadable")
        let lineCount = (try? String(contentsOf: Repo.file("Fixtures/memory_cases.jsonl"), encoding: .utf8))?
            .split(separator: "\n").count
        #expect(lineCount == Self.cases.count, "every line must be a JSON object")
    }

    @Test(arguments: cases(ofType: "normalise_key"))
    func normaliseKey(_ item: JSONObject) {
        #expect(TextRules.normaliseKey(item["input"]!.stringValue!) == item["expect"]!.stringValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "secret"))
    func secret(_ item: JSONObject) {
        #expect(HardRules.looksSecret(item["text"]!.stringValue!) == item["expect"]!.boolValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "permission"))
    func permission(_ item: JSONObject) {
        let result = HardRules.grantsPermission(key: item["key"]!.stringValue!, value: item["value"]!.stringValue!)
        #expect(result == item["expect"]!.boolValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "redact"))
    func redact(_ item: JSONObject) {
        #expect(MessageContent.redact(item["input"]!.stringValue!) == item["expect"]!.stringValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "redact_secrets"))
    func redactSecrets(_ item: JSONObject) {
        #expect(HardRules.redactSecrets(item["input"]!.stringValue!) == item["expect"]!.stringValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "message_content"))
    func messageContent(_ item: JSONObject) {
        let result = MessageContent.repeatsMessage(item["value"]!.stringValue!, goal: item["goal"]!.stringValue!)
        #expect(result == item["expect"]!.boolValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "options_from_question"))
    func optionsFromQuestion(_ item: JSONObject) {
        #expect(ExchangeRules.optionsFromQuestion(item["question"]!.stringValue!) == Self.strings(item["expect"]),
                "\(item)")
    }

    @Test(arguments: cases(ofType: "pick_option"))
    func pickOption(_ item: JSONObject) {
        let result = ExchangeRules.pickOption(answer: item["answer"]!.stringValue!, options: Self.strings(item["options"]))
        #expect(result == item["expect"]?.stringValue, "\(item)")
    }

    @Test(arguments: cases(ofType: "confirmation_question"))
    func confirmationQuestion(_ item: JSONObject) {
        #expect(ExchangeRules.isConfirmationQuestion(item["question"]!.stringValue!) == item["expect"]!.boolValue!,
                "\(item)")
    }

    @Test(arguments: cases(ofType: "bare_yes_no"))
    func bareYesNo(_ item: JSONObject) {
        #expect(ExchangeRules.isBareYesNo(item["answer"]!.stringValue!) == item["expect"]!.boolValue!, "\(item)")
    }

    @Test(arguments: cases(ofType: "exchange"))
    func exchange(_ item: JSONObject) async throws {
        let question = item["question"]!.stringValue!
        let answer = item["answer"]!.stringValue!
        let goal = item["goal"]!.stringValue!
        let options = Self.strings(item["options"])
        let isConfirmation = item["is_confirmation"]?.boolValue ?? false
        let reason = ExchangeRules.neverLearnReason(question: question, answer: answer, isConfirmation: isConfirmation)
        let test = try TestStore()
        // A model that would happily learn anything, to prove the rules stop it first.
        let model = FakeModel(reply: lastingReply(kind: "style", key: "send", value: "always"))
        let learner = Learner(store: test.store, model: model)
        let fact = await learner.learn(question: question, answer: answer, goal: goal, options: options,
                                       isConfirmation: isConfirmation)
        switch item["expect"]!.stringValue! {
        case "never":
            #expect(reason?.rawValue == item["reason"]!.stringValue!, "\(item)")
            #expect(fact == nil, "\(item)")
            #expect(model.calls.isEmpty, "the model must never be asked: \(item)")
        case "learn_by_rule":
            let expected = item["fact"]!.objectValue!
            #expect(fact?.kind.rawValue == expected["kind"]?.stringValue, "\(item)")
            #expect(fact?.key == expected["key"]?.stringValue, "\(item)")
            #expect(fact?.value == expected["value"]?.stringValue, "\(item)")
            #expect(fact?.scope == expected["scope"]?.stringValue, "\(item)")
            #expect(fact?.status.rawValue == expected["status"]?.stringValue, "\(item)")
            #expect(model.calls.isEmpty, "name choices need no model: \(item)")
        case "not_by_rule":
            #expect(reason == nil, "\(item)")
            #expect(ExchangeRules.nameChoice(question: question, answer: answer, goal: goal, options: options) == nil)
        default:
            Issue.record("unknown expectation in \(item)")
        }
    }

    @Test(arguments: cases(ofType: "recipe_select"))
    func recipeSelection(_ item: JSONObject) throws {
        let test = try TestStore(seedBuiltIns: true)
        var aliasFacts: [StoredFact] = []
        for alias in item["aliases"]?.arrayValue ?? [] {
            aliasFacts.append(try test.store.remember(
                .alias, key: alias["key"]!.stringValue!, value: alias["value"]!.stringValue!,
                scope: alias["scope"]?.stringValue ?? "", source: .explicit))
        }
        let picked = try test.store.selectRecipes(forGoal: item["goal"]!.stringValue!, hintFacts: aliasFacts)
        #expect(picked.compactMap(\.builtInID) == Self.strings(item["expect_ids"]), "\(item)")
    }

    @Test func builtInRecipesAreSafe() throws {
        let recipes = try BuiltInRecipe.decode(Data(contentsOf: Repo.file("Fixtures/recipes.json")))
        #expect(!recipes.isEmpty)
        #expect(Set(recipes.map(\.id)).count == recipes.count, "recipe ids must be unique")
        for recipe in recipes {
            #expect(HardRules.refusalReason(key: recipe.task, value: recipe.how) == nil, "\(recipe.id)")
            #expect(recipe.how.count <= MemoryLimits.maximumBuiltInRecipeLength, "\(recipe.id)")
        }
    }
}

/// The package bundles copies of files whose masters live at the repo root.
/// Run Packages/HFMemory/sync-resources.sh after editing a master.
@Suite("Bundled resources match their masters")
struct ResourceCopyTests {
    @Test(arguments: [
        ("recipes.json", "Fixtures/recipes.json"),
        ("memory_tools.json", "Fixtures/memory_tools.json"),
        ("memory_learning.md", "docs/prompts/memory_learning.md"),
    ])
    func copyMatchesMaster(resource: String, master: String) throws {
        let parts = resource.split(separator: ".")
        let bundled = try #require(MemoryResources.bundle.url(forResource: String(parts[0]), withExtension: String(parts[1])))
        let copy = try Data(contentsOf: bundled)
        let original = try Data(contentsOf: Repo.file(master))
        #expect(copy == original, "\(resource) is out of date: run Packages/HFMemory/sync-resources.sh")
    }

    @Test func promptsParse() throws {
        let prompts = try #require(LearningPrompts.bundled)
        #expect(prompts.exchangeInstructions.hasPrefix("You help a voice assistant"))
        #expect(prompts.exchangeInstructions.hasSuffix("value \"in full\"."))
        #expect(prompts.reflectInstructions.contains("only after the user confirms"))
        #expect(prompts.exchangeSchema["required"]?.arrayValue?.count == 6)
        #expect(prompts.reflectSchema["properties"]?["pitfall"] != nil)
        #expect(prompts.lastingQuestion.hasPrefix("Does the user's answer reveal a lasting"))
    }

    @Test func everyToolHasABundledDefinition() {
        #expect(Set(MemoryTools.definitions.keys)
            == ["remember", "recall", "forget", "forget_everything", "correct_memory", "recent_tasks"])
    }
}
