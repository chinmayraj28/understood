import Foundation
import HFCore
import HFDecisions
import HFTasks
import Testing

let isLive = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"

// The real SafetyGate and the real answer classifier (HFDecisions) inside the
// runner's confirm path, and the real StopWatcher driving the runner's cancel.
// Keyword fallback by default; live Jev only with HF_LIVE=1.
@Suite(.serialized) struct DecisionsIntegrationTests {

    static let goal = TaskFlowTests.goal

    /// Plays 4b up to the Send confirmation.
    static func reachConfirmation(_ rig: Rig) async throws -> TaskEvent {
        await rig.call("start_task", ["goal": .string(goal)])
        _ = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        await rig.call("answer_task", ["answer": "Priya Shah"])
        return try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
    }

    @Test("Real gate: the guests field is plainly safe, the Send click is held by a fixed rule")
    func gateDecisions() async throws {
        let classifiers = Classifiers(client: nil)
        let gate = SafetyGate(classifier: classifiers)
        let rig = Rig(gate: gate, classifier: classifiers) { InviteFlowExecutor(hands: $0) }
        _ = try await Self.reachConfirmation(rig)

        let audit = gate.recent(10)
        let guests = try #require(audit.first { $0.action.contains("Add guests") })
        #expect(guests.verdict == .safe && guests.source == .rule)
        let send = try #require(audit.first { $0.action.contains("\"Send\"") })
        #expect(send.verdict == .needsConfirmation)
        #expect(send.source == .rule, "a Send button must be held by a fixed rule, not only because Jev is off: \(send.reason)")

        await rig.call("answer_task", ["answer": "yes"])
        #expect(await rig.recorder.waitFor(.result)?.status == .done)
        #expect(rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("Real answer classifier: clear yeses proceed", arguments: ["yes", "Yes.", "yeah go for it", "send it", "yes please"])
    func clearYes(reply: String) async throws {
        let classifiers = Classifiers(client: nil)
        let rig = Rig(gate: SafetyGate(classifier: classifiers), classifier: classifiers) { InviteFlowExecutor(hands: $0) }
        _ = try await Self.reachConfirmation(rig)
        await rig.call("answer_task", ["answer": .string(reply)])
        // Either it proceeds at once, or (if the two word lists disagree) it asks again; it must not decline.
        let outcome = await waitUntil {
            rig.recorder.events.contains { $0.kind == .result } || rig.recorder.events.filter { $0.kind == .confirmation }.count == 2
        }
        #expect(outcome)
        #expect(rig.recorder.events.filter { $0.kind == .confirmation }.count == 1,
                "\"\(reply)\" should be a clear yes for both the runner's word list and HFDecisions' fallback")
        #expect(rig.recorder.events.last?.text == "Sent the invite to Priya Shah.")
    }

    @Test("Real answer classifier: no, corrections and hesitation never send",
          arguments: ["no", "nope", "no, not yet", "wait, change the time", "hmm", "maybe later"])
    func notYes(reply: String) async throws {
        let classifiers = Classifiers(client: nil)
        let rig = Rig(gate: SafetyGate(classifier: classifiers), classifier: classifiers) { InviteFlowExecutor(hands: $0) }
        _ = try await Self.reachConfirmation(rig)
        await rig.call("answer_task", ["answer": .string(reply)])
        // An unclear reply is asked once more; answer that with silence-like hesitation too.
        if await rig.recorder.waitFor(.confirmation, number: 2, timeout: 0.5) != nil {
            await rig.call("answer_task", ["answer": "um"])
        }
        #expect(await rig.recorder.waitFor(.result)?.text == "I didn't send the invite.")
        #expect(!rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("Live Jev: the same flow with the real classifier", .enabled(if: isLive, "set HF_LIVE=1 to call Jev"))
    func liveJev() async throws {
        let settings = Settings.load()
        try #require(settings.isJevEnabled, "OPENROUTER_API_KEY is not set")
        let classifiers = Classifiers(settings: settings)
        _ = await classifiers.client?.warmUp()
        let gate = SafetyGate(classifier: classifiers)
        let rig = Rig(gate: gate, classifier: classifiers) { InviteFlowExecutor(hands: $0) }
        _ = try await Self.reachConfirmation(rig)
        #expect(gate.recent(10).first { $0.action.contains("\"Send\"") }?.verdict == .needsConfirmation)
        await rig.call("answer_task", ["answer": "yeah, go ahead and send it"])
        #expect(await rig.recorder.waitFor(.result, timeout: 5)?.status == .done)
        #expect(rig.hands.actions.items.contains("click 900,120"))
    }

    // MARK: StopWatcher

    /// The watcher wired the way the app should wire it (see the review note on currentTaskID).
    static func watcher(for rig: Rig, classifier: UtteranceClassifying = Classifiers(client: nil)) -> StopWatcher {
        let runner = rig.runner
        return StopWatcher(
            classifier: classifier,
            isTaskRunning: { runner.isRunning },
            isAwaitingAnswer: { runner.isAwaitingAnswer },
            currentTaskID: { runner.status()["task_id"]?.stringValue },
            cancel: { _ = runner.cancel(taskID: nil) })
    }

    @Test("Spoken \"stop\" during a long glide cancels the task and freezes the hands")
    func stopDuringGlide() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0, gliding: 5) }
        let watcher = Self.watcher(for: rig)
        _ = try await Self.reachConfirmation(rig)
        await rig.call("answer_task", ["answer": "yes"])
        #expect(await waitUntil {
            rig.activity.events.contains { if case .pointerMoving(_, let duration) = $0 { duration == 5 } else { false } }
        })
        let begin = ContinuousClock.now
        watcher.heard("stop")
        #expect(await waitUntil(timeout: 1) { rig.recorder.events.last?.status == .cancelled })
        #expect(secondsSince(begin) < 1)
        #expect(await waitUntil(timeout: 1) { rig.hands.actions.items.last == "resume" })
        #expect(!rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("A bare \"no\" to a confirmation is an answer, not a cancel")
    func bareNoIsAnAnswer() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        let watcher = Self.watcher(for: rig)
        _ = try await Self.reachConfirmation(rig)
        // The voice session must call the watcher BEFORE passing the sentence on as an answer.
        watcher.heard("no")
        _ = await watcher.waitUntilIdle(timeoutSeconds: 2)
        #expect(rig.runner.isRunning, "the watcher must leave the task alone")
        await rig.call("answer_task", ["answer": "no"])
        #expect(await rig.recorder.waitFor(.result)?.text == "I didn't send the invite.")
        #expect(rig.recorder.events.last?.status == .done)
    }

    @Test("\"Stop the music\" is a command, not a cancel")
    func stopTheMusic() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        let watcher = Self.watcher(for: rig)
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        watcher.heard("stop the music")
        _ = await watcher.waitUntilIdle(timeoutSeconds: 2)
        #expect(rig.runner.isRunning)
    }

    /// A Jev stand-in that takes its time and then says "cancel".
    struct SlowCancelClassifier: UtteranceClassifying {
        func classifyUtterance(_ text: String, context: UtteranceContext) async -> Decision<Intent> {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Decision(label: .cancel, confidence: 0.95, source: .jev)
        }
    }

    /// Task 1 asks a question; the user mutters "ugh, please stop that"; before Jev answers,
    /// task 1 is answered and finishes and task 2 starts. Returns whether task 2 survived.
    static func lateVerdictScenario() async throws -> Bool {
        let rig = Rig { hands in
            ScriptedFlow { context in
                _ = try await context.askUser("Which account?", options: [])
                return "Done."
            } then: { context in
                _ = try await context.askUser("Priya Shah or Priya Patel?", options: [])
                return "Done."
            }
        }
        let watcher = watcher(for: rig, classifier: SlowCancelClassifier())
        await rig.call("start_task", ["goal": "first"])
        _ = try #require(await rig.recorder.waitFor(.question))
        watcher.heard("ugh, please stop that")  // goes to the slow classifier
        await rig.call("answer_task", ["answer": "work"])
        _ = try #require(await rig.recorder.waitFor(.result))
        #expect(await waitUntil { rig.call_sync_start("second") })
        _ = await watcher.waitUntilIdle(timeoutSeconds: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        return rig.runner.isRunning && rig.runner.status()["task_id"]?.stringValue == "t2"
    }

    @Test("A late cancel verdict never stops a newer task")
    func lateVerdictSpared() async throws {
        #expect(try await Self.lateVerdictScenario())
    }
}
