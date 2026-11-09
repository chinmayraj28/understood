import Foundation
import HFCore
import Testing

@testable import HFUnderstand

/// A fake recogniser: fixed text after a delay, or an error. Its delay ignores cancellation on
/// purpose, like a badly behaved network library. It records the hints it was given.
final class FakeHearer: Hearing, @unchecked Sendable {
    let name: HearerName
    private let lock = NSLock()
    private var texts: [String]
    private let delaySeconds: Double
    private let error: Error?
    private(set) var lastHints: HearingHints?

    init(_ name: HearerName, _ texts: String..., delaySeconds: Double = 0, error: Error? = nil) {
        self.name = name
        self.texts = texts
        self.delaySeconds = delaySeconds
        self.error = error
    }

    func hear(_ turn: RecordedTurn, hints: HearingHints) async throws -> String {
        lock.withLock { lastHints = hints }
        if delaySeconds > 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { continuation.resume() }
            }
        }
        if let error { throw error }
        // Each call takes the next text; the last one repeats.
        return lock.withLock { texts.count > 1 ? texts.removeFirst() : (texts.first ?? "") }
    }
}

private let turn = RecordedTurn(wav: Data([1, 2, 3]), durationSeconds: 1.2, source: "test")

private func understander(
    _ hearers: [any Hearing], model: StructuredLanguageModel? = nil, phrasebook: Phrasebook? = nil,
    _ change: (inout UnderstanderConfiguration) -> Void = { _ in }
) throws -> Understander {
    var configuration = UnderstanderConfiguration()
    configuration.postsActivity = false
    configuration.hearerTimeoutSeconds = 0.5
    configuration.repairTimeoutSeconds = 0.5
    change(&configuration)
    return Understander(hearers: hearers, repairModel: model, phrasebook: try phrasebook ?? Phrasebook.inMemory(), configuration: configuration)
}

@Suite("Understander")
struct UnderstanderTests {
    @Test func agreementTakesTheFastPathWithoutRepair() async throws {
        let model = FakeStructuredModel.reading("volume up", "high")
        let result = try await understander([FakeHearer(.scribe, "Volume up"), FakeHearer(.gemini, "volume up."), FakeHearer(.apple, "volume up")], model: model)
            .understand(turn, context: .init())
        #expect(result.decision == .act(text: "Volume up"))
        #expect(result.reading == nil && model.callCount == 0)
        #expect(result.hypotheses.map(\.hearer) == [.scribe, .gemini, .apple])
    }

    @Test func disagreementIsRepairedThenDecidedInCode() async throws {
        let model = FakeStructuredModel.reading("message Mum", "medium")
        let result = try await understander([FakeHearer(.scribe, "message mom"), FakeHearer(.gemini, "massage Mum")], model: model)
            .understand(turn, context: .init(frontApp: "WhatsApp"))
        #expect(result.decision == .confirm(question: "Message Mum?", reading: "message Mum"))
        #expect(result.reading?.confidence == .medium && model.callCount == 1)
        #expect(model.lastInput.contains("<front_app>WhatsApp</front_app>"))
    }

    @Test func aSlowRecogniserIsLeftBehind() async throws {
        let start = Date()
        let result = try await understander([FakeHearer(.scribe, "scroll down"), FakeHearer(.gemini, "scroll down", delaySeconds: 3), FakeHearer(.apple, "scroll down")])
            .understand(turn, context: .init())
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(result.hypotheses[1].failure?.contains("timed out") == true && result.hypotheses[1].text.isEmpty)
        #expect(result.decision == .act(text: "scroll down"))  // the other two agree
    }

    @Test func aFailingRecogniserBecomesAFailedHypothesis() async throws {
        let result = try await understander([FakeHearer(.scribe, error: SpeakableError("Scribe is down.")), FakeHearer(.apple, "open mail")])
            .understand(turn, context: .init())
        #expect(result.hypotheses[0].failure == "Scribe is down.")
        #expect(result.decision == .confirm(question: "Open mail?", reading: "open mail"))  // no repair model: confirm what was heard
    }

    @Test func everythingDownCannotHear() async throws {
        let model = FakeStructuredModel.reading("x", "high")
        let result = try await understander([FakeHearer(.scribe, error: SpeakableError("down")), FakeHearer(.gemini, delaySeconds: 2), FakeHearer(.apple, "")], model: model)
            .understand(turn, context: .init())
        #expect(result.decision == .cannotHear(message: "I can't hear properly right now."))
        #expect(model.callCount == 0)
    }

    @Test func slowOrFailedRepairFallsBackToTheScribeText() async throws {
        let failing = FakeStructuredModel(answer: nil)
        let slow = FakeStructuredModel(answer: ["text": "call Sam", "confidence": "high", "alternatives": [], "reason": ""], delaySeconds: 3)
        for model in [failing, slow] {
            let start = Date()
            let result = try await understander([FakeHearer(.scribe, "call some"), FakeHearer(.gemini, "cool sum")], model: model)
                .understand(turn, context: .init())
            #expect(Date().timeIntervalSince(start) < 2 && model.callCount == 1)
            #expect(result.reading == nil && result.decision == .confirm(question: "Call some?", reading: "call some"))
        }
    }

    @Test func stopIsNeverDelayedByRepair() async throws {
        let model = FakeStructuredModel(answer: nil, delaySeconds: 5)
        let result = try await understander([FakeHearer(.scribe, "stop"), FakeHearer(.gemini, "top hmm")], model: model)
            .understand(turn, context: .init(pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"]))
        #expect(result.decision == .act(text: "stop") && model.callCount == 0 && result.seconds < 1)
    }

    @Test func aConfirmedGarbleIsCaughtNextTime() async throws {
        let book = try Phrasebook.inMemory()
        let model = FakeStructuredModel.reading("call Sam", "high")
        let hearers: [any Hearing] = [FakeHearer(.scribe, "call some"), FakeHearer(.gemini, "cool sum"), FakeHearer(.apple, "call some")]
        let layer = try understander(hearers, model: model, phrasebook: book)

        let first = await layer.understand(turn, context: .init())
        #expect(first.phrasebookMatch == nil && first.decision == .confirm(question: "Call Sam?", reading: "call Sam"))
        await layer.learn(from: turn, result: first, outcome: .confirmed(meant: "call Sam"))

        let second = await layer.understand(turn, context: .init())
        #expect(second.phrasebookMatch?.meant == "call Sam" && second.phrasebookMatch?.timesConfirmed == 1)
        #expect(second.decision == .confirm(question: "Call Sam?", reading: "call Sam"))  // learned once: asked once more
        await layer.learn(from: turn, result: second, outcome: .confirmed(meant: "call Sam"))

        let callsBefore = model.callCount
        let third = await layer.understand(turn, context: .init())
        #expect(third.decision == .act(text: "call Sam"))  // learned twice: acts, without asking Claude
        #expect(model.callCount == callsBefore && third.reading == nil)
    }

    @Test func learningStoresTheClipAndFeedsTheNextHints() async throws {
        let book = try Phrasebook.inMemory()
        let scribe = FakeHearer(.scribe, "message mom")
        let layer = try understander([scribe, FakeHearer(.gemini, "message Mum")], phrasebook: book)
        let result = await layer.understand(turn, context: .init())
        await layer.learn(from: turn, result: result, outcome: .corrected(meant: "message Mum"))
        let entries = try book.entries(includingAudio: true)
        #expect(entries.count == 1 && entries[0].source == .correction && entries[0].wav == turn.wav)

        _ = await layer.understand(turn, context: .init())
        #expect(scribe.lastHints?.keyterms.prefix(3) == ["message Mum", "message", "Mum"])
        #expect(scribe.lastHints?.examples == [SpeechExample(wav: turn.wav, text: "message Mum")])
    }

    @Test func warmUpRunsEveryHearerOnceAndChangesNothing() async throws {
        let book = try Phrasebook.inMemory()
        let scribe = FakeHearer(.scribe, "hello"), apple = FakeHearer(.apple, error: SpeakableError("loading"))
        let layer = try understander([scribe, apple], phrasebook: book)
        await layer.warmUp().value
        #expect(scribe.lastHints != nil && apple.lastHints != nil && scribe.lastHints?.keyterms.isEmpty == true)
        #expect(book.count == 0 && layer.consecutiveFailedTries == 0)
    }

    @Test func aRejectedTurnLearnsNothing() async throws {
        let book = try Phrasebook.inMemory()
        let layer = try understander([FakeHearer(.scribe, "call some")], phrasebook: book)
        let result = await layer.understand(turn, context: .init())
        await layer.learn(from: turn, result: result, outcome: .rejected)
        #expect(book.count == 0 && layer.consecutiveFailedTries == 1)  // counted once, by the question
    }

    @Test func repeatedFailuresSwitchToYesNoQuestions() async throws {
        let model = FakeStructuredModel.reading("message Mum", "low", alternatives: ["message Sam"])
        let layer = try understander([FakeHearer(.scribe, "message mom"), FakeHearer(.gemini, "message some")], model: model)
        #expect(await layer.understand(turn, context: .init()).decision == .choose(question: "Mum or Sam?", options: ["message Mum", "message Sam"]))
        #expect(await layer.understand(turn, context: .init()).decision == .choose(question: "Mum or Sam?", options: ["message Mum", "message Sam"]))
        #expect(await layer.understand(turn, context: .init()).decision == .confirm(question: "Message Mum?", reading: "message Mum"))
        #expect(layer.consecutiveFailedTries == 3)
    }
}

@Suite("Understander stage switches")
struct UnderstanderSwitchTests {
    private func book() throws -> Phrasebook {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, wav: Data([7]), source: .enrolment)
        return book
    }

    @Test func keytermsCombineAnswersPhrasebookAppWordsAndScreen() async throws {
        let scribe = FakeHearer(.scribe, "hi")
        _ = try await understander([scribe], phrasebook: book(), { $0.extraKeyterms = ["Priya", "sam"] })
            .understand(turn, context: .init(screenLabels: ["Send", "", "Priya"], expectedAnswers: ["yes", "no"]))
        #expect(scribe.lastHints?.keyterms == ["yes", "no", "call Sam", "call", "Sam", "Priya", "Send"])
        #expect(scribe.lastHints?.languageCode == "en-GB")
    }

    @Test func eachSwitchTurnsItsStageOff() async throws {
        let scribe = FakeHearer(.scribe, "call some"), model = FakeStructuredModel.reading("call Sam", "high")
        let off = try understander([scribe, FakeHearer(.gemini, "cool sum")], model: model, phrasebook: book()) {
            $0.useKeyterms = false; $0.useExamples = false; $0.useRepair = false; $0.usePhrasebook = false
        }
        let result = await off.understand(turn, context: .init(screenLabels: ["Send"]))
        #expect(scribe.lastHints?.keyterms.isEmpty == true && scribe.lastHints?.examples.isEmpty == true)
        #expect(result.phrasebookMatch == nil && result.reading == nil && model.callCount == 0)

        let noPhrasebook = FakeHearer(.scribe, "hi")
        _ = try await understander([noPhrasebook], phrasebook: book(), { $0.usePhrasebook = false; $0.extraKeyterms = ["Priya"] })
            .understand(turn, context: .init())
        #expect(noPhrasebook.lastHints?.keyterms == ["Priya"] && noPhrasebook.lastHints?.examples.count == 1)

        let withoutModel = try await understander([FakeHearer(.scribe, "call some"), FakeHearer(.gemini, "cool sum")], model: nil)
            .understand(turn, context: .init())
        #expect(withoutModel.reading == nil)
    }
}
