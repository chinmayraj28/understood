import Foundation
import HFCore
import Testing
@testable import HFDecisions

@Suite("Jev client")
struct JevClientTests {
    static let noulQuestion = ["q": JevQuestion(kind: .noul, instructions: "greeting?")]

    @Test func returnsAnswersAndSendsTheKeyOnlyInTheHeader() async throws {
        let transport = FakeTransport.respond(json: ["answers": ["q": ["type": "noul", "noul": 0.9]]])
        let client = makeClient(transport)
        let answers = try await client.ask(state: ["said": "hi"], questions: Self.noulQuestion)
        #expect(answers["q"] == .noul(probabilityOfYes: 0.9))
        let request = try #require(transport.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["model"] == "jev-latest")
        #expect(body["state"]?["said"] == "hi")
        #expect(body["questions"]?["q"]?["type"] == "noul")
    }

    @Test(arguments: [
        ("500", FakeTransport.respond(status: 500, text: "upstream error")),
        ("401", FakeTransport.respond(status: 401, text: "no auth")),
        ("not json", FakeTransport.respond(status: 200, text: "not json")),
        ("missing answer", FakeTransport.respond(json: ["answers": [:] as [String: Any]])),
        ("out of range", FakeTransport.respond(json: ["answers": ["q": ["type": "noul", "noul": 1.7]]])),
        ("no value", FakeTransport.respond(json: ["answers": ["q": ["type": "noul"]]])),
        ("no answers", FakeTransport.respond(json: ["oops": true])),
        ("network", FakeTransport.brokenNetwork),
    ])
    func anyFailureIsAJevError(name: String, transport: FakeTransport) async {
        let client = makeClient(transport)
        do {
            _ = try await client.ask(state: [:], questions: Self.noulQuestion)
            Issue.record("expected a JevError for \(name)")
        } catch let error as JevError {
            #expect(!error.description.contains(fakeKey))
        } catch {
            Issue.record("expected a JevError, got \(error)")
        }
    }

    @Test func rejectsAChoiceOutsideItsCriteria() async {
        let client = makeClient(.choice("q", ["maybe": 1]))
        let question = ["q": JevQuestion(kind: .choice, instructions: "x", criteria: ["yes": "", "no": ""])]
        await #expect(throws: JevError.self) { try await client.ask(state: [:], questions: question) }
    }

    @Test func timeoutIsAHardDeadline() async {
        let client = makeClient(.slow(seconds: 1.0), timeoutSeconds: 0.15)
        let start = ContinuousClock.now
        await #expect(throws: JevError.timedOut(seconds: 0.15)) {
            try await client.ask(state: [:], questions: Self.noulQuestion)
        }
        #expect(elapsedMilliseconds(since: start) < 500)
    }

    @Test(arguments: [(-1.0, 0.8), (Double.nan, 0.8), (Double.infinity, 0.8), (0, 0.8), (0.01, 0.1), (99, 1.2), (0.5, 0.5)])
    func timeoutIsClampedToASaneRange(given: Double, expected: Double) async {
        let client = JevClient(apiKey: fakeKey, model: "jev-latest", url: URL(string: "https://jev.test")!,
                               timeoutSeconds: given, transport: FakeTransport.slow(seconds: 5))
        #expect(client.timeoutSeconds == expected)
        #expect(client.timeoutSeconds < 1.5)  // below the task runner's own classification timeout
        if given > 1 && given.isFinite {
            // A huge setting must still give up before the runner does, without trapping.
            let start = ContinuousClock.now
            await #expect(throws: JevError.self) { try await client.ask(state: [:], questions: Self.noulQuestion) }
            #expect(elapsedMilliseconds(since: start) < 1500)
        }
    }

    @Test func warmUpNeverThrows() async {
        #expect(await makeClient(.failing).warmUp() == nil)
        let working = makeClient(.respond(json: ["answers": ["warm": ["type": "noul", "noul": 1]]]))
        #expect((await working.warmUp() ?? -1) >= 0)
    }

    @Test func noClientWithoutAKey() {
        var settings = Settings.load(environment: [:], envFileCandidates: [])
        settings.openRouterAPIKey = ""
        #expect(JevClient(settings: settings) == nil)
    }
}
