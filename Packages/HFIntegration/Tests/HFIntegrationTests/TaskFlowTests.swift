import CoreGraphics
import Foundation
import HFCore
import HFTasks
import Testing

// BUILD_PLAN 4b end to end through the voice tools: what the voice session
// receives (TaskEvents), what the companion draws (ActivityBus), and what the
// hands actually did.
@Suite(.serialized) struct TaskFlowTests {

    static let goal = "Create a Google Calendar event tomorrow at 15:00 with a Google Meet link and invite Priya"

    @Test("4b: question, answer, a risky click held for a yes, done")
    func inviteFlow() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }

        let started = await rig.call("start_task", ["goal": .string(Self.goal)])
        #expect(started == ["ok": true, "task_id": "t1", "status": "running"])

        let question = try #require(await rig.recorder.waitFor(.question))
        #expect(question.options == ["Priya Shah", "Priya Patel"])
        #expect(rig.runner.isAwaitingAnswer)
        #expect(await rig.call("task_status").string("question") == "Priya Shah or Priya Patel?")
        #expect(await rig.call("answer_task", ["answer": "Priya Shah", "task_id": "t1"]).isOK)

        let confirmation = try #require(await rig.recorder.waitFor(.confirmation))
        #expect(confirmation.text == "Send the invite to Priya Shah for tomorrow at 3pm?")
        let status = await rig.call("task_status")
        #expect(status.string("waiting_for") == "confirmation")
        #expect(status.string("action") == InviteFlowExecutor.sendAction.description)
        #expect(status.string("action") == "Click button \"Send\" in Google Chrome, window \"Google Calendar - Invite guests\"")
        #expect(!rig.hands.actions.items.contains("click 900,120"), "Send must not be clicked before the yes")

        #expect(await rig.call("answer_task", ["answer": "yes"]).isOK)
        let result = try #require(await rig.recorder.waitFor(.result))
        #expect(result.status == .done && result.text == "Sent the invite to Priya Shah.")

        #expect(rig.recorder.lines == [
            "progress/running/Starting: \(Self.goal)",
            "progress/running/Opening Google Calendar",
            "question/needs_input/Priya Shah or Priya Patel?",
            "progress/running/Got it: Priya Shah.",
            "confirmation/needs_input/Send the invite to Priya Shah for tomorrow at 3pm?",
            "progress/running/Going ahead.",
            "result/done/Sent the invite to Priya Shah.",
        ])
        #expect(await rig.activity.waitFor { if case .taskEnded = $0 { true } else { false } })
        #expect(rig.activity.names == [
            "taskStarted",
            "progress: Opening Google Calendar",
            "waitingForAnswer: Priya Shah or Priya Patel?",
            "progress: Got it: Priya Shah.",
            "pointerMoving", "clicked", "typing",
            "heldForConfirmation: Send the invite to Priya Shah for tomorrow at 3pm?",
            "progress: Going ahead.",
            "pointerMoving", "pointerMoving", "clicked",
            "taskEnded: done",
        ])
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
        #expect(rig.hands.actions.items == ["click 400,300", "type Priya Shah", "click 900,120", "resume"])
        #expect(!rig.hands.isHalted)
    }

    @Test("4b declined: a no leaves Send unclicked and the task ends normally")
    func declined() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = await rig.recorder.waitFor(.confirmation)
        await rig.call("answer_task", ["answer": "no, don't send it yet"])
        let result = try #require(await rig.recorder.waitFor(.result))
        #expect(result.status == .done && result.text == "I didn't send the invite.")
        #expect(rig.recorder.lines.contains("progress/running/OK, I won't do that."))
        #expect(!rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("4b unclear then yes: one re-ask, then the click lands")
    func unclearThenYes() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = await rig.recorder.waitFor(.confirmation)
        await rig.call("answer_task", ["answer": "hmm"])
        let reask = try #require(await rig.recorder.waitFor(.confirmation, number: 2))
        #expect(reask.text == "Sorry, I didn't catch that. Send the invite to Priya Shah for tomorrow at 3pm? Please say yes or no.")
        #expect(await rig.activity.waitFor { $0 == .heldForConfirmation(action: reask.text) })
        await rig.call("answer_task", ["answer": "yes"])
        #expect(await rig.recorder.waitFor(.result)?.status == .done)
        #expect(rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("4b cancelled during the confirmation: hands frozen, nothing sent, then released")
    func cancelDuringConfirmation() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = await rig.recorder.waitFor(.confirmation)

        let cancelled = await rig.call("cancel_task")
        #expect(cancelled.string("status") == "cancelled")
        #expect(cancelled.string("summary")
            == "Stopped. I did not go ahead with \"Send the invite to Priya Shah for tomorrow at 3pm?\". So far: Opening Google Calendar.")
        // The hands were frozen before cancel returned. (This executor was only waiting, so it may
        // already have unwound and been released by now: release only ever follows the halt.)
        #expect(rig.hands.actions.items.contains("halt"), "the hands are frozen before cancel returns")
        #expect(!rig.runner.isRunning)

        // A late yes changes nothing.
        #expect(await rig.call("answer_task", ["answer": "yes"]).isOK == false)
        #expect(await rig.activity.waitFor { if case .taskEnded = $0 { true } else { false } })
        let names = rig.activity.names
        let halted = try #require(names.firstIndex(of: "halted"))
        let ended = try #require(names.firstIndex(of: "taskEnded: cancelled"))
        #expect(halted < ended)
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" }, "released once the executor has unwound")
        let actions = rig.hands.actions.items
        #expect(actions.firstIndex(of: "halt")! < actions.lastIndex(of: "resume")!)
        #expect(!rig.hands.actions.items.contains("click 900,120"))
    }

    @Test("Stop during a long glide freezes the pointer within a few steps")
    func cancelFreezesGlide() async throws {
        let rig = Rig { InviteFlowExecutor(hands: $0, gliding: 5) }
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        await rig.call("answer_task", ["answer": "Priya Shah"])
        _ = await rig.recorder.waitFor(.confirmation)
        await rig.call("answer_task", ["answer": "yes"])
        // Wait until the 5 s glide to Send has started.
        #expect(await waitUntil {
            rig.activity.events.contains { if case .pointerMoving(_, let duration) = $0 { duration == 5 } else { false } }
        })
        let begin = ContinuousClock.now
        await rig.call("cancel_task")
        #expect(rig.hands.isHalted)
        // The glide throws Halted at its next step, the executor unwinds, and the hands are released.
        #expect(await waitUntil(timeout: 1) { rig.hands.actions.items.last == "resume" })
        #expect(secondsSince(begin) < 0.5)
        #expect(!rig.hands.actions.items.contains("click 900,120"), "the click after the glide never happens")
        #expect(rig.recorder.events.last?.status == .cancelled)
        #expect(rig.recorder.events.filter { $0.kind == .result }.count == 1)
    }

    @Test("A second goal while one runs is busy; after cancel it starts")
    func busyThenRestart() async {
        let rig = Rig { InviteFlowExecutor(hands: $0) }
        await rig.call("start_task", ["goal": .string(Self.goal)])
        _ = await rig.recorder.waitFor(.question)
        let busy = await rig.call("start_task", ["goal": "Open Spotify and play jazz"])
        #expect(busy.string("status") == "busy" && busy.string("goal") == Self.goal)
        await rig.call("cancel_task")
        #expect(await waitUntil { rig.hands.actions.items.last == "resume" })
        #expect(await rig.call("start_task", ["goal": "Open Spotify and play jazz"]).string("task_id") == "t2")
    }
}
