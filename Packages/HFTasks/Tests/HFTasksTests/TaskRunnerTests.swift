import Foundation
import HFCore
import Testing

@testable import HFTasks

// The scenarios of docs/TASKS.md section 14, by number. Serialized, because
// several tests measure how fast something happens.
@Suite(.serialized) struct TaskRunnerTests {

    // MARK: Main flow

    @Test("1. Full 4b flow: question, answer, confirmation, yes, done")
    func fullFlow() async throws {
        let executor = InviteExecutor()
        let bus = ActivityBus()
        let activity = Log<ActivityEvent>()
        let listening = Task { for await event in bus.events() { activity.append(event) } }
        try await Task.sleep(nanoseconds: 10_000_000)
        let (runner, recorder) = makeRunner(executor, activityBus: bus)
        defer { runner.shutdown(); listening.cancel() }

        let started = runner.start(goal: "Create a calendar event tomorrow 15:00 with Meet, invite Priya")
        #expect(started == ["ok": true, "task_id": "t1", "status": "running"])

        let question = try #require(await recorder.waitFor(.question))
        #expect(question.status == .needsInput)
        #expect(question.text == "Priya Shah or Priya Patel?")
        #expect(question.options == ["Priya Shah", "Priya Patel"])
        #expect(runner.status().string("question") == "Priya Shah or Priya Patel?")
        #expect(runner.isRunning && runner.isAwaitingAnswer)

        #expect(runner.answer("Priya Shah", taskID: "t1") == ["ok": true, "task_id": "t1", "status": "running"])
        let confirmation = try #require(await recorder.waitFor(.confirmation))
        #expect(confirmation.status == .needsInput && confirmation.options == ["yes", "no"])
        #expect(confirmation.text == "Is it OK to click button \"Send\" in Google Calendar, window \"Invite Priya Shah\"?")
        #expect(runner.status().string("waiting_for") == "confirmation")
        #expect(runner.status().string("action") == "Click button \"Send\" in Google Calendar, window \"Invite Priya Shah\"")
        #expect(!executor.sent.isSet)

        #expect(runner.answer("yes", taskID: nil).isOK)
        let result = try #require(await recorder.waitFor(.result))
        #expect(result.status == .done && result.text == "Sent the invite to Priya Shah.")
        #expect(executor.sent.isSet)

        let seen = recorder.events.map { "\($0.kind.rawValue)/\($0.status.rawValue)/\($0.text)" }
        #expect(seen == [
            "progress/running/Starting: Create a calendar event tomorrow 15:00 with Meet, invite Priya",
            "progress/running/Opening Google Calendar",
            "question/needs_input/Priya Shah or Priya Patel?",
            "progress/running/Got it: Priya Shah.",
            "confirmation/needs_input/Is it OK to click button \"Send\" in Google Calendar, window \"Invite Priya Shah\"?",
            "progress/running/Going ahead.",
            "result/done/Sent the invite to Priya Shah.",
        ])
        #expect(recorder.labels == ["com.handsfree.tasks.events"])
        let status = runner.status()
        #expect(status.string("status") == "done" && status["steps"] == 2)
        #expect(!runner.isRunning)

        // The companion saw the same story.
        #expect(await waitUntil { activity.items.contains { if case .taskEnded = $0 { true } else { false } } })
        #expect(activity.items == [
            .taskStarted(goal: "Create a calendar event tomorrow 15:00 with Meet, invite Priya"),
            .progress("Opening Google Calendar"),
            .waitingForAnswer(question: "Priya Shah or Priya Patel?"),
            .progress("Got it: Priya Shah."),
            .heldForConfirmation(action: "Is it OK to click button \"Send\" in Google Calendar, window \"Invite Priya Shah\"?"),
            .progress("Going ahead."),
            .taskEnded(status: .done, summary: "Sent the invite to Priya Shah."),
        ])
    }

    @Test("2. A simple task finishes")
    func simpleTask() async throws {
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            context.report("Opening Google Meet")
            try context.step()
            return "Meeting started."
        })
        defer { runner.shutdown() }
        _ = runner.start(goal: "Start an instant Google Meet")
        #expect(await recorder.waitFor(.result)?.text == "Meeting started.")
        #expect(runner.status().string("status") == "done")
    }

    @Test("3. An empty goal is refused")
    func emptyGoal() {
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, _ in "x" })
        defer { runner.shutdown() }
        #expect(runner.start(goal: "   ") == ["ok": false, "error": "The task needs a goal."])
        #expect(recorder.events.isEmpty)
    }

    // MARK: One task at a time

    @Test("4. Busy while running, free after cancel")
    func busyWhileRunning() async {
        let (runner, _) = makeRunner(ForeverExecutor())
        defer { runner.shutdown() }
        _ = runner.start(goal: "first goal")
        let second = runner.start(goal: "second goal")
        #expect(second.string("status") == "busy" && !second.isOK)
        #expect(second.string("task_id") == "t1" && second.string("goal") == "first goal")
        _ = runner.cancel(taskID: nil)
        #expect(await waitUntil { runner.start(goal: "second goal").string("task_id") == "t2" })
    }

    @Test("5. Busy while waiting for an answer")
    func busyWhileWaiting() async {
        let (runner, recorder) = makeRunner(ForeverExecutor(askFirst: true))
        defer { runner.shutdown() }
        _ = runner.start(goal: "first goal")
        _ = await recorder.waitFor(.question)
        #expect(runner.start(goal: "another").string("status") == "busy")
    }

    // MARK: Cancel

    @Test("6. Cancel while running is fast and summarises")
    func cancelWhileRunning() async throws {
        let executor = ForeverExecutor()
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "Find the cheapest train to Leeds")
        #expect(await executor.started.wait())

        let begin = ContinuousClock.now
        let result = runner.cancel(taskID: nil)
        #expect(elapsed(since: begin) < 0.2)
        #expect(result.isOK && result.string("status") == "cancelled" && result.string("task_id") == "t1")
        #expect(result.string("summary") == "Stopped. So far: Opening Chrome.")
        #expect(!runner.isRunning)

        #expect(await recorder.waitFor(.result, timeout: 1)?.status == .cancelled)
        #expect(await executor.cleanedUp.wait(timeout: 1))
        #expect(elapsed(since: begin) < 1)
    }

    @Test("7. Cancel while waiting for an answer")
    func cancelWhileWaiting() async {
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "Open my Google account")
        _ = await recorder.waitFor(.question)

        let begin = ContinuousClock.now
        #expect(runner.cancel(taskID: nil).string("status") == "cancelled")
        #expect(await executor.cleanedUp.wait(timeout: 1) && elapsed(since: begin) < 1)
        #expect(await recorder.waitFor(.result)?.status == .cancelled)
        #expect(!runner.answer("work", taskID: nil).isOK)
        #expect(executor.answers.items.isEmpty)
    }

    @Test("8. Cancel during a confirmation never sends")
    func cancelDuringConfirmation() async {
        let executor = InviteExecutor()
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "invite Priya")
        _ = await recorder.waitFor(.question)
        _ = runner.answer("Priya Shah", taskID: nil)
        _ = await recorder.waitFor(.confirmation)
        let summary = runner.cancel(taskID: nil).string("summary") ?? ""
        #expect(summary.contains("I did not go ahead with \"Is it OK to click button \"Send\" in Google Calendar"))
        #expect(await executor.cleanedUp.wait(timeout: 1))
        #expect(!executor.sent.isSet && executor.confirmResult.items.isEmpty)
    }

    @Test("9. Cancel with nothing running is not an error")
    func cancelNothing() {
        let (runner, _) = makeRunner(ScriptedExecutor { _, _ in "x" })
        defer { runner.shutdown() }
        let result = runner.cancel(taskID: nil)
        #expect(result == ["ok": true, "status": "not_running", "task_id": nil, "summary": "There's no task running."])
    }

    @Test("10. A stale id still stops the current task")
    func cancelStaleID() {
        let (runner, _) = makeRunner(ForeverExecutor())
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        let result = runner.cancel(taskID: "t99")
        #expect(result.string("status") == "cancelled" && result.string("task_id") == "t1")
        #expect(result.string("note") == "Task t99 was not running; stopped t1 instead.")
    }

    @Test("11. A cancel racing a finish gives exactly one result")
    func cancelRacesFinish() async {
        for _ in 0..<20 {
            let (runner, recorder) = makeRunner(ScriptedExecutor { _, _ in "done at once" })
            _ = runner.start(goal: "goal")
            _ = runner.cancel(taskID: nil)
            _ = await recorder.waitFor(.result)
            try? await Task.sleep(nanoseconds: 20_000_000)
            #expect(recorder.count(.result) == 1)
            runner.shutdown()
        }
    }

    @Test("12. An executor that ignores cancellation is abandoned and revoked")
    func stubbornExecutor() async {
        let executor = StubbornExecutor()
        let gate = FakeGate()
        let (runner, recorder) = makeRunner(executor, gate: gate)
        defer { executor.release.set(); runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())

        let begin = ContinuousClock.now
        #expect(runner.cancel(taskID: nil).string("status") == "cancelled")
        #expect(elapsed(since: begin) < 0.2)
        #expect(await waitUntil(timeout: 1) { runner.status()["stuck"] == true })

        // After it was stopped it tried to get a yes. It must never get one, and must not ask.
        #expect(await waitUntil(timeout: 1) { !executor.lateConfirm.items.isEmpty })
        #expect(executor.lateConfirm.items == ["refused"])
        #expect(recorder.count(.confirmation) == 0)
        #expect(gate.checked.items.isEmpty)

        // While it is alive, a new task is refused rather than handing it the hands.
        let refused = runner.start(goal: "next goal")
        #expect(refused.string("status") == "stuck" && !refused.isOK)

        // Once it finally ends, tasks run normally again.
        executor.release.set()
        #expect(await waitUntil { runner.start(goal: "next goal").isOK })
    }

    @Test("13. Cleanup that awaits something cancellable finishes at once")
    func cancellableCleanup() async {
        let started = Flag()
        let cleanupFinished = Flag()
        let (runner, _) = makeRunner(ScriptedExecutor { _, _ in
            started.set()
            do {
                try await Task.sleep(nanoseconds: 100_000_000_000)
            } catch {
                // Cancellation is sticky in Swift, so cancellable cleanup does not hang.
                try? await Task.sleep(nanoseconds: 100_000_000_000)
                cleanupFinished.set()
                throw error
            }
            return "never"
        })
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await started.wait())
        _ = runner.cancel(taskID: nil)
        #expect(await cleanupFinished.wait(timeout: 1))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(runner.status()["stuck"] == nil)
    }

    @Test("14. Cancel returns even if the executor blocks its thread")
    func blockingExecutor() async {
        let started = Flag()
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, _ in
            started.set()
            blockThread(0.4)  // a badly written executor holding its thread
            return "late"
        })
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await started.wait())
        let begin = ContinuousClock.now
        #expect(runner.cancel(taskID: nil).string("status") == "cancelled")
        #expect(elapsed(since: begin) < 0.1)
        #expect(!runner.isRunning)
        #expect(await recorder.waitFor(.result)?.status == .cancelled)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(recorder.count(.result) == 1)  // the late "late" is ignored
    }

    @Test("15. The halt hook runs first, once, and only for a live task")
    func haltHookComesFirst() async {
        let executor = ForeverExecutor()
        let observations = Log<String>()
        let recorder = EventRecorder()
        let runnerBox = Log<TaskRunner>()
        let (runner, _) = makeRunner(executor, recorder: recorder, onCancel: {
            let runner = runnerBox.items.first
            observations.append(
                "running=\(runner?.isRunning ?? false) results=\(recorder.count(.result)) executorSawCancel=\(executor.sawCancellation.isSet)")
        })
        runnerBox.append(runner)
        defer { runner.shutdown() }

        _ = runner.cancel(taskID: nil)  // nothing running: no halt
        #expect(observations.items.isEmpty)

        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        _ = runner.cancel(taskID: nil)
        #expect(observations.items == ["running=true results=0 executorSawCancel=false"])
        #expect(await executor.sawCancellation.wait())
    }

    @Test("16. The resume hook runs once, only after the executor has really ended")
    func resumeHook() async {
        // Done: after the result.
        let doneCalls = Log<String>()
        let (doneRunner, doneRecorder) = makeRunner(ScriptedExecutor { _, _ in "ok" }, onTaskEnd: { id, status in
            doneCalls.append("\(id) \(status.rawValue)")
        })
        _ = doneRunner.start(goal: "goal")
        _ = await doneRecorder.waitFor(.result)
        #expect(await waitUntil { doneCalls.items == ["t1 done"] })
        doneRunner.shutdown()

        // Cancelled: after the executor's cleanup ran.
        let forever = ForeverExecutor()
        let cancelCalls = Log<String>()
        let (cancelRunner, _) = makeRunner(forever, onTaskEnd: { id, status in
            cancelCalls.append("\(id) \(status.rawValue) cleanedUp=\(forever.cleanedUp.isSet)")
        })
        _ = cancelRunner.start(goal: "goal")
        #expect(await forever.started.wait())
        _ = cancelRunner.cancel(taskID: nil)
        #expect(await waitUntil { cancelCalls.items == ["t1 cancelled cleanedUp=true"] })
        cancelRunner.shutdown()

        // Abandoned: held back until the runaway executor finally ends.
        let stubborn = StubbornExecutor()
        let stuckCalls = Log<String>()
        let (stuckRunner, _) = makeRunner(stubborn, onTaskEnd: { id, status in
            stuckCalls.append("\(id) \(status.rawValue)")
        })
        _ = stuckRunner.start(goal: "goal")
        #expect(await stubborn.started.wait())
        _ = stuckRunner.cancel(taskID: nil)
        #expect(await waitUntil { stuckRunner.status()["stuck"] == true })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(stuckCalls.items.isEmpty)
        stubborn.release.set()
        #expect(await waitUntil { stuckCalls.items == ["t1 cancelled"] })
        stuckRunner.shutdown()
    }

    @Test("16b. A new task never launches, and the hands stay halted, while an old executor is alive")
    func runawayBlocksNextTask() async {
        let stubborn = StubbornExecutor()
        let launches = Log<String>()
        let taskEnds = Log<String>()
        let (runner, recorder) = makeRunner(
            ScriptedExecutor { goal, context in
                launches.append(goal)
                return try await stubborn.run(goal: goal, context: context)
            },
            onTaskEnd: { id, status in taskEnds.append("\(id) \(status.rawValue)") })
        defer { stubborn.release.set(); runner.shutdown() }
        _ = runner.start(goal: "first")
        #expect(await stubborn.started.wait())
        _ = runner.cancel(taskID: nil)

        // Started inside the grace period: accepted, but it waits, and fails when the old one won't stop.
        #expect(runner.start(goal: "second").string("task_id") == "t2")
        let second = await recorder.waitFor { $0.taskID == "t2" && $0.kind == .result }
        #expect(second?.status == .failed && second?.text == TaskRunner.stuckMessage)
        #expect(launches.items == ["first"])  // the second executor never ran
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(taskEnds.items.isEmpty)  // hands still halted: the runaway is alive

        stubborn.release.set()
        #expect(await waitUntil { taskEnds.items.count == 2 })
        #expect(Set(taskEnds.items) == ["t1 cancelled", "t2 failed"])
    }

    @Test("17. Limits, timeouts and shutdown halt the hands before stopping the executor")
    func forcedEndingsHalt() async {
        func check(
            _ name: String, configure: @escaping (inout TaskRunner.Configuration) -> Void,
            clock: FakeClock? = nil, askFirst: Bool = false, steps: Bool = false,
            trigger: @escaping (TaskRunner, FakeClock?) async -> Void
        ) async {
            let sawCancel = Flag()
            let started = Flag()
            let halts = Log<Bool>()
            let executor = ScriptedExecutor { _, context in
                try await withTaskCancellationHandler {
                    if askFirst { _ = try await context.askUser("Which one?", options: []) }
                    started.set()
                    while true {
                        // Swallows the step limit, so the runner has to stop it.
                        if steps { do { try context.step() } catch is StepLimitReached {} }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                } onCancel: { sawCancel.set() }
            }
            let (runner, recorder) = makeRunner(
                executor, clock: clock, configure: configure, onCancel: { halts.append(sawCancel.isSet) })
            _ = runner.start(goal: "goal")
            if askFirst { _ = await recorder.waitFor(.question) } else { #expect(await started.wait()) }
            await trigger(runner, clock)
            #expect(await recorder.waitFor(.result) != nil, "\(name)")
            #expect(halts.items == [false], "\(name): halted once, before the executor saw cancellation")
            runner.shutdown()
        }
        await check("steps", configure: { $0.maxSteps = 3 }, steps: true) { _, _ in }
        let timeClock = FakeClock()
        await check("time", configure: { $0.maxSeconds = 10 }, clock: timeClock) { _, clock in clock?.advance(11) }
        let questionClock = FakeClock()
        await check("question", configure: { $0.questionTimeout = 60 }, clock: questionClock, askFirst: true) {
            _, clock in clock?.advance(61)
        }
        await check("shutdown", configure: { _ in }) { runner, _ in runner.shutdown() }
    }

    // MARK: Confirmations and reply reading

    @Test("19. A declined confirmation")
    func declined() async {
        let executor = InviteExecutor()
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "invite Priya")
        _ = await recorder.waitFor(.question)
        _ = runner.answer("Priya Shah", taskID: nil)
        _ = await recorder.waitFor(.confirmation)
        _ = runner.answer("no", taskID: nil)
        let result = await recorder.waitFor(.result)
        #expect(result?.status == .done && result?.text == "I didn't send the invite.")
        #expect(executor.confirmResult.items == [false] && !executor.sent.isSet)
        #expect(recorder.events.contains { $0.text == "OK, I won't do that." })
    }

    @Test("20. A correction declines without a re-ask and keeps the user's words")
    func correction() async {
        let executor = ConfirmOnlyExecutor("Send the invite for 3pm")
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.confirmation)
        _ = runner.answer("wait, change the time to 4", taskID: nil)
        #expect(await recorder.waitFor(.result)?.text == "Not sent.")
        #expect(recorder.count(.confirmation) == 1)
        #expect(recorder.events.contains { $0.text == "OK, I haven't done it." })
        #expect(executor.lastAnswers.items == ["wait, change the time to 4"])
    }

    @Test("21. Unclear, then yes: one plainer re-ask, then go ahead")
    func unclearThenYes() async throws {
        let executor = ConfirmOnlyExecutor("Send the message to Mum", spokenQuestion: "Send 'on my way' to Mum?")
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.confirmation)
        _ = runner.answer("hmm", taskID: nil)
        let reask = try #require(await recorder.waitFor(.confirmation, number: 2))
        #expect(reask.status == .needsInput)
        #expect(reask.text == "Sorry, I didn't catch that. Send 'on my way' to Mum? Please say yes or no.")
        #expect(runner.status().string("status") == "needs_input" && runner.isAwaitingAnswer)
        // No progress event between the first ask and the re-ask.
        let kinds = recorder.events.map(\.kind)
        #expect(Array(kinds.suffix(2)) == [.confirmation, .confirmation])
        _ = runner.answer("yes", taskID: nil)
        #expect(await recorder.waitFor(.result)?.text == "Sent.")
        #expect(recorder.events.contains { $0.text == "Going ahead." })
        #expect(executor.results.items == [true])
    }

    @Test("22. Unclear twice: give up without a third ask")
    func unclearTwice() async {
        let executor = ConfirmOnlyExecutor()
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.confirmation)
        _ = runner.answer("hmm", taskID: nil)
        _ = await recorder.waitFor(.confirmation, number: 2)
        _ = runner.answer("the blue one", taskID: nil)
        #expect(await recorder.waitFor(.result)?.text == "Not sent.")
        #expect(recorder.count(.confirmation) == 2)
        #expect(recorder.events.contains { $0.text == "I didn't hear a clear yes, so I haven't done it." })
        #expect(executor.results.items == [false])
    }

    @Test("23. The re-ask keeps the clock paused and restarts the question timeout")
    func reaskClock() async {
        let clock = FakeClock()
        let executor = ConfirmOnlyExecutor()
        let (runner, recorder) = makeRunner(executor, clock: clock) {
            $0.maxSeconds = 10
            $0.questionTimeout = 120
        }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.confirmation)
        clock.advance(100)
        _ = runner.answer("hmm", taskID: nil)
        _ = await recorder.waitFor(.confirmation, number: 2)
        clock.advance(100)  // 200 s since the first ask, 100 s since the re-ask
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(runner.isAwaitingAnswer)
        clock.advance(21)
        let result = await recorder.waitFor(.result)
        #expect(result?.status == .failed)
        #expect(result?.text.contains("I stopped waiting for an answer") == true)
    }

    @Test("24. A safe action needs no confirmation and emits nothing")
    func safeAction() async {
        let executor = ConfirmOnlyExecutor("Open the settings page")
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.result)?.text == "Sent.")
        #expect(executor.results.items == [true] && recorder.count(.confirmation) == 0)
        #expect(recorder.events.map(\.kind) == [.progress, .result])
    }

    @Test("25. A gate that does not answer in time means ask")
    func gateTimeout() async {
        let executor = ConfirmOnlyExecutor("Open the settings page")
        let (runner, recorder) = makeRunner(executor, gate: FakeGate(hangs: true))
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.confirmation) != nil)
        _ = runner.answer("yes", taskID: nil)
        #expect(await recorder.waitFor(.result)?.text == "Sent.")
    }

    @Test("26. The executor's spoken wording is what the user hears; the gate sees the action")
    func spokenWording() async {
        let gate = FakeGate()
        let worded = ConfirmOnlyExecutor(
            action: clickAction("Send", app: "WhatsApp", window: "Amma"), spokenQuestion: "Send 'running late' to Amma?")
        let (runner, recorder) = makeRunner(worded, gate: gate)
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.confirmation)?.text == "Send 'running late' to Amma?")
        #expect(gate.checked.items == ["Click button \"Send\" in WhatsApp, window \"Amma\""])
        runner.shutdown()

        let unworded = ConfirmOnlyExecutor(action: clickAction("Send", app: "WhatsApp", window: "Amma"))
        let (fallbackRunner, fallbackRecorder) = makeRunner(unworded)
        _ = fallbackRunner.start(goal: "goal")
        #expect(await fallbackRecorder.waitFor(.confirmation)?.text
            == "Is it OK to click button \"Send\" in WhatsApp, window \"Amma\"?")
        fallbackRunner.shutdown()
    }

    @Test("27. The classifier upgrades or doubts, but never overrides a no or a wait")
    func classifierRules() async {
        func confirmWith(_ classifier: FakeClassifier, replies: [String]) async -> [Bool] {
            let executor = ConfirmOnlyExecutor()
            let (runner, recorder) = makeRunner(executor, classifier: classifier)
            defer { runner.shutdown() }
            _ = runner.start(goal: "goal")
            for (index, reply) in replies.enumerated() {
                _ = await recorder.waitFor(.confirmation, number: index + 1)
                _ = runner.answer(reply, taskID: nil)
            }
            _ = await recorder.waitFor(.result)
            return executor.results.items
        }
        let sayYes = FakeClassifier(label: .yes)
        #expect(await confirmWith(sayYes, replies: ["ship it mate"]) == [true])
        #expect(await confirmWith(sayYes, replies: ["no"]) == [false])
        #expect(await confirmWith(sayYes, replies: ["wait"]) == [false])
        // A doubted yes is asked again, not declined at once.
        #expect(await confirmWith(FakeClassifier(label: .unclear), replies: ["yes", "yes"]) == [false])
        // A classifier that is too slow leaves the word list in charge.
        #expect(await confirmWith(FakeClassifier(label: .no, hangs: true), replies: ["yes"]) == [true])
    }

    // MARK: Answers at the wrong time

    @Test("28. An answer with nothing waiting changes nothing")
    func answerNothingWaiting() async {
        let executor = ForeverExecutor()
        let (runner, _) = makeRunner(executor)
        defer { runner.shutdown() }
        #expect(runner.answer("yes", taskID: nil) == [
            "ok": false, "error": "No task is waiting for an answer right now.", "status": "idle",
        ])
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        #expect(!runner.answer("yes", taskID: nil).isOK)
        #expect(runner.status().string("status") == "running")
    }

    @Test("29. An answer for the wrong task is refused")
    func answerWrongTask() async {
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.question)
        let wrong = runner.answer("work", taskID: "t7")
        #expect(!wrong.isOK && wrong.string("task_id") == "t1")
        #expect(runner.status().string("status") == "needs_input" && executor.answers.items.isEmpty)
        #expect(runner.answer("work", taskID: "t1").isOK)
        #expect(await executor.started.wait() && executor.answers.items == ["work"])
    }

    @Test("30. A second answer to the same question is refused")
    func secondAnswer() async {
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.question)
        // Hold the runner still so both answers land before it resumes.
        let (first, second) = runner.withLock { (runner.answer("work", taskID: nil), runner.answer("personal", taskID: nil)) }
        #expect(first.isOK && second.string("error") == "I already have an answer for that question.")
        #expect(await executor.started.wait() && executor.answers.items == ["work"])
    }

    // MARK: Limits

    @Test("31. The step limit")
    func stepLimit() async {
        let cleanedUp = Flag()
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            defer { cleanedUp.set() }
            while true {
                try context.step()
                await Task.yield()
            }
        }) { $0.maxSteps = 5 }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        let result = await recorder.waitFor(.result)
        #expect(result?.status == .failed)
        #expect(result?.text == "I stopped because the task used all 5 of its steps without finishing. It had only just started.")
        #expect(runner.status()["steps"] == 5)
        #expect(await cleanedUp.wait(timeout: 1))
    }

    @Test("32. The step limit holds even if the executor swallows it")
    func stepLimitSwallowed() async {
        let cleanedUp = Flag()
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            defer { cleanedUp.set() }
            while true {
                do { try context.step() } catch is StepLimitReached {}
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }) { $0.maxSteps = 3 }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.result)?.status == .failed)
        #expect(await cleanedUp.wait(timeout: 1))
        #expect(runner.status()["steps"] == 3)
    }

    @Test("33. The time limit ignores time spent waiting for the user")
    func timeLimitIgnoresWaiting() async {
        let clock = FakeClock()
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor, clock: clock) {
            $0.maxSeconds = 10
            $0.questionTimeout = 10_000
        }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.question)

        clock.advance(500)  // the user takes a long time to answer
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(runner.status().string("status") == "needs_input")

        _ = runner.answer("work", taskID: nil)
        #expect(await executor.started.wait())
        clock.advance(5)
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(runner.status().string("status") == "running")
        #expect(runner.status()["seconds"] == 5)

        clock.advance(6)  // 11 s of running time in total
        let result = await recorder.waitFor(.result)
        #expect(result?.status == .failed)
        #expect(result?.text == "I stopped because the task took longer than 10 seconds without finishing. So far: Opening Chrome.")
        #expect(await executor.cleanedUp.wait(timeout: 1))
    }

    @Test("34. A question waits at most the question timeout")
    func questionTimeout() async {
        let clock = FakeClock()
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor, clock: clock) { $0.questionTimeout = 120 }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.question)
        clock.advance(119)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(runner.isRunning)
        clock.advance(2)
        let result = await recorder.waitFor(.result)
        #expect(result?.status == .failed)
        #expect(result?.text.hasPrefix("I stopped waiting for an answer to \"Work or personal account?\"") == true)
        #expect(await executor.cleanedUp.wait(timeout: 1))
    }

    // MARK: Failures and broken collaborators

    @Test("35. An ordinary error becomes a speakable failure")
    func ordinaryError() async {
        struct InternalFailure: Error { let detail = "selector #btn-42 not found" }
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            context.report("Opening Chrome")
            throw InternalFailure()
        })
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        let text = await recorder.waitFor(.result)?.text ?? ""
        #expect(text == "Something went wrong and I couldn't finish the task. So far: Opening Chrome.")
        for leak in ["InternalFailure", "selector", "\n"] { #expect(!text.contains(leak)) }
    }

    @Test("36. A SpeakableError is spoken")
    func speakableError() async {
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, _ in throw SpeakableError("Chrome isn't installed.") })
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.result)?.text == "Chrome isn't installed. It had only just started.")
    }

    @Test("37. A sink that calls back into the runner does not deadlock")
    func reentrantSink() async {
        let seen = Log<String>()
        let runnerBox = Log<TaskRunner>()
        let executor = InviteExecutor()
        let runner = TaskRunner(
            executor: executor, gate: FakeGate(),
            sink: { event in
                let status = runnerBox.items.first?.status().string("status") ?? "?"
                seen.append("\(event.kind.rawValue):\(status)")
            },
            configuration: testConfiguration(), activityBus: ActivityBus())
        runnerBox.append(runner)
        defer { runner.shutdown() }
        _ = runner.start(goal: "invite Priya")
        #expect(await waitUntil { seen.items.contains { $0.hasPrefix("question") } })
        _ = runner.answer("Priya Shah", taskID: nil)
        #expect(await waitUntil { seen.items.contains { $0.hasPrefix("confirmation") } })
        _ = runner.answer("yes", taskID: nil)
        #expect(await waitUntil { seen.items.last == "result:done" })
        #expect(executor.sent.isSet)
    }

    @Test("38. A slow sink does not delay cancel")
    func slowSink() async {
        let recorder = EventRecorder()
        recorder.delay = 0.5
        let executor = ForeverExecutor()
        let (runner, _) = makeRunner(executor, recorder: recorder)
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        let begin = ContinuousClock.now
        _ = runner.cancel(taskID: nil)
        #expect(await executor.cleanedUp.wait(timeout: 1) && elapsed(since: begin) < 1)
    }

    // MARK: Progress

    @Test("39. Progress is rate-limited, and every line is kept for the summary")
    func progressRateLimit() async {
        let clock = FakeClock()
        let doneReporting = Flag()
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            for index in 0..<50 { context.report("step \(index)") }
            doneReporting.set()
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }, clock: clock) { $0.progressInterval = 4 }
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await doneReporting.wait())
        try? await Task.sleep(nanoseconds: 50_000_000)
        let reports = recorder.events.filter { $0.kind == .progress }.dropFirst().map(\.text)
        #expect(reports == ["step 0"])

        clock.advance(4)  // the newest line goes out once the interval allows
        #expect(await recorder.waitFor { $0.text == "step 49" } != nil)
        #expect(recorder.count(.progress) == 3)

        let summary = runner.cancel(taskID: nil).string("summary")
        #expect(summary == "Stopped. So far: step 47; step 48; step 49.")
    }

    // MARK: Memory

    @Test("40. Memory: hints in, questions learned, confirmations never learned, task logged")
    func memoryFlow() async {
        let memory = FakeMemory()
        let hints = Log<String>()
        let inner = InviteExecutor()
        let (runner, recorder) = makeRunner(ScriptedExecutor { goal, context in
            hints.append(context.memoryHints)
            return try await inner.run(goal: goal, context: context)
        }, memory: memory)
        defer { runner.shutdown() }
        _ = runner.start(goal: "invite Priya")
        _ = await recorder.waitFor(.question)
        _ = runner.answer("Priya Shah", taskID: nil)
        _ = await recorder.waitFor(.confirmation)
        _ = runner.answer("yes", taskID: nil)
        _ = await recorder.waitFor(.result)

        #expect(hints.items == ["- alias priya: Priya Shah (in calendar)"])
        #expect(await waitUntil { !memory.ended.items.isEmpty && !memory.learned.items.isEmpty })
        #expect(memory.learned.items == [["Priya Shah or Priya Patel?", "Priya Shah", "invite Priya"]])
        #expect(memory.ended.items == ["invite Priya|done|Sent the invite to Priya Shah."])
        #expect(memory.endedSteps.items == [["Opening Google Calendar"]])
    }

    @Test("41. Slow memory never holds a task up")
    func slowMemory() async {
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, _ in "ok" }, memory: FakeMemory(slowSeconds: 1)) {
            $0.memoryTimeout = 0.1
        }
        defer { runner.shutdown() }
        let begin = ContinuousClock.now
        _ = runner.start(goal: "goal")
        #expect(await recorder.waitFor(.result)?.status == .done)
        #expect(elapsed(since: begin) < 0.8)
    }

    // MARK: Many callers and shutdown

    @Test("42. Calls from many threads at once")
    func manyThreads() async {
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        let callers = 12

        let starts = Log<JSONObject>()
        DispatchQueue.concurrentPerform(iterations: callers) { _ in starts.append(runner.start(goal: "goal")) }
        #expect(starts.items.filter { $0.string("status") == "running" }.count == 1)
        #expect(starts.items.filter { $0.string("status") == "busy" }.count == callers - 1)

        _ = await recorder.waitFor(.question)
        let answers = Log<JSONObject>()
        DispatchQueue.concurrentPerform(iterations: callers + 4) { index in
            if index < callers {
                answers.append(runner.answer("answer \(index)", taskID: nil))
            } else {
                for _ in 0..<200 { _ = runner.status(); _ = runner.isRunning; _ = runner.isAwaitingAnswer }
            }
        }
        #expect(answers.items.filter(\.isOK).count == 1)
        #expect(await executor.started.wait())

        let cancels = Log<JSONObject>()
        DispatchQueue.concurrentPerform(iterations: callers) { _ in cancels.append(runner.cancel(taskID: nil)) }
        #expect(cancels.items.filter { $0.string("status") == "cancelled" }.count == 1)
        #expect(cancels.items.filter { $0.string("status") == "not_running" }.count == callers - 1)
        _ = await recorder.waitFor(.result)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.count(.result) == 1)
    }

    @Test("43. Shutdown with a task running")
    func shutdownRunning() async {
        let executor = ForeverExecutor()
        let (runner, recorder) = makeRunner(executor)
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        let begin = ContinuousClock.now
        runner.shutdown()
        #expect(elapsed(since: begin) < 1.5)
        #expect(executor.cleanedUp.isSet)
        let result = recorder.events.last
        #expect(result?.status == .cancelled && result?.text == "Stopped because the assistant is shutting down.")
        #expect(runner.start(goal: "again") == ["ok": false, "error": "The task runner has shut down."])
        runner.shutdown()  // twice is fine
    }

    @Test("44. Shutdown with a stubborn executor is bounded")
    func shutdownStubborn() async {
        let executor = StubbornExecutor()
        let (runner, recorder) = makeRunner(executor)
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        let begin = ContinuousClock.now
        runner.shutdown()
        #expect(elapsed(since: begin) < 3)
        #expect(recorder.events.last?.status == .cancelled)
        executor.release.set()
    }

    // MARK: Extras for the Swift design

    @Test("isAwaitingAnswer is true only while an unanswered question is open")
    func awaitingAnswerFlag() async {
        let executor = ForeverExecutor(askFirst: true)
        let (runner, recorder) = makeRunner(executor)
        defer { runner.shutdown() }
        #expect(!runner.isAwaitingAnswer)
        _ = runner.start(goal: "goal")
        _ = await recorder.waitFor(.question)
        #expect(runner.isAwaitingAnswer)
        _ = runner.answer("work", taskID: nil)
        #expect(!runner.isAwaitingAnswer)
        #expect(await executor.started.wait())
        #expect(!runner.isAwaitingAnswer && runner.isRunning)
    }

    @Test("Cancel posts .halted to the activity bus")
    func haltedActivity() async {
        let bus = ActivityBus()
        let activity = Log<ActivityEvent>()
        let listening = Task { for await event in bus.events() { activity.append(event) } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let executor = ForeverExecutor()
        let (runner, _) = makeRunner(executor, activityBus: bus)
        defer { runner.shutdown(); listening.cancel() }
        _ = runner.start(goal: "goal")
        #expect(await executor.started.wait())
        _ = runner.cancel(taskID: nil)
        #expect(await waitUntil {
            activity.items.contains(.halted) && activity.items.contains { if case .taskEnded = $0 { true } else { false } }
        })
        let haltIndex = activity.items.firstIndex(of: .halted)
        let endIndex = activity.items.firstIndex { if case .taskEnded = $0 { true } else { false } }
        #expect(haltIndex != nil && endIndex != nil && haltIndex! < endIndex!)
    }

    @Test("Two questions at once are refused rather than mixed up")
    func twoQuestionsAtOnce() async {
        let secondOutcome = Log<String>()
        let (runner, recorder) = makeRunner(ScriptedExecutor { _, context in
            async let first = context.askUser("First?", options: [])
            try await Task.sleep(nanoseconds: 20_000_000)
            do {
                _ = try await context.askUser("Second?", options: [])
                secondOutcome.append("asked")
            } catch let error as SpeakableError {
                secondOutcome.append(error.spokenMessage)
            }
            return try await first
        })
        defer { runner.shutdown() }
        _ = runner.start(goal: "goal")
        #expect(await waitUntil { !secondOutcome.items.isEmpty })
        #expect(secondOutcome.items == ["The task tried to ask two things at once."])
        #expect(recorder.count(.question) == 1)
        _ = runner.answer("one", taskID: nil)
        #expect(await recorder.waitFor(.result)?.text == "one")
    }
}
