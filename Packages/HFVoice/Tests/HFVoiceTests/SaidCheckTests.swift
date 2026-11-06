import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Records the answers that reach the task.
private final class AnswerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var answers: [String] { lock.withLock { log } }
    func add(_ answer: String) { lock.withLock { log.append(answer) } }
}

private let confirmation = TaskEvent(taskID: "t1", kind: .confirmation, status: .needsInput, text: "Send 'late' to Amma?")

/// The pure rules: what counts as saying a question.
@Suite struct SaidCheckRuleTests {
    @Test func aParaphraseCarriesTheQuestionAndFillerDoesNot() {
        #expect(SaidCheck.carries("Shall I send 'late' to Amma?", "Send 'late' to Amma?"))
        #expect(SaidCheck.carries("Do you want me to invite Priya Shah?", "Invite Priya Shah?"))
        #expect(!SaidCheck.carries("On it.", "Send 'late' to Amma?"))
        #expect(!SaidCheck.carries("", "Invite Priya Shah?"))
    }

    @Test func neverMoreThanOneExtraAttempt() {
        var check = SaidCheck()
        check.noted(confirmation)
        check.sent([confirmation], at: 0)
        #expect(check.silent(at: 1) == .sendAgain([confirmation]))
        #expect(check.isSecondTry([confirmation]))
        check.sent([confirmation], at: 2)
        #expect(check.silent(at: 3) == .gaveUp([confirmation]))
        #expect(check.silent(at: 4) == .nothingPending, "nothing more is sent")
        #expect(check.hasUnsaid(at: 5, shelfLife: 1800))
    }

    @Test func progressIsNeverTracked() {
        var check = SaidCheck()
        check.sent([TaskEvent(taskID: "t1", kind: .progress, status: .running, text: "Opening WhatsApp")], at: 0)
        #expect(check.attempt == nil)
    }

    @Test func aResultIsSaidByAnyReplyWithWords() {
        var check = SaidCheck()
        let result = TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma.")
        check.sent([result], at: 0)
        #expect(check.replied("   ", at: 1) == .sendAgain([result]), "an empty reply is not said")
        check.sent([result], at: 2)
        #expect(check.replied("Done, your message went to Amma.", at: 3) == .said)
    }

    @Test func aNewConversationHearsNothingYet() {
        var check = SaidCheck()
        check.noted(confirmation)
        _ = check.replied("Shall I send 'late' to Amma?", at: 0)
        #expect(check.unheardQuestion(forAnswerTo: "t1") == nil)
        _ = check.newConversation(at: 1, shelfLife: 1800)
        #expect(check.unheardQuestion(forAnswerTo: "t1") == confirmation)
    }
}

/// The rules running in the voice session.
@Suite(.serialized) @MainActor struct SaidInSessionTests {
    @Test func aQuestionThenASilentTurnIsSentOnceMoreWordedToBeSaid() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1)
        harness.driver.emit(.silentTurn)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2, "skipped, so sent again")
        let again = harness.driver.userMessages.last ?? ""
        #expect(again.hasPrefix(TaskEventSpeech.sayItNow) && again.contains("Send 'late' to Amma?"))
        harness.driver.emit(.agentResponse("Shall I send 'late' to Amma?"))
        harness.clock.advance(10)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2, "said the second time, so not sent again")
        #expect(!harness.session.activity.hasUnspokenNews)
        #expect(harness.session.spokenNews == .init(sentAgain: 1, notSaidTwice: 0, unsaidNow: 0, answersHeldBack: 0))
    }

    @Test func twoSilentTurnsLeaveItUnsaidAndNothingMoreIsSent() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        harness.driver.emit(.silentTurn)
        await harness.settle()
        harness.driver.emit(.silentTurn)
        await harness.settle()
        harness.clock.advance(30)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2, "never a third time")
        #expect(harness.session.activity.hasUnspokenNews, "unsaid, so the conversation does not close on it")
        #expect(harness.session.spokenNews == .init(sentAgain: 1, notSaidTwice: 1, unsaidNow: 1, answersHeldBack: 0))
    }

    @Test func anUnsaidResultDoesNotHoldTheConversationOpenButIsOfferedNextTime() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        harness.driver.emit(.silentTurn)
        await harness.settle()
        harness.driver.emit(.silentTurn)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2)
        #expect(harness.session.spokenNews.notSaidTwice == 1)
        #expect(!harness.session.activity.hasUnspokenNews, "the conversation may sleep on the ordinary idle time")
        await harness.session.close()
        await harness.session.open()
        await harness.settle()
        #expect(harness.driver.userMessages.contains { $0.contains("Sent to Amma.") }, "offered again in the next conversation")
        await harness.session.close()
    }

    @Test func theNoReplyWaitNeverRunsOutWhileTheAgentSpeaksOrTheUserTalks() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        // A long reply: the agent is speaking well past the 4 s wait, its text not here yet.
        harness.driver.emit(.agentActivity(.speaking))
        harness.clock.advance(10)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1, "not re-sent over the agent")
        // The user talks over it.
        harness.driver.emit(.agentActivity(.listening))
        for _ in 0..<5 {
            harness.driver.emit(.voiceActivity(0.9))
            harness.clock.advance(1)
            await harness.settle()
        }
        #expect(harness.driver.userMessages.count == 1, "not re-sent while the user talks")
        // Then nothing at all for the whole wait: that is no reply.
        harness.clock.advance(5)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2)
    }

    @Test func aReplyThatDoesNotSayTheConfirmationDoesNotCount() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        harness.driver.emit(.agentResponse("On it."))
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2)
        #expect(harness.driver.userMessages.last?.hasPrefix(TaskEventSpeech.sayItNow) == true)
    }

    @Test func noReplyAtAllWithinTheTimeoutDoesNotCount() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        harness.clock.advance(5)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2)
    }

    @Test func aYesBeforeTheQuestionWasSaidIsNotPassedOnAndTheQuestionIsAsked() async {
        let harness = Harness(mode: .text)
        let log = AnswerLog()
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            log.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        // The user is talking to the agent about something else when the confirmation arrives,
        // so it waits; a "yes" meant for something else must not reach the task.
        harness.driver.emit(.userTranscript("Is it raining?"))
        harness.session.push(confirmation)
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "the push is waiting for the agent's reply")
        harness.driver.emit(.userTranscript("Yes."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"Yes."}"#.utf8)))
        await harness.settle()
        #expect(log.answers.isEmpty, "not consent: the user never heard the question")
        #expect(harness.driver.toolResults.first?.isError == true)
        #expect(harness.driver.toolResults.first?.text.contains("has not heard") == true)
        #expect(harness.session.spokenNews.answersHeldBack == 1)

        harness.driver.emit(.agentResponse("I can't check the weather."))
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1 && harness.driver.userMessages[0].contains("Send 'late' to Amma?"),
                "the question is asked")
        harness.driver.emit(.agentResponse("Shall I send 'late' to Amma?"))
        harness.driver.emit(.userTranscript("Yes."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c2", parameters: Data(#"{"answer":"Yes.","task_id":"t1"}"#.utf8)))
        await harness.settle()
        #expect(log.answers == ["Yes."], "heard, so this yes is passed on")
    }

    @Test func aConfirmationIsJudgedOnTheUsersOwnWordsNotTheAgents() async {
        let harness = Harness(mode: .text)
        let log = AnswerLog()
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            log.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.session.push(confirmation)
        await harness.settle()
        harness.driver.emit(.agentResponse("Shall I send late to Amma?"))
        // The agent calls answer_task with "yes" before the user has said anything: not passed on.
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"yes"}"#.utf8)))
        await harness.settle()
        #expect(log.answers.isEmpty, "no sentence from the user since the confirmation was said")
        #expect(harness.driver.toolResults.first?.text.contains("has not answered") == true)
        // The user says "hmm, not yet"; the agent passes on "yes". The task gets the user's words.
        harness.driver.emit(.userTranscript("Hmm, not yet."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c2", parameters: Data(#"{"answer":"yes"}"#.utf8)))
        await harness.settle()
        #expect(log.answers == ["Hmm, not yet."], "the classifier judges what the user said")
    }

    @Test func anOrdinaryQuestionStillTakesTheAgentsWording() async {
        let harness = Harness(mode: .text)
        let log = AnswerLog()
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            log.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.session.push(TaskEvent(taskID: "t1", kind: .question, status: .needsInput, text: "Priya Shah or Priya Patel?"))
        await harness.settle()
        harness.driver.emit(.agentResponse("Priya Shah or Priya Patel?"))
        harness.driver.emit(.userTranscript("The first one."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"Priya Shah"}"#.utf8)))
        await harness.settle()
        #expect(log.answers == ["Priya Shah"])
    }

    @Test func aQuestionSentButNotSaidBeforeADropIsSentAgainAfterReconnecting() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.session.push(confirmation)
        await harness.settle()
        let first = harness.driver
        #expect(first.userMessages.count == 1)
        first.emit(.disconnected(reason: "The voice connection dropped."))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await harness.settle()
        #expect(harness.drivers.count == 2, "reconnected")
        #expect(harness.driver.userMessages.contains { $0.contains("Send 'late' to Amma?") }, "the unsaid confirmation goes out again")
        await harness.session.close()
    }

    @Test func newsIsNeverSaidMoreThanHalfAnHourAfterItHappened() async {
        let harness = Harness(mode: .text)
        harness.session.prepare(tools: [], memorySummary: "")
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        harness.clock.advance(1801)
        await harness.session.open()
        await harness.settle()
        #expect(harness.driver.userMessages.isEmpty, "too old to say")
        #expect(harness.session.queuedEventCount == 0)
        await harness.session.close()
    }

    @Test func newsThatCannotBeDeliveredStopsHoldingTheAppAwake() async {
        let harness = Harness(mode: .text)
        await harness.start()
        harness.driver.emit(.agentActivity(.speaking))
        harness.failNextStarts = 1000  // it cannot reconnect
        harness.session.push(TaskEvent(taskID: "t1", kind: .result, status: .done, text: "Sent to Amma."))
        await harness.settle()
        harness.driver.emit(.disconnected(reason: "dropped"))
        await harness.settle()
        #expect(harness.session.activity.hasUnspokenNews, "while it reconnects, the news still holds the conversation")
        harness.clock.advance(31)
        #expect(!harness.session.activity.hasUnspokenNews, "it cannot be delivered: it no longer keeps the app awake")
        #expect(harness.session.queuedEventCount == 1, "but it is kept for the next conversation")
        await harness.session.close()
    }

    @Test func aQuestionHeardInAnEarlierConversationIsAskedAgainBeforeAYesCounts() async {
        let harness = Harness(mode: .text)
        let log = AnswerLog()
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            log.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.session.push(confirmation)
        await harness.settle()
        harness.driver.emit(.agentResponse("Shall I send 'late' to Amma?"))
        await harness.settle()
        await harness.session.close()
        await harness.session.open()
        await harness.settle()
        harness.driver.emit(.userTranscript("Yes."))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: Data(#"{"answer":"Yes."}"#.utf8)))
        await harness.settle()
        #expect(log.answers.isEmpty, "a new conversation has not heard it")
        await harness.session.close()
    }
}
