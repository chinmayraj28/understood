//
//  CompanionStateTests.swift
//  HandsfreeTests
//
//  The mapping from ActivityBus events to what the companion shows.
//

import CoreGraphics
import Foundation
import HFCore
import Testing

@Suite("Companion state")
struct CompanionStateTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test("Starts as connecting and rests once listening")
    func restsWhenListening() {
        var state = CompanionState()
        #expect(state.glyph == .connecting)
        state.apply(.listening, now: start)
        #expect(state.glyph == .listening)
        #expect(state.isResting)
    }

    @Test("The waveform follows the level and stops after a short silence")
    func userSpeaking() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.userSpeaking(level: 0.6), now: at(0))
        #expect(state.glyph == .userSpeaking)
        #expect(state.voiceLevel == 0.6)
        state.apply(.userSpeaking(level: 4), now: at(0.1))
        #expect(state.voiceLevel == 1, "levels are clamped to 0...1")
        state.expire(now: at(0.5))
        #expect(state.glyph == .userSpeaking)
        state.expire(now: at(0.1 + CompanionTiming.userSpeakingSilenceSeconds + 0.01))
        #expect(state.glyph == .listening)
    }

    @Test("A heard sentence is shown in quotes and goes away by itself")
    func heardCaption() {
        var state = CompanionState()
        state.apply(.userSaid("  Message Amma  "), now: start)
        #expect(state.caption?.text == "\u{201C}Message Amma\u{201D}")
        #expect(state.caption?.tone == .heard)
        state.expire(now: at(CompanionTiming.heardCaptionSeconds + 0.01))
        #expect(state.caption == nil)
    }

    @Test("Empty sentences show nothing")
    func emptySentence() {
        var state = CompanionState()
        state.apply(.userSaid("   "), now: start)
        #expect(state.caption == nil)
    }

    @Test("Thinking and progress show a caption while the task works")
    func thinkingAndProgress() {
        var state = CompanionState()
        state.apply(.taskStarted(goal: "Message Amma"), now: start)
        #expect(state.glyph == .thinking)
        #expect(state.currentGoal == "Message Amma")
        state.apply(.progress("Opening WhatsApp"), now: at(1))
        #expect(state.caption?.text == "Opening WhatsApp")
        #expect(state.caption?.tone == .progress)
    }

    @Test("Pointer travel shows a target that closes in, then a click halo")
    func pointerTravelAndClick() {
        var state = CompanionState()
        state.apply(.taskStarted(goal: "Message Amma"), now: start)
        let destination = CGPoint(x: 400, y: 300)
        state.apply(.pointerMoving(to: destination, duration: 0.8), now: at(1))
        #expect(state.glyph == .moving)
        #expect(state.target?.phase == .approaching)
        #expect(state.target?.point == destination)
        #expect(state.target?.travelSeconds == 0.8)

        state.apply(.clicked(at: destination), now: at(1.8))
        #expect(state.glyph == .clicking)
        #expect(state.target?.phase == .clicked)

        // The halo goes, and between actions the task is thinking again.
        state.expire(now: at(1.8 + CompanionTiming.clickRippleSeconds + 0.01))
        #expect(state.target == nil)
        #expect(state.glyph == .thinking)
    }

    @Test("A move with no click leaves its target briefly, then clears it")
    func moveWithoutClick() {
        var state = CompanionState()
        state.apply(.pointerMoving(to: CGPoint(x: 10, y: 10), duration: 0.5), now: start)
        state.expire(now: at(0.5 + CompanionTiming.arrivedTargetLingerSeconds + 0.01))
        #expect(state.target == nil)
        #expect(state.glyph == .listening || state.glyph == .connecting)
    }

    @Test("Typing and scrolling show while they happen, then return to idle without a task")
    func typingAndScrolling() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.typing, now: start)
        #expect(state.glyph == .typing)
        state.expire(now: at(CompanionTiming.typingQuietSeconds + 0.01))
        #expect(state.glyph == .listening)
        state.apply(.scrolled, now: at(5))
        #expect(state.glyph == .scrolling)
        state.expire(now: at(5 + CompanionTiming.scrollQuietSeconds + 0.01))
        #expect(state.glyph == .listening)
    }

    @Test("A held action becomes a confirmation card, whichever event comes first")
    func heldForConfirmation() {
        let action = "Click button \"Send\" in WhatsApp, window \"Amma\""
        let question = "Send \"running late\" to Amma?"

        var heldFirst = CompanionState()
        heldFirst.apply(.pointerMoving(to: CGPoint(x: 900, y: 700), duration: 0.6), now: start)
        heldFirst.apply(.heldForConfirmation(action: action), now: at(0.7))
        heldFirst.apply(.waitingForAnswer(question: question), now: at(0.8))
        #expect(heldFirst.glyph == .holding)
        #expect(heldFirst.prompt?.isConfirmation == true)
        #expect(heldFirst.prompt?.question == question)
        #expect(heldFirst.prompt?.heldAction == action)
        #expect(heldFirst.target?.phase == .held)
        #expect(heldFirst.target?.expiresAt == nil, "the held ring stays until the answer")

        var questionFirst = CompanionState()
        questionFirst.apply(.waitingForAnswer(question: question), now: start)
        #expect(questionFirst.glyph == .asking)
        questionFirst.apply(.heldForConfirmation(action: action), now: at(0.1))
        #expect(questionFirst.glyph == .holding)
        #expect(questionFirst.prompt?.question == question)
        #expect(questionFirst.prompt?.heldAction == action)
    }

    @Test("The card stays while the user answers, and goes when the click lands")
    func confirmationResolvedByClick() {
        var state = CompanionState()
        let send = CGPoint(x: 900, y: 700)
        state.apply(.pointerMoving(to: send, duration: 0.6), now: start)
        state.apply(.heldForConfirmation(action: "Click Send"), now: at(1))
        state.apply(.waitingForAnswer(question: "Send it?"), now: at(1))
        // Thirty seconds of thinking it over: still there.
        state.expire(now: at(31))
        #expect(state.prompt != nil)
        // The user speaks: the waveform shows, the card stays.
        state.apply(.userSpeaking(level: 0.5), now: at(32))
        #expect(state.glyph == .userSpeaking)
        #expect(state.prompt != nil)
        state.apply(.userSaid("yes"), now: at(33))
        #expect(state.prompt != nil, "the card stays until the task acts on the answer")
        state.apply(.clicked(at: send), now: at(33.5))
        #expect(state.prompt == nil)
        #expect(state.target?.phase == .clicked)
    }

    @Test("While a card is up, the agent's speech does not add a second box")
    func questionNotDuplicated() {
        var state = CompanionState()
        state.apply(.waitingForAnswer(question: "Amma, or Amma Work?"), now: start)
        state.apply(.agentSpeaking("I can see two chats, Amma and Amma Work. Which one?"), now: at(0.1))
        #expect(state.caption == nil)
        #expect(state.glyph == .asking)
        // Once the card is gone, speech shows again.
        state.apply(.thinking(caption: "Opening the chat"), now: at(3))
        state.apply(.agentSpeaking("Opening Amma."), now: at(4))
        #expect(state.caption?.text == "Opening Amma.")
    }

    @Test("Reconnecting replaces the not-connected caption at once")
    func reconnected() {
        var state = CompanionState()
        state.apply(.voiceDisconnected(reason: "network"), now: start)
        state.apply(.listening, now: at(2))
        #expect(state.caption?.text == "Connected again")
        #expect(state.caption?.tone == .success)
        state.apply(.listening, now: at(2.5))
        #expect(state.caption?.text == "Connected again", "a second listening does not repeat or clear it")
        state.expire(now: at(2 + CompanionTiming.reconnectedCaptionSeconds + 0.01))
        #expect(state.isResting)
    }

    @Test("The prompt has a backstop so it can never stay forever")
    func promptBackstop() {
        var state = CompanionState()
        state.apply(.taskStarted(goal: "x"), now: start)
        state.apply(.waitingForAnswer(question: "Which one?"), now: start)
        state.expire(now: at(CompanionTiming.promptBackstopSeconds + 1))
        #expect(state.prompt == nil)
        #expect(state.glyph == .thinking)
    }

    @Test("Stop clears everything at once and shows Stopped, then rests")
    func halted() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.taskStarted(goal: "Play music"), now: start)
        state.apply(.pointerMoving(to: CGPoint(x: 1, y: 1), duration: 2), now: at(1))
        state.apply(.halted, now: at(1.5))
        #expect(state.glyph == .stopped)
        #expect(state.target == nil)
        #expect(state.prompt == nil)
        #expect(state.caption?.tone == .stop)
        // The runner then reports the task as cancelled: Stopped stays on screen.
        state.apply(.taskEnded(status: .cancelled, summary: "Stopped."), now: at(1.6))
        #expect(state.glyph == .stopped)
        state.expire(now: at(1.5 + CompanionTiming.stoppedSeconds + 0.01))
        #expect(state.glyph == .listening)
    }

    @Test("A repeated stop is shown once and does not restart")
    func haltedIsIdempotent() {
        var state = CompanionState()
        state.apply(.taskStarted(goal: "Play music"), now: start)
        state.apply(.halted, now: at(1))
        state.apply(.taskEnded(status: .cancelled, summary: "Stopped. Nothing else was done."), now: at(1.1))
        state.apply(.halted, now: at(1.2))
        state.apply(.halted, now: at(1.3))
        #expect(state.caption?.text == "Stopped. Nothing else was done.")
        #expect(state.activityExpiresAt == at(1 + CompanionTiming.stoppedSeconds), "the stopped state was not extended")
    }

    @Test("Where the pointer really stopped is not drawn as a target and keeps Stopped")
    func zeroLengthMoveAfterStop() {
        var state = CompanionState()
        state.apply(.taskStarted(goal: "x"), now: start)
        state.apply(.pointerMoving(to: CGPoint(x: 900, y: 100), duration: 1.5), now: at(1))
        state.apply(.halted, now: at(1.6))
        state.apply(.pointerMoving(to: CGPoint(x: 600, y: 400), duration: 0), now: at(1.65))
        #expect(state.glyph == .stopped)
        #expect(state.target == nil)
    }

    @Test("Stop while a confirmation is held drops the card")
    func haltedWhileHolding() {
        var state = CompanionState()
        state.apply(.heldForConfirmation(action: "Click Send"), now: start)
        state.apply(.halted, now: at(1))
        #expect(state.prompt == nil)
        #expect(state.glyph == .stopped)
    }

    @Test("Task results show the right symbol and summary, then rest", arguments: [
        (TaskStatus.done, CompanionState.Glyph.done, CompanionState.Tone.success),
        (TaskStatus.failed, CompanionState.Glyph.failed, CompanionState.Tone.problem),
        (TaskStatus.cancelled, CompanionState.Glyph.cancelled, CompanionState.Tone.muted),
    ])
    func taskEnded(status: TaskStatus, glyph: CompanionState.Glyph, tone: CompanionState.Tone) {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.taskStarted(goal: "x"), now: start)
        state.apply(.taskEnded(status: status, summary: "Summary"), now: at(1))
        #expect(state.glyph == glyph)
        #expect(state.caption?.text == "Summary")
        #expect(state.caption?.tone == tone)
        #expect(state.currentGoal == nil)
        state.expire(now: at(1 + max(CompanionTiming.finishedSeconds, CompanionTiming.resultCaptionSeconds) + 0.01))
        #expect(state.glyph == .listening)
        #expect(state.isResting)
    }

    @Test("A done task with no summary still says Done")
    func emptySummary() {
        var state = CompanionState()
        state.apply(.taskEnded(status: .done, summary: ""), now: start)
        #expect(state.caption?.text == "Done")
    }

    @Test("Disconnected shows until the voice is back, and its caption fades")
    func disconnected() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        state.apply(.voiceDisconnected(reason: "network"), now: at(1))
        #expect(state.glyph == .disconnected)
        state.expire(now: at(1 + CompanionTiming.disconnectedCaptionSeconds + 0.01))
        #expect(state.caption == nil)
        #expect(state.glyph == .disconnected, "the small grey symbol stays while disconnected")
        state.apply(.listening, now: at(20))
        #expect(state.glyph == .listening)
    }

    @Test("A held confirmation outranks being disconnected, so the question stays visible")
    func holdingOutranksDisconnected() {
        var state = CompanionState()
        state.apply(.heldForConfirmation(action: "Click Send"), now: start)
        state.apply(.voiceDisconnected(reason: "network"), now: at(1))
        #expect(state.glyph == .holding)
        #expect(state.prompt != nil)
    }

    @Test("Agent speech shows as a caption timed to its length")
    func agentSpeaking() {
        var state = CompanionState()
        state.apply(.listening, now: start)
        let sentence = "Okay, messaging Amma."
        state.apply(.agentSpeaking(sentence), now: start)
        #expect(state.glyph == .agentSpeaking)
        #expect(state.caption?.tone == .spoken)
        let seconds = CompanionTiming.spokenCaptionSeconds(for: sentence)
        state.expire(now: at(seconds + 0.01))
        #expect(state.caption == nil)
        #expect(state.glyph == .listening)
    }

    @Test("Spoken captions are on screen long enough to read, but not forever")
    func spokenCaptionTiming() {
        #expect(CompanionTiming.spokenCaptionSeconds(for: "Ok") == 2.5)
        #expect(CompanionTiming.spokenCaptionSeconds(for: String(repeating: "word ", count: 200)) == 10)
    }

    @Test("Every glyph eventually returns to resting with no further events")
    func everythingEnds() {
        let events: [ActivityEvent] = [
            .listening, .userSpeaking(level: 0.5), .userSaid("hi"), .agentSpeaking("hello"),
            .thinking(caption: "Looking"), .pointerMoving(to: .zero, duration: 1), .clicked(at: .zero), .typing, .scrolled,
            .progress("x"), .waitingForAnswer(question: "?"), .heldForConfirmation(action: "a"),
            .taskEnded(status: .done, summary: "ok"), .halted, .listening,
        ]
        var state = CompanionState()
        for (index, event) in events.enumerated() { state.apply(event, now: at(Double(index) * 0.1)) }
        state.expire(now: at(CompanionTiming.promptBackstopSeconds + 60))
        #expect(state.isResting)
        #expect(state.target == nil)
    }

    @Test("sameWords ignores quotes, case and punctuation")
    func sameWords() {
        #expect(CompanionState.sameWords("Send \u{201C}hi\u{201D} to Amma?", "send \"hi\" to amma"))
        #expect(!CompanionState.sameWords("Send it?", "Send it to Amma?"))
    }
}
