import Foundation
import HFCore
import Testing

@testable import HFVoice

// Consent in own-listening mode (DECISIONS.md, 6 Nov: a yes counts only if the question was
// heard). Here the agent's reply is our own speech, so a question counts as said only once its
// audio has played to the end, with no failure and no interruption.

/// Every answer that reached the task.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ answer: String) { lock.withLock { stored.append(answer) } }
    var all: [String] { lock.withLock { stored } }
}

private let question = TaskEvent(
    taskID: "t1", kind: .question, status: .needsInput, text: "Priya Shah or Priya Patel?", options: ["Priya Shah", "Priya Patel"])
private let answerCall = Data(#"{"answer":"Priya Shah","task_id":"t1"}"#.utf8)

@Suite(.serialized) @MainActor struct OwnListeningConsentTests {
    /// A session in own-listening mode with an answer_task tool, the question already pushed and
    /// sent, and the agent's reply carrying it just arrived.
    private func askedQuestion(_ speech: FakeSpeech, _ sink: FakeSink, answers: Answers) async -> Harness {
        let harness = Harness(ownListening: sink.setting(speech))
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            answers.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.session.push(question)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 1, "the question was sent to the agent")
        harness.driver.emit(.agentResponse("Which Priya: Priya Shah or Priya Patel?"))
        await harness.settle()
        return harness
    }

    @Test func aQuestionPlayedToTheEndIsSaidAndItsAnswerIsPassedOn() async {
        let speech = FakeSpeech(), sink = FakeSink(), answers = Answers()
        let harness = await askedQuestion(speech, sink, answers: answers)
        harness.clock.advance(1)  // 0.2 s of audio plus the tail have played
        await harness.settle()
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all == ["Priya Shah"])
        #expect(harness.session.spokenNews.sentAgain == 0)
        #expect(harness.session.spokenNews.answersHeldBack == 0)
    }

    @Test func anAnswerWhileTheQuestionIsStillPlayingIsHeldUntilItHasPlayed() async {
        let speech = FakeSpeech(), sink = FakeSink(), answers = Answers()
        let harness = await askedQuestion(speech, sink, answers: answers)
        // The audio is handed over but has not finished playing yet.
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all.isEmpty, "not heard yet, so not consent")
        #expect(harness.driver.toolResults.first?.isError == true)
        #expect(harness.session.spokenNews.answersHeldBack == 1)
        harness.clock.advance(1)
        await harness.settle()
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c2", parameters: answerCall))
        await harness.settle()
        #expect(answers.all == ["Priya Shah"], "heard now, so the answer is passed on")
    }

    @Test func aSpeechFailureMeansNotSaidTheAnswerIsHeldAndTheQuestionGoesAgain() async {
        let speech = FakeSpeech(), sink = FakeSink(), answers = Answers()
        speech.failure = SpeakableError("I couldn't say the reply aloud (text-to-speech error 500).")
        let harness = await askedQuestion(speech, sink, answers: answers)
        #expect(harness.session.spokenNews.sentAgain == 1, "not said: sent again once")
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all.isEmpty)
        #expect(harness.session.spokenNews.answersHeldBack == 1)
        harness.clock.advance(1)
        await harness.settle()
        #expect(harness.driver.userMessages.count == 2, "the question is sent to the agent again")
        #expect(harness.driver.userMessages.last?.contains("Priya Shah or Priya Patel?") == true)
    }

    @Test func aQuestionInterruptedMidwayIsNotSaid() async {
        let speech = FakeSpeech(), sink = FakeSink(), answers = Answers()
        speech.endless = true
        let harness = await askedQuestion(speech, sink, answers: answers)
        #expect(harness.session.isAgentSpeaking)
        harness.session.interruptAgentSpeech()
        await harness.settle()
        #expect(harness.session.spokenNews.sentAgain == 1)
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all.isEmpty, "cut off before the end: the question was not heard")
        #expect(harness.session.spokenNews.answersHeldBack == 1)
    }

    @Test func talkingOverTheQuestionCutsItOffSoItIsNotSaid() async throws {
        let speech = FakeSpeech(), sink = FakeSink(), answers = Answers()
        speech.endless = true
        let harness = await askedQuestion(speech, sink, answers: answers)
        try await harness.session.sendHeardTurn("Priya Shah")
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all.isEmpty)
        #expect(harness.session.spokenNews.sentAgain == 1)
    }

    @Test func voiceModeStillJudgesTheReplyTextAtOnce() async {
        // The setting off: the same reply counts as said when its text arrives, as before.
        let harness = Harness()
        let answers = Answers()
        let answerTask = ToolSpec(name: "answer_task", description: "d", parameters: ["type": "object"], tier: .task) { parameters in
            answers.add(parameters["answer"]?.stringValue ?? "")
            return ToolResult.ok()
        }
        await harness.start(tools: [answerTask])
        harness.session.push(question)
        await harness.settle()
        harness.driver.emit(.agentResponse("Which Priya: Priya Shah or Priya Patel?"))
        harness.driver.emit(.toolCall(name: "answer_task", callID: "c1", parameters: answerCall))
        await harness.settle()
        #expect(answers.all == ["Priya Shah"])
    }
}
