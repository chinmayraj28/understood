import Foundation
import HFCore
import Testing
@testable import HFUnderstand

/// A stand-in for the understanding layer: answers from a table keyed by the clip's source.
final class FakeUnderstanding: Understanding, @unchecked Sendable {
    let answers: [String: UnderstandingDecision]
    let heard: [String: String]
    private let lock = NSLock()
    private(set) var learned: [(source: String, outcome: TurnOutcome)] = []

    init(answers: [String: UnderstandingDecision], heard: [String: String] = [:]) {
        self.answers = answers
        self.heard = heard
    }

    func understand(_ turn: RecordedTurn, context: UnderstandingContext) async -> UnderstandingResult {
        let decision = answers[turn.source] ?? .cannotHear(message: "I can't hear properly right now.")
        let text = heard[turn.source] ?? ""
        return UnderstandingResult(
            hypotheses: [Hypothesis(hearer: .scribe, text: text, seconds: 0.5)],
            phrasebookMatch: nil, reading: nil, decision: decision, seconds: 1.0)
    }

    func learn(from turn: RecordedTurn, result: UnderstandingResult, outcome: TurnOutcome) async {
        lock.withLock { learned.append((turn.source, outcome)) }
    }
}

@Suite struct EvaluationRunnerTests {
    static func manifest() -> EvaluationManifest {
        func clip(_ id: String, _ speaker: String, _ prompt: String, _ split: EvaluationManifest.Split) -> EvaluationManifest.Clip {
            .init(id: id, speaker: speaker, session: "Session1", prompt: prompt, audio: "\(id).wav", split: split,
                  kind: WordErrorRate.words(prompt).count == 1 ? "word" : "sentence")
        }
        return EvaluationManifest(
            name: "fake", splitRule: "test rule",
            speakers: [.init(id: "F01", group: "dysarthric", severity: "severe"), .init(id: "FC01", group: "control", severity: "none")],
            clips: [
                clip("e1", "F01", "yes", .enrolment),
                clip("e2", "F01", "Open the door", .enrolment),
                clip("t1", "F01", "yes", .test),
                clip("t2", "F01", "The quick brown fox", .test),
                clip("t3", "F01", "open the door.", .test),
                clip("c1", "FC01", "no", .test),
            ])
    }

    static func runner(enrolmentLimit: Int? = nil) -> EvaluationRunner {
        EvaluationRunner(
            manifest: manifest(), manifestFolder: URL(fileURLWithPath: "/tmp"), enrolmentLimit: enrolmentLimit,
            loadTurn: { url in RecordedTurn(wav: Data(), durationSeconds: 1, source: url.deletingPathExtension().lastPathComponent) })
    }

    @Test func scoresEachDecision() async {
        let fake = FakeUnderstanding(
            answers: [
                "t1": .act(text: "Yes."),                          // correct action
                "t2": .act(text: "the quick brown socks"),         // wrong action
                "t3": .confirm(question: "Open the door?", reading: "open the door"),  // asked
            ],
            heard: ["t1": "yes", "t2": "the quick brown socks", "t3": "open the floor", "c1": ""])
        let setup = EvaluationSetup(name: "fake", summary: "a fake") { _, _ in fake }
        let runner = Self.runner()
        let records = await runner.run(setups: [setup], testClips: runner.selectTestClips(limit: nil))
        #expect(records.count == 4)

        let all = EvaluationReport.summarise(records, setup: "fake", scope: "all")
        #expect(all.clips == 4)
        #expect(all.correctActionRate == 0.25)
        #expect(all.wrongActionRate == 0.25)
        #expect(all.askRate == 0.25)
        #expect(all.cannotHearRate == 0.25)
        #expect(all.exactMatchRate == 0.5)     // t1 and t3
        #expect(all.meanSeconds == 1.0)
        // Final: t1 0/1, t2 1/4, t3 0/3, c1 1/1 -> 2 errors in 9 words.
        #expect(abs(all.finalWER - 2.0 / 9.0) < 1e-9)
        // Scribe: t1 0, t2 1, t3 1, c1 1 -> 3 in 9.
        #expect(abs((all.hearerWER["scribe"] ?? -1) - 3.0 / 9.0) < 1e-9)
    }

    @Test func labelsSeenAndUnseenPrompts() async {
        let fake = FakeUnderstanding(answers: [:])
        let setup = EvaluationSetup(name: "s", summary: "") { _, _ in fake }
        let runner = Self.runner()
        let records = await runner.run(setups: [setup], testClips: runner.selectTestClips(limit: nil))
        let seen = Dictionary(uniqueKeysWithValues: records.map { ($0.clip, $0.promptSeen) })
        #expect(seen["t1"] == true)    // "yes" was enrolled
        #expect(seen["t3"] == true)    // "open the door." matches "Open the door" after normalising
        #expect(seen["t2"] == false)
        #expect(seen["c1"] == false)
    }

    @Test func enrolmentLimitChangesWhatCountsAsSeen() {
        let runner = Self.runner(enrolmentLimit: 1)
        #expect(runner.seenPrompts(of: "F01") == ["yes"])
    }

    @Test func setupOnlyEverSeesItsOwnSpeakersEnrolmentClips() async {
        let given = Locked<[String: [String]]>([:])
        let setup = EvaluationSetup(name: "s", summary: "") { speaker, enrolment in
            given.update { $0[speaker] = enrolment.map(\.prompt) }
            return FakeUnderstanding(answers: [:])
        }
        let runner = Self.runner()
        _ = await runner.run(setups: [setup], testClips: runner.selectTestClips(limit: nil))
        #expect(given.value["F01"] == ["yes", "Open the door"])
        #expect(given.value["FC01"] == [])
    }

    @Test func selectionTakesTurnsAcrossSpeakersAndMixesSeen() {
        let picked = Self.runner().selectTestClips(limit: 3).map(\.id)
        // F01 seen first (t1), then FC01 (c1), then F01 unseen (t2).
        #expect(picked == ["t1", "c1", "t2"])
    }

    @Test func enrolHelperConfirmsEachPrompt() async {
        let fake = FakeUnderstanding(answers: [:])
        let turn = RecordedTurn(wav: Data(), durationSeconds: 1, source: "e1")
        await EvaluationRunner.enrol(fake, with: [EnrolmentClip(turn: turn, prompt: "yes")])
        #expect(fake.learned.count == 1)
        #expect(fake.learned.first?.outcome == .confirmed(meant: "yes"))
    }

    @Test func keytermsAreDistinctAndMostFrequentFirst() {
        let turn = RecordedTurn(wav: Data(), durationSeconds: 1, source: "x")
        let clips = ["no", "yes", "Yes.", "up"].map { EnrolmentClip(turn: turn, prompt: $0) }
        #expect(EvaluationRunner.keyterms(from: clips) == ["yes", "no", "up"])
    }

    @Test func markdownHasEveryTable() async throws {
        let fake = FakeUnderstanding(answers: ["t1": .act(text: "yes")])
        let setup = EvaluationSetup(name: "Scribe alone", summary: "baseline") { _, _ in fake }
        let runner = Self.runner()
        let records = await runner.run(setups: [setup], testClips: runner.selectTestClips(limit: nil))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = try EvaluationReport.write(records: records, setups: [setup], manifest: Self.manifest(), manifestName: "fake.json", folder: folder)
        let text = try String(contentsOf: out.markdown, encoding: .utf8)
        #expect(text.contains("## All test clips"))
        #expect(text.contains("| Scribe alone | 4 |"))
        #expect(text.contains("| F01 | severe |"))
        let decoded = try JSONDecoder().decode(EvaluationReport.File.self, from: Data(contentsOf: out.json))
        #expect(decoded.records.count == 4)
    }
}

/// A small thread-safe box for test bookkeeping.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Never answers in time: a stand-in for a call stuck in the network.
struct StalledUnderstanding: Understanding {
    func understand(_ turn: RecordedTurn, context: UnderstandingContext) async -> UnderstandingResult {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return UnderstandingResult(hypotheses: [], phrasebookMatch: nil, reading: nil, decision: .act(text: "yes"), seconds: 60)
    }
    func learn(from turn: RecordedTurn, result: UnderstandingResult, outcome: TurnOutcome) async {}
}

@Suite struct EvaluationTimeLimitTests {
    @Test func stalledClipIsCutOffAndScoredAsCannotHear() async {
        let setup = EvaluationSetup(name: "stalled", summary: "") { _, _ in StalledUnderstanding() }
        var runner = EvaluationRunnerTests.runner()
        runner.clipTimeLimitSeconds = 0.2
        let started = Date()
        let records = await runner.run(setups: [setup], testClips: Array(runner.selectTestClips(limit: 1)))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(records.count == 1)
        #expect(records[0].timedOut == true)
        #expect(records[0].decision == "cannotHear")
        let summary = EvaluationReport.summarise(records, setup: "stalled", scope: "all")
        #expect(summary.timedOut == 1)
        #expect(summary.wrongActionRate == 0)
        #expect(summary.correctActionRate == 0)
    }
}
