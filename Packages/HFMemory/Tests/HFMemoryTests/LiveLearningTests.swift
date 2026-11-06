import Foundation
import HFCore
import Testing
@testable import HFMemory

/// Real extraction with Claude (Settings.smallModel), run only with HF_LIVE=1:
///
///     cd Packages/HFMemory && HF_LIVE=1 swift test --filter Live
///
/// Uses the "live" cases in Fixtures/memory_cases.jsonl, plus recipe reflection after a
/// success and after a failure. Each call is cheap; the whole suite costs well under a cent.
@Suite("Live learning with Claude", .enabled(if: ProcessInfo.processInfo.environment["HF_LIVE"] == "1"),
       .serialized)
struct LiveLearningTests {
    static let model: LiveAnthropicModel? = {
        let settings = Settings.load()
        guard !settings.anthropicAPIKey.isEmpty else { return nil }
        return LiveAnthropicModel(apiKey: settings.anthropicAPIKey, model: settings.smallModel)
    }()

    static let liveExchanges: [JSONObject] = SharedCaseTests.cases.filter {
        $0["type"]?.stringValue == "exchange" && $0["verified"]?.stringValue == "live"
    }

    @Test(arguments: liveExchanges)
    func exchange(_ item: JSONObject) async throws {
        let model = try #require(Self.model, "ANTHROPIC_API_KEY is not set")
        let test = try TestStore()
        let learner = Learner(store: test.store, model: model)
        let fact = await learner.learn(question: item["question"]!.stringValue!, answer: item["answer"]!.stringValue!,
                                       goal: item["goal"]!.stringValue!)
        switch item["expect"]!.stringValue! {
        case "learn_by_model":
            let learned = try #require(fact, "expected a lasting preference: \(item)")
            #expect(learned.kind.rawValue == item["fact_kind"]?.stringValue, "\(item)")
            #expect(learned.value.lowercased().contains(item["value_contains"]!.stringValue!), "\(learned.value)")
            #expect(learned.status == .candidate && learned.source == .learned)
        default:  // "none"
            #expect(fact == nil, "should not be learned: \(item) -> \(String(describing: fact?.value))")
            #expect(try test.store.allLive().isEmpty)
        }
    }

    @Test func successTeachesAGenericRecipe() async throws {
        let model = try #require(Self.model, "ANTHROPIC_API_KEY is not set")
        let test = try TestStore()
        let facts = await Learner(store: test.store, model: model).reflect(
            goal: "Open my team's budget spreadsheet", status: .done,
            summary: "Opened the Team budget 2026 sheet in Google Sheets.",
            steps: ["Pressed Cmd+T in Chrome", "Typed sheets.google.com and pressed Return",
                    "Clicked the search box and typed budget", "Clicked Team budget 2026"],
            recipeIDs: [])
        let recipe = try #require(facts.first { $0.kind == .recipe }, "expected a recipe")
        print("Learned recipe: \(recipe.spokenLabel) [\(recipe.scope)]: \(recipe.value)")
        #expect(recipe.scope == "chrome")
        #expect(recipe.value.lowercased().contains("sheets"))
    }

    @Test func failureWithNoRecipeLeavesOnlyACandidate() async throws {
        let model = try #require(Self.model, "ANTHROPIC_API_KEY is not set")
        let test = try TestStore()
        let facts = await Learner(store: test.store, model: model).reflect(
            goal: "Rename the budget file on my desktop to Budget 2026", status: .failed,
            summary: "Double-clicking the file opened it in Numbers instead of renaming it.",
            steps: ["Clicked the Finder icon in the Dock", "Clicked Desktop in the sidebar",
                    "Double-clicked budget.numbers: it opened in Numbers", "Closed Numbers", "Gave up after 8 steps"],
            recipeIDs: [])
        for fact in facts {
            print("From a failure: \(fact.spokenLabel) [\(fact.scope)] \(fact.status.rawValue): \(fact.value) | \(fact.pitfalls)")
            #expect(fact.kind == .recipe && fact.status == .candidate)  // never trusted from a failure
            #expect(!fact.value.contains("Budget 2026"))
        }
    }

    @Test func failureLeavesAPitfallAndNeverTheMessage() async throws {
        let model = try #require(Self.model, "ANTHROPIC_API_KEY is not set")
        let test = try TestStore(seedBuiltIns: true)
        let recipe = try #require(try test.store.allLive().first { $0.builtInID == "whatsapp.send_message" })
        let goal = "WhatsApp Mum: running late, start dinner without me"
        _ = await Learner(store: test.store, model: model).reflect(
            goal: goal, status: .failed, summary: "I couldn't find the search field in WhatsApp.",
            steps: ["Opened WhatsApp with Spotlight", "Pressed Cmd+F: nothing happened",
                    "Clicked the top of the chat list: no search field", "Gave up after 6 steps"],
            recipeIDs: [recipe.id])
        let after = try #require(try test.store.get(recipe.id))
        print("Pitfalls: \(after.pitfalls)")
        #expect(after.failures == 1)
        for text in after.pitfalls + (try test.store.allLive().map(\.value)) {
            #expect(!text.lowercased().contains("dinner") && !text.lowercased().contains("running late"))
        }
    }
}

/// A minimal StructuredLanguageModel over the Anthropic Messages API, for live tests only.
/// The app passes in the real client (HFScreenAgent's ClaudeClient); this one exists so
/// HFMemory can test its prompts without depending on another package. The key is only
/// ever put in a request header: never printed or logged.
struct LiveAnthropicModel: StructuredLanguageModel {
    let apiKey: String
    let model: String

    struct Failure: Error, CustomStringConvertible { let description: String }

    func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: JSONValue = [
            "model": .string(model),
            "max_tokens": 2000,
            "system": .string(instructions),
            "messages": [["role": "user", "content": .string(input)]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
        ]
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // The body of an error response never contains the key; cut it short anyway.
            throw Failure(description: "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        guard reply["stop_reason"]?.stringValue == "end_turn" else {
            throw Failure(description: "stopped early: \(reply["stop_reason"]?.stringValue ?? "unknown")")
        }
        let text = reply["content"]?.arrayValue?.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue ?? ""
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard parsed.objectValue != nil else { throw Failure(description: "not a JSON object") }
        return parsed
    }
}
