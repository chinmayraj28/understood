//
//  SentenceRoutingTests.swift
//  HandsfreeTests
//
//  Where each sentence goes (6 Nov review): the stop watcher hears every sentence, with the wake
//  phrase taken off the front; a sign-off is detected as well; "stop listening" stops a task and
//  then sleeps; "that's all" lets it finish; anything said afterwards takes a sign-off back.
//  That the stop watcher then cancels at once on these exact strings is tested in HFDecisions
//  (StopListeningRuleTests and the stop watcher's own tests).
//

import Foundation
import Testing

@Suite("Where each sentence goes")
struct SentenceRoutingTests {
    let wakePhrases = ["Hey Handsfree"]

    struct Row: CustomTestStringConvertible, Sendable {
        let said: String
        let stopWatcherHears: String
        let signOff: SentenceRoute.SignOff?
        var testDescription: String { "\u{201C}\(said)\u{201D}" }
    }

    static let rows: [Row] = [
        // Stops: always reach the stop watcher, never a sign-off.
        Row(said: "stop", stopWatcherHears: "stop", signOff: nil),
        Row(said: "stop stop", stopWatcherHears: "stop stop", signOff: nil),
        Row(said: "stop it", stopWatcherHears: "stop it", signOff: nil),
        Row(said: "no stop", stopWatcherHears: "no stop", signOff: nil),
        Row(said: "that's enough", stopWatcherHears: "that's enough", signOff: nil),
        Row(said: "stop, that's all", stopWatcherHears: "stop, that's all", signOff: nil),
        Row(said: "Stop listening, stop", stopWatcherHears: "Stop listening, stop", signOff: nil),
        Row(said: "okay stop listening to him and stop", stopWatcherHears: "okay stop listening to him and stop", signOff: nil),
        // The wake phrase is taken off the front, with or without a comma, however it is spelt.
        Row(said: "Hey Handsfree stop", stopWatcherHears: "stop", signOff: nil),
        Row(said: "Hey Handsfree, stop!", stopWatcherHears: "stop!", signOff: nil),
        Row(said: "hey hands free stop", stopWatcherHears: "stop", signOff: nil),
        Row(said: "Handsfree, stop it", stopWatcherHears: "stop it", signOff: nil),
        Row(said: "Hey Handsfree", stopWatcherHears: "", signOff: nil),
        Row(said: "open the Handsfree settings", stopWatcherHears: "open the Handsfree settings", signOff: nil),
        // Sign-offs: the stop watcher still hears them.
        Row(said: "stop listening", stopWatcherHears: "stop listening", signOff: .stopListening),
        Row(said: "Okay, please stop listening to me", stopWatcherHears: "Okay, please stop listening to me", signOff: .stopListening),
        Row(said: "Hey Handsfree, stop listening now", stopWatcherHears: "stop listening now", signOff: .stopListening),
        Row(said: "that's all", stopWatcherHears: "that's all", signOff: .finishThenSleep),
        Row(said: "That's it, thanks", stopWatcherHears: "That's it, thanks", signOff: .finishThenSleep),
        Row(said: "goodbye", stopWatcherHears: "goodbye", signOff: .finishThenSleep),
        Row(said: "we're done", stopWatcherHears: "we're done", signOff: .finishThenSleep),
        Row(said: "Hey Handsfree, go to sleep", stopWatcherHears: "go to sleep", signOff: .finishThenSleep),
        // Neither a stop nor a sign-off.
        Row(said: "stop the music", stopWatcherHears: "stop the music", signOff: nil),
        Row(said: "be quiet", stopWatcherHears: "be quiet", signOff: nil),
        Row(said: "send Amma a message saying that's all for today", stopWatcherHears: "send Amma a message saying that's all for today", signOff: nil),
        Row(said: "Yes, that's it", stopWatcherHears: "Yes, that's it", signOff: nil),
        Row(said: "actually, open my email after that", stopWatcherHears: "actually, open my email after that", signOff: nil),
    ]

    @Test("Every sentence reaches the stop watcher; sign-offs are found as well", arguments: rows)
    func routes(row: Row) {
        let route = SentenceRouting.route(row.said, wakePhrases: wakePhrases)
        #expect(route.forStopWatcher == row.stopWatcherHears)
        #expect(route.signOff == row.signOff)
    }

    @Test("The wake phrase's alternatives come off the front too")
    func alternatives() {
        let phrases = ["Hey Handsfree", "Okay Computer"]
        #expect(SentenceRouting.route("okay computer, stop", wakePhrases: phrases).forStopWatcher == "stop")
        #expect(SentenceRouting.route("Computer stop", wakePhrases: phrases).forStopWatcher == "stop")
        #expect(SentenceRouting.route("Hey Handsfree stop", wakePhrases: phrases).forStopWatcher == "stop")
        #expect(SentenceRouting.route("computer science homework", wakePhrases: ["Hey Handsfree"]).forStopWatcher == "computer science homework")
    }

    // MARK: - Sleeping

    func route(_ sentence: String) -> SentenceRoute { SentenceRouting.route(sentence, wakePhrases: wakePhrases) }

    @Test("'Stop listening' with no task sleeps at once; during a task, once the task has ended")
    func stopListeningSleeps() {
        var idle = SleepRequest()
        let idleAction = idle.heard(route("stop listening"), taskActive: false)
        #expect(idleAction == .sleepNow)

        var busy = SleepRequest()
        let busyAction = busy.heard(route("stop listening"), taskActive: true)
        #expect(busyAction == .sleepWhenTaskEnds)
        // The stop watcher cancels the task; at the next refresh the task has ended, so it sleeps.
        let first = busy.taskHasEnded(taskActive: false, conversationOpen: true)
        let second = busy.taskHasEnded(taskActive: false, conversationOpen: true)
        #expect(first)
        #expect(!second, "only once")
    }

    @Test("'That's all' during a task waits for the task, then sleeps")
    func thatsAllWaitsForTheTask() {
        var request = SleepRequest()
        let action = request.heard(route("that's all"), taskActive: true)
        #expect(action == .sleepWhenTaskEnds)
        let whileRunning = request.taskHasEnded(taskActive: true, conversationOpen: true)
        #expect(!whileRunning, "never sleeps over a running task")
        let afterwards = request.taskHasEnded(taskActive: false, conversationOpen: true)
        #expect(afterwards)
    }

    @Test("'That's all', then 'actually, open my email after that': it does not sleep over the new request")
    func laterSentenceTakesItBack() {
        var request = SleepRequest()
        _ = request.heard(route("that's all"), taskActive: true)
        let action = request.heard(route("actually, open my email after that"), taskActive: true)
        #expect(action == .none)
        #expect(!request.waitsForTask)
        let sleeps = request.taskHasEnded(taskActive: false, conversationOpen: true)
        #expect(!sleeps)
    }

    @Test("A held sign-off is dropped if the conversation has already closed")
    func droppedWhenClosed() {
        var request = SleepRequest()
        _ = request.asked(taskActive: true)
        let sleeps = request.taskHasEnded(taskActive: false, conversationOpen: false)
        #expect(!sleeps)
        #expect(!request.waitsForTask)
    }

    @Test("The agent's go_to_sleep tool never sleeps over a task either")
    func toolNeverSleepsOverATask() {
        var request = SleepRequest()
        let during = request.asked(taskActive: true)
        let after = request.asked(taskActive: false)
        #expect(during == .sleepWhenTaskEnds)
        #expect(after == .sleepNow)
    }
}
