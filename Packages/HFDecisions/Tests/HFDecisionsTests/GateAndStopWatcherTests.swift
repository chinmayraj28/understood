import Foundation
import HFCore
import Testing
@testable import HFDecisions

/// A risk classifier that always gives the same verdict and remembers what it was asked.
final class FixedRiskClassifier: RiskClassifying, @unchecked Sendable {
    let verdict: Risk
    private let lock = NSLock()
    private var asked: [String] = []
    init(_ verdict: Risk) { self.verdict = verdict }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    private func note(_ action: String) { lock.lock(); asked.append(action); lock.unlock() }
    func classifyRisk(_ action: ScreenAction) async -> Decision<Risk> {
        note(action.description)
        return Decision(label: verdict, confidence: 0.99, source: .jev)
    }
}

@Suite("Safety gate")
struct SafetyGateTests {
    @Test(arguments: [
        (click(.button, "Buy now", app: "Google Chrome", window: "Kettle - Shop"), "payment or purchase"),
        (click(.button, "Delete event", app: "Google Chrome", window: "Google Calendar"), "deletion"),
        (click(.menuItem, "Empty Bin…", app: "Finder"), "deletion"),
        (whatsAppSend, "sends to people"),
        (ScreenAction(kind: .pressKey, key: KeyChord("return"), target: whatsAppBox), "message box"),
        (ScreenAction(kind: .typeLineBreak, target: whatsAppBox), "line break"),
        (click(.button, "Done", app: "Google Chrome", window: "Google Calendar - Event details"), "calendar"),
        (click(.button, app: "WhatsApp", window: "WhatsApp"), "unlabelled"),
        (clickUnknown(in: "WhatsApp", window: "WhatsApp"), "unknown"),
    ])
    func fixedRulesAskWithoutConsultingTheClassifier(action: ScreenAction, category: String) async {
        let classifier = FixedRiskClassifier(.safe)
        let decision = await SafetyGate(classifier: classifier).check(action)
        #expect(decision.label == .needsConfirmation)
        #expect(decision.source == .rule)
        #expect(decision.reason.contains(category), "\(decision.reason)")
        #expect(classifier.calls.isEmpty)
    }

    @Test func otherActionsGoToTheClassifier() async {
        let classifier = FixedRiskClassifier(.safe)
        let decision = await SafetyGate(classifier: classifier).check(click(.link, "Inbox", app: "Google Chrome", window: "Gmail"))
        #expect(decision.label == .safe)
        #expect(classifier.calls.count == 1)
    }

    @Test(arguments: ["error", "timeout", "low confidence", "just under"])
    func asksWhenJevIsUnsureOrUnavailable(jev: String) async {
        let subject: Classifiers = switch jev {
        case "error": classifiers(.failing)
        case "timeout": classifiers(.slow(seconds: 1), timeoutSeconds: 0.1)
        case "low confidence": classifiers(riskSays(safe: 0.6))
        default: classifiers(riskSays(safe: 0.89))
        }
        let decision = await SafetyGate(classifier: subject).check(RiskTests.neutral)
        #expect(decision.label == .needsConfirmation, "\(jev)")
    }

    @Test func auditLogIsNewestFirstAndBounded() async {
        let gate = SafetyGate(classifier: FixedRiskClassifier(.safe), auditCapacity: 3)
        for action in [click(.tab, "A", app: "Finder"), click(.button, "Buy now", app: "Google Chrome"),
                       click(.tab, "B", app: "Finder"), click(.tab, "C", app: "Finder")] {
            _ = await gate.check(action)
        }
        let recent = gate.recent(10)
        #expect(recent.map(\.action) == ["Click tab \"C\" in Finder", "Click tab \"B\" in Finder", "Click button \"Buy now\" in Google Chrome"])
        #expect(recent[2].verdict == .needsConfirmation)
        #expect(recent[2].source == .rule)
    }

    @Test func auditLogCanBeReadWhileChecking() async {
        let gate = SafetyGate(classifier: FixedRiskClassifier(.safe))
        let reader = Task.detached { for _ in 0..<500 { _ = gate.recent() } }
        for _ in 0..<50 { _ = await gate.check(click(.tab, "A", app: "Finder")) }
        await reader.value
        #expect(gate.recent(100).count == 50)
    }
}

/// A pretend task runner for the stop watcher.
final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var taskID: String
    private var awaitingAnswer: Bool
    private var cancellations = 0

    init(running: Bool = true, taskID: String = "A", awaitingAnswer: Bool = false) {
        self.running = running
        self.taskID = taskID
        self.awaitingAnswer = awaitingAnswer
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var isAwaiting: Bool { lock.lock(); defer { lock.unlock() }; return awaitingAnswer }
    var currentID: String? { lock.lock(); defer { lock.unlock() }; return running ? taskID : nil }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    func cancel() { lock.lock(); cancellations += 1; running = false; lock.unlock() }
    func start(_ id: String) { lock.lock(); taskID = id; running = true; lock.unlock() }
    func setRunning(_ value: Bool) { lock.lock(); running = value; lock.unlock() }
}

/// An utterance classifier that answers after a delay and counts its calls.
final class StubUtteranceClassifier: UtteranceClassifying, @unchecked Sendable {
    let label: Intent
    let delaySeconds: Double
    private let lock = NSLock()
    private var seen: [(String, UtteranceContext)] = []
    init(_ label: Intent, delaySeconds: Double = 0) {
        self.label = label
        self.delaySeconds = delaySeconds
    }
    var calls: [(String, UtteranceContext)] { lock.lock(); defer { lock.unlock() }; return seen }
    private func note(_ text: String, _ context: UtteranceContext) { lock.lock(); seen.append((text, context)); lock.unlock() }
    func classifyUtterance(_ text: String, context: UtteranceContext) async -> Decision<Intent> {
        note(text, context)
        if delaySeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1e9)) }
        return Decision(label: label, confidence: 0.9, source: .jev)
    }
}

func makeWatcher(_ runner: FakeRunner, _ classifier: UtteranceClassifying) -> StopWatcher {
    StopWatcher(
        classifier: classifier,
        isTaskRunning: { runner.isRunning },
        isAwaitingAnswer: { runner.isAwaiting },
        currentTaskID: { runner.currentID },
        cancel: { runner.cancel() })
}

@Suite("Stop watcher")
struct StopWatcherTests {
    @Test func doesNotBlockTheVoiceThread() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel, delaySeconds: 0.5))
        let start = ContinuousClock.now
        #expect(watcher.heard("that's the wrong person, quit it") == nil)
        #expect(elapsedMilliseconds(since: start) < 50)
        #expect(runner.cancelCount == 0)  // the answer has not come back yet
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(runner.cancelCount == 1)
    }

    @Test func anExactStopCancelsInstantlyWithoutTheClassifier() async {
        let runner = FakeRunner()
        let classifier = StubUtteranceClassifier(.other)
        let watcher = makeWatcher(runner, classifier)
        let start = ContinuousClock.now
        let decision = watcher.heard("stop... stop it")
        #expect(decision?.label == .cancel)
        #expect(decision?.source == .rule)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 1)
        #expect(classifier.calls.isEmpty)
        #expect(elapsedMilliseconds(since: start) < 200)
    }

    @Test func stopTheMusicDoesNotCancel() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.command))
        #expect(watcher.heard("stop the music") == nil)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 0)
    }

    @Test func nothingRunningMeansNothingHappens() async {
        let runner = FakeRunner(running: false)
        let classifier = StubUtteranceClassifier(.cancel)
        let watcher = makeWatcher(runner, classifier)
        #expect(watcher.heard("stop") == nil)
        #expect(watcher.heard("no wait, that's wrong") == nil)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 0)
        #expect(classifier.calls.isEmpty)
    }

    @Test func anAnswerToAQuestionDoesNotCancel() async {
        let runner = FakeRunner(awaitingAnswer: true)
        let classifier = StubUtteranceClassifier(.other)
        let watcher = makeWatcher(runner, classifier)
        for text in ["no", "wait", "hang on", "Shah", "yes send it"] {
            let decision = watcher.heard(text)
            #expect(decision == nil || decision?.label != .cancel, "\(text)")
        }
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 0)
        #expect(classifier.calls.allSatisfy { $0.1.awaitingAnswer })
    }

    @Test func aLateAnswerDoesNotCancelANewerTask() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel, delaySeconds: 0.3))
        watcher.heard("ugh, that's not it")
        runner.start("B")  // task A finished and B started before the answer came back
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(runner.cancelCount == 0)
    }

    /// The integration tester's sequence: "please stop doing it like that" while A runs
    /// goes to Jev; A finishes and B starts; Jev's cancel arrives late and must not hit B.
    @Test func aLateCancelVerdictDoesNotHitTheTaskThatStartedAfterTheSentence() async {
        let runner = FakeRunner(taskID: "A")
        let classifier = StubUtteranceClassifier(.cancel, delaySeconds: 0.3)
        let watcher = makeWatcher(runner, classifier)
        #expect(watcher.heard("please stop doing it like that") == nil)  // not an exact phrase: Jev decides
        runner.setRunning(false)  // A finishes
        runner.start("B")  // B starts before the verdict
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(classifier.calls.count == 1)
        #expect(runner.cancelCount == 0)
        #expect(runner.currentID == "B")
    }

    @Test func aLateCancelVerdictAfterTheTaskEndedDoesNothing() async {
        let runner = FakeRunner(taskID: "A")
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel, delaySeconds: 0.2))
        watcher.heard("ugh, not like that")
        runner.setRunning(false)
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(runner.cancelCount == 0)
    }

    @Test func aSecondStopForTheSameTaskDoesNotCancelTwice() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel, delaySeconds: 0.2))
        watcher.heard("hmm, not that one")  // slow path, spoken first
        watcher.heard("stop")  // instant cancel, spoken second
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(runner.cancelCount == 1)
    }

    @Test func declineWhileAskedKeepsTheTaskButEndingPhrasesStillCancel() async {
        let runner = FakeRunner(awaitingAnswer: true)
        let classifier = StubUtteranceClassifier(.other)
        let watcher = makeWatcher(runner, classifier)
        for text in ["No, don't", "don't", "cancel that", "I said no", "no, don't, say fifteen minutes"] {
            #expect(watcher.heard(text)?.label != .cancel, "\(text)")
        }
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 0)
        #expect(watcher.heard("stop everything")?.label == .cancel)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 1)
    }

    @Test func aBurstOfSentencesCancelsOnce() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel, delaySeconds: 0.1))
        let start = ContinuousClock.now
        for text in ["no that's wrong", "wrong one", "argh", "not that", "please no"] { watcher.heard(text) }
        #expect(elapsedMilliseconds(since: start) < 50)
        #expect(await watcher.waitUntilIdle(timeoutSeconds: 3))
        #expect(runner.cancelCount == 1)
    }

    @Test func recordsTheLastDecision() async {
        let runner = FakeRunner()
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.command))
        watcher.heard("pause Spotify")
        #expect(await watcher.waitUntilIdle())
        #expect(watcher.lastDecision?.label == .command)
    }
}

@Suite("Golden examples")
struct GoldenExampleTests {
    @Test func bundledCopyMatchesTheMasterInFixtures() throws {
        let master = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jev_golden.jsonl")
        let bundled = try #require(GoldenExample.bundledURL)
        #expect(try Data(contentsOf: master) == Data(contentsOf: bundled),
                "copy Fixtures/jev_golden.jsonl to Sources/HFDecisions/Resources/")
    }

    /// The fixed rules decide without Jev, so they must never contradict a golden label: an
    /// always-ask rule may not fire on a safe example, and the plainly-safe rule may not fire on
    /// a risky one. Catches drift from shared code such as HFCore's word splitting.
    @Test func noFixedRuleContradictsAGoldenLabel() throws {
        var ruled = 0
        for example in try GoldenExample.bundled() where example.classifier == .risk {
            let action = try #require(example.screenAction)
            if let category = RiskRules.alwaysAsk(action) {
                ruled += 1
                #expect(example.accepts(Risk.needsConfirmation.rawValue), "asks (\(category)) on safe: \(action.description)")
            } else if RiskRules.isPlainlySafe(action) {
                ruled += 1
                #expect(example.accepts(Risk.safe.rawValue), "plainly safe on risky: \(action.description)")
            }
        }
        #expect(ruled > 90)
    }

    @Test func everyExampleDecodesAndIsWellFormed() throws {
        let examples = try GoldenExample.bundled()
        #expect(examples.count >= 200)
        for example in examples {
            #expect(!example.input.isEmpty)
            switch example.classifier {
            case .utterance: #expect(Intent(rawValue: example.expected) != nil)
            case .risk:
                #expect(Risk(rawValue: example.expected) != nil)
                #expect(example.screenAction != nil, "\(example.input)")
                if example.kind == .pressKey { #expect(example.screenAction?.key != nil) }
            case .answer:
                #expect(Answer(rawValue: example.expected) != nil)
                #expect(example.question != nil)
            }
        }
        for kind in [GoldenExample.Classifier.utterance, .risk, .answer] {
            #expect(examples.contains { $0.classifier == kind && $0.split == "holdout" })
        }
    }
}
