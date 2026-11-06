import Foundation
import HFCore
import Testing

@testable import HFWake

/// Everything a cycle test needs: a fake listener, a fake conversation, a manual clock, a bus.
final class CycleHarness: @unchecked Sendable {
    let clock = ManualClock()
    let listener = FakeWakeListener()
    let bus = ActivityBus()
    let recorder: BusRecorder
    let opened = Locked<[String]>([])
    let closes = Locked(0)
    /// Real seconds that closing the conversation takes.
    let closeDelay = Locked(0.0)
    let openErrors = Locked<[Error]>([])
    let activity = Locked(ConversationActivity.idle)
    let problems = Locked<[SpeakableError]>([])
    let cycle: ListeningCycle

    init(mode: WakeMode = .phrase, idle: Double = 25, unusedWake: Double? = nil) {
        recorder = BusRecorder(bus)
        var pace = ListeningCycle.Pace()
        pace.retrySeconds = [2, 5]
        let clock = self.clock
        let (opened, closes, openErrors, activity, problems) = (self.opened, self.closes, self.openErrors, self.activity, self.problems)
        cycle = ListeningCycle(
            mode: mode, wakePhrase: "Hey Handsfree", sleepAfterIdleSeconds: idle, sleepAfterUnusedWakeSeconds: unusedWake,
            listener: listener,
            openConversation: { first in
                var error: Error?
                openErrors.update { errors in if !errors.isEmpty { error = errors.removeFirst() } }
                if let error { throw error }
                opened.update { $0.append(first) }
            },
            closeConversation: { [closeDelay] in
                if closeDelay.value > 0 { try? await Task.sleep(nanoseconds: UInt64(closeDelay.value * 1_000_000_000)) }
                closes.update { $0 += 1 }
            },
            currentActivity: { activity.value },
            now: { clock.now },
            sleep: { seconds in try await clock.sleep(seconds) },
            bus: bus,
            onProblem: { problem in problems.update { $0.append(problem) } },
            pace: pace)
    }

    func state() async -> ListeningCycle.State { await cycle.state }

    func waitFor(_ state: ListeningCycle.State) async -> Bool {
        await eventually { await self.cycle.state == state }
    }

    /// Starts asleep, hears the phrase, and waits until awake.
    func wake(saying rest: String = "") async -> Bool {
        await cycle.start()
        guard await waitFor(.asleep) else { return false }
        listener.hear(rest)
        return await waitFor(.awake)
    }
}

@Suite struct CycleAsleepAndWaking {
    @Test func startsAsleepWithTheListenerOnAndSaysSo() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        #expect(await harness.state() == .asleep)
        #expect(harness.listener.isListening)
        #expect(await eventually { harness.recorder.events.value.contains(.asleep(wakePhrase: "Hey Handsfree")) })
        #expect(harness.opened.value.isEmpty)
        await harness.cycle.stop()
    }

    @Test func wakingStopsTheListenerAndOpensTheConversationWithTheRest() async {
        let harness = CycleHarness()
        #expect(await harness.wake(saying: "open Spotify"))
        #expect(harness.opened.value == ["open Spotify"])
        #expect(!harness.listener.isListening)
        #expect(harness.listener.stops.value == 1)
        #expect(await eventually { harness.recorder.events.value.contains(.waking) })
        await harness.cycle.stop()
    }

    @Test func aFailedOpenGoesBackToSleepAndKeepsListening() async {
        let harness = CycleHarness()
        harness.openErrors.value = [SpeakableError("I couldn't reach the voice service.")]
        await harness.cycle.start()
        _ = await harness.waitFor(.asleep)
        harness.listener.hear("open Mail")
        #expect(await eventually { harness.listener.starts.value == 2 })
        #expect(await harness.state() == .asleep)
        #expect(harness.listener.isListening)
        #expect(harness.problems.value == [SpeakableError("I couldn't reach the voice service.")])
        // And the next wake works.
        harness.listener.hear("open Mail")
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == ["open Mail"])
        await harness.cycle.stop()
    }

    @Test func aListenerThatCannotStartIsReportedAndRetried() async {
        let harness = CycleHarness()
        let problem = SpeakableError("Orca isn't allowed to use the microphone, so I can't listen for the wake phrase.")
        harness.listener.startErrors.value = [problem, problem]
        await harness.cycle.start()
        #expect(await harness.state() == .cannotListen)
        #expect(harness.problems.value == [problem])
        await harness.clock.advance(by: 2.1)  // first retry, fails again: reported only once
        #expect(await eventually { harness.listener.starts.value == 2 })
        #expect(harness.problems.value == [problem])
        await harness.clock.advance(by: 5.1)  // second retry succeeds
        #expect(await harness.waitFor(.asleep))
        #expect(harness.listener.starts.value == 3)
        #expect(await harness.cycle.problem == nil)
        await harness.cycle.stop()
    }

    @Test func aListenerThatDiesWhileAsleepIsRestarted() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        harness.listener.listening.value = false  // died, and its own restart did not bring it back
        await harness.clock.advance(by: 10.5)
        #expect(await eventually { harness.listener.starts.value == 2 })
        #expect(harness.listener.isListening)
        #expect(await harness.state() == .asleep)
        await harness.cycle.stop()
    }

    @Test func stopWhileWakingOpensNoConversation() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        harness.listener.stopDelay.value = 0.2  // releasing the microphone takes a moment
        harness.listener.hear("open Mail")
        #expect(await harness.waitFor(.waking))
        await harness.cycle.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(harness.opened.value.isEmpty)
        #expect(await harness.state() == .stopped)
    }

    @Test func aWakeWhileNotAsleepIsIgnored() async {
        let harness = CycleHarness()
        #expect(await harness.wake(saying: "first"))
        harness.listener.hear("second")  // a stale callback
        await settle()
        #expect(harness.opened.value == ["first"])
        await harness.cycle.stop()
    }
}

@Suite struct CycleAwakeAndSleeping {
    @Test func sleepsAfterIdleAndListensAgain() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake)
        await harness.clock.advance(by: 6)
        #expect(await harness.waitFor(.asleep))
        #expect(harness.closes.value == 1)
        #expect(harness.listener.isListening)
        #expect(harness.listener.starts.value == 2)
        #expect(harness.recorder.events.value.filter { $0 == .asleep(wakePhrase: "Hey Handsfree") }.count == 2)
        await harness.cycle.stop()
    }

    @Test func staysAwakeWhileATaskRuns() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake(saying: "reply to Mark"))
        harness.activity.value = ConversationActivity(taskRunning: true)
        await harness.clock.advance(by: 90)
        #expect(await harness.state() == .awake)
        #expect(harness.closes.value == 0)
        harness.activity.value = .idle  // the task finished
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake)  // the full idle wait starts when the task ends
        await harness.clock.advance(by: 7)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func neverSleepsWhileATaskIsWaitingForAnAnswer() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        harness.activity.value = ConversationActivity(awaitingAnswer: true)  // the pointer may be over Send
        await harness.clock.advance(by: 300, step: 1)
        #expect(await harness.state() == .awake)
        #expect(await harness.cycle.requestSleep() == .busy)
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake)
        #expect(harness.closes.value == 0)
        await harness.cycle.stop()
    }

    @Test func staysAwakeWhileSomeoneSpeaks() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        harness.activity.value = ConversationActivity(someoneSpeaking: true)
        await harness.clock.advance(by: 60)
        #expect(await harness.state() == .awake)
        await harness.cycle.stop()
    }

    @Test func activityOnTheBusRestartsTheIdleWait() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        await harness.clock.advance(by: 20)
        harness.bus.post(.userSaid("what's on my calendar"))
        await settle()
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake)
        await harness.clock.advance(by: 6)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func theCyclesOwnEventsAndListeningAreNotActivity() {
        #expect(!ListeningCycle.countsAsActivity(.listening))
        #expect(!ListeningCycle.countsAsActivity(.asleep(wakePhrase: "Hey Handsfree")))
        #expect(!ListeningCycle.countsAsActivity(.waking))
        #expect(!ListeningCycle.countsAsActivity(.voiceDisconnected(reason: "network")))
        #expect(ListeningCycle.countsAsActivity(.agentSpeaking("Done.")))
        #expect(ListeningCycle.countsAsActivity(.waitingForAnswer(question: "Send it?")))
    }

    @Test func askedToSleepClosesAfterTheGoodbye() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        #expect(await harness.cycle.requestSleep() == .goingToSleep)
        harness.activity.value = ConversationActivity(someoneSpeaking: true)  // the agent says goodbye
        await harness.clock.advance(by: 4)
        #expect(await harness.state() == .awake)
        harness.activity.value = .idle
        await harness.clock.advance(by: 1)
        #expect(await harness.waitFor(.asleep))
        #expect(harness.closes.value == 1)
        await harness.cycle.stop()
    }

    @Test func theGoodbyeLimitNeverCutsTheAgentOffMidSentence() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        #expect(await harness.cycle.requestSleep() == .goingToSleep)
        // The agent is still saying a long task result when the 15 s goodbye limit passes.
        harness.activity.value = ConversationActivity(agentSpeaking: true)
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake, "not closed over the agent")
        #expect(harness.closes.value == 0)
        harness.activity.value = .idle
        await harness.clock.advance(by: 1)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func pastTheGoodbyeLimitTheUserTalkingDoesNotHoldItOpen() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        #expect(await harness.cycle.requestSleep() == .goingToSleep)
        harness.activity.value = ConversationActivity(someoneSpeaking: true)  // room noise or the user, not the agent
        await harness.clock.advance(by: 16)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func askedToSleepButATaskStartsDuringTheGoodbye() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake())
        #expect(await harness.cycle.requestSleep() == .goingToSleep)
        harness.activity.value = ConversationActivity(taskRunning: true)
        await harness.clock.advance(by: 20)
        #expect(await harness.state() == .awake)
        #expect(harness.closes.value == 0)
        await harness.cycle.stop()
    }

    @Test func askedToSleepWhenNotAwake() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        #expect(await harness.cycle.requestSleep() == .notAwake)
        await harness.cycle.stop()
    }

    @Test func stopClosesAnOpenConversationAndTheListener() async {
        let harness = CycleHarness()
        #expect(await harness.wake())
        await harness.cycle.stop()
        #expect(await harness.state() == .stopped)
        #expect(harness.closes.value == 1)
        #expect(!harness.listener.isListening)
        // Nothing happens afterwards.
        await harness.clock.advance(by: 60)
        #expect(harness.listener.starts.value == 1)
    }

    @Test func stopWhileAsleepReleasesTheListener() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        await harness.cycle.stop()
        #expect(!harness.listener.isListening)
        #expect(harness.closes.value == 0)
    }

    @Test func wakesAgainAfterSleeping() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake(saying: "open Mail"))
        await harness.clock.advance(by: 26)
        #expect(await harness.waitFor(.asleep))
        harness.listener.hear("open Safari")
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == ["open Mail", "open Safari"])
        await harness.cycle.stop()
    }
}

@Suite struct CycleAlwaysMode {
    @Test func keepsTheConversationOpenWithoutListening() async {
        let harness = CycleHarness(mode: .always, idle: 25)
        await harness.cycle.start()
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == [""])
        #expect(harness.listener.starts.value == 0)
        await harness.clock.advance(by: 120, step: 1)
        #expect(await harness.state() == .awake)
        #expect(harness.closes.value == 0)
        #expect(await harness.cycle.requestSleep() == .alwaysOn)
        #expect(!harness.recorder.events.value.contains(.asleep(wakePhrase: "Hey Handsfree")))
        await harness.cycle.stop()
        #expect(harness.closes.value == 1)
    }

    @Test func retriesOpeningUntilItWorks() async {
        let harness = CycleHarness(mode: .always)
        harness.openErrors.value = [SpeakableError("no network")]
        await harness.cycle.start()
        #expect(await eventually { harness.problems.value.count == 1 })
        #expect(await harness.state() == .waking)
        await harness.clock.advance(by: 2.1)
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == [""])
        await harness.cycle.stop()
    }
}

@Suite struct CycleWakeNow {
    @Test func wakeNowWhileAsleepOpensWithNothingSaid() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        #expect(await harness.cycle.wakeNow() == .waking)
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == [""])
        #expect(!harness.listener.isListening)
        #expect(await eventually { harness.recorder.events.value.contains(.waking) })
        await harness.cycle.stop()
    }

    @Test func wakeNowWhileAwakeDoesNothing() async {
        let harness = CycleHarness()
        #expect(await harness.wake(saying: "open Mail"))
        #expect(await harness.cycle.wakeNow() == .alreadyAwake)
        await settle()
        #expect(harness.opened.value == ["open Mail"])
        await harness.cycle.stop()
    }

    @Test func wakeNowWhileFallingAsleepWakesRightAfterTheClose() async {
        let harness = CycleHarness(idle: 25)
        #expect(await harness.wake(saying: "first"))
        harness.closeDelay.value = 0.3
        await harness.clock.advance(by: 26)
        #expect(await harness.waitFor(.fallingAsleep))
        #expect(await harness.cycle.wakeNow() == .afterFallingAsleep)
        #expect(await harness.waitFor(.awake))
        #expect(harness.closes.value == 1)  // the close was finished, not abandoned half way
        #expect(harness.opened.value == ["first", ""])
        #expect(harness.listener.starts.value == 1)  // it did not go back to listening in between
        await harness.cycle.stop()
    }

    @Test func wakeNowWhenTheListenerCannotStart() async {
        let harness = CycleHarness()
        harness.listener.startErrors.value = [SpeakableError("No microphone.")]
        await harness.cycle.start()
        #expect(await harness.state() == .cannotListen)
        #expect(await harness.cycle.wakeNow() == .waking)
        #expect(await harness.waitFor(.awake))
        #expect(harness.opened.value == [""])
        await harness.cycle.stop()
    }

    @Test func wakeNowFromManyTasksAtOnceOpensOneConversation() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        let cycle = harness.cycle
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await cycle.wakeNow() } }
            group.addTask { harness.listener.hear("open Mail") }  // and the phrase, at the same time
        }
        #expect(await harness.waitFor(.awake))
        await settle()
        #expect(harness.opened.value.count == 1)
        await harness.cycle.stop()
    }

    @Test func wakeNowWhenStoppedDoesNothing() async {
        let harness = CycleHarness()
        #expect(await harness.cycle.wakeNow() == .notRunning)
        #expect(harness.opened.value.isEmpty)
    }
}

@Suite struct CycleProblemsOnTheBus {
    @Test func aListenerThatCannotStartIsShownOnTheBusAndAsleepOnlyOnceItRuns() async {
        let harness = CycleHarness()
        let problem = SpeakableError("I can't listen for the wake phrase.")
        harness.listener.startErrors.value = [problem]
        await harness.cycle.start()
        #expect(await eventually { harness.recorder.events.value.contains(.voiceDisconnected(reason: problem.spokenMessage)) })
        #expect(!harness.recorder.events.value.contains(.asleep(wakePhrase: "Hey Handsfree")))
        await harness.clock.advance(by: 2.1)
        #expect(await harness.waitFor(.asleep))
        #expect(await eventually { harness.recorder.events.value.last == .asleep(wakePhrase: "Hey Handsfree") })
        await harness.cycle.stop()
    }

    @Test func aFailedWakeFollowedByAListenerFailureIsShown() async {
        let harness = CycleHarness()
        await harness.cycle.start()
        _ = await harness.waitFor(.asleep)
        harness.openErrors.value = [SpeakableError("I couldn't reach the voice service.")]
        harness.listener.startErrors.value = [SpeakableError("The microphone is busy.")]
        harness.listener.hear("open Mail")
        #expect(await harness.waitFor(.cannotListen))
        let shown = harness.recorder.events.value.compactMap { event -> String? in
            if case .voiceDisconnected(let reason) = event { return reason } else { return nil }
        }
        #expect(await eventually {
            harness.recorder.events.value.contains(.voiceDisconnected(reason: "The microphone is busy."))
        })
        #expect(shown.contains("I couldn't reach the voice service."))
        await harness.cycle.stop()
    }
}

/// A wake where the user says nothing at all sleeps after the shorter `sleepAfterUnusedWakeSeconds`;
/// as soon as they say anything, the ordinary idle time applies for the rest of the conversation.
@Suite struct CycleUnusedWake {
    @Test func aWakeWithNothingSaidSleepsAfterTheShorterWait() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake())
        await harness.clock.advance(by: 7)
        #expect(await harness.state() == .awake)
        await harness.clock.advance(by: 2)
        #expect(await harness.waitFor(.asleep), "nothing said: asleep after 8 s, not 15")
        #expect(harness.closes.value == 1)
        await harness.cycle.stop()
    }

    @Test func theWaitCountsFromTheEndOfTheAgentsGreeting() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake())
        harness.activity.value = ConversationActivity(someoneSpeaking: true)  // the agent is talking
        await harness.clock.advance(by: 12)
        #expect(await harness.state() == .awake, "speech in progress is never cut off")
        harness.activity.value = .idle
        await harness.clock.advance(by: 7)
        #expect(await harness.state() == .awake)
        await harness.clock.advance(by: 2)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func theRestOfTheWakeSentenceCountsAsSpeaking() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake(saying: "open Spotify"))
        await harness.clock.advance(by: 10)
        #expect(await harness.state() == .awake, "the ordinary 15 s applies")
        await harness.clock.advance(by: 6)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func oneSentenceFromTheUserSwitchesToTheOrdinaryWait() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake())
        await harness.clock.advance(by: 3)
        harness.bus.post(.userSaid("what's the time?"))
        await settle()
        await harness.clock.advance(by: 10)
        #expect(await harness.state() == .awake)
        await harness.clock.advance(by: 6)
        #expect(await harness.waitFor(.asleep))
        await harness.cycle.stop()
    }

    @Test func voiceActivityAloneDoesNotCountAsSpeaking() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake())
        harness.bus.post(.userSpeaking(level: 0.9))  // someone nearby, no transcript
        await settle()
        await harness.clock.advance(by: 9)
        #expect(await harness.waitFor(.asleep), "noise restarts the wait but does not make it the long one")
        await harness.cycle.stop()
    }

    @Test func aTaskWaitingForAYesIsNeverPutToSleep() async {
        let harness = CycleHarness(idle: 15, unusedWake: 8)
        #expect(await harness.wake())
        harness.activity.value = ConversationActivity(awaitingAnswer: true)
        await harness.clock.advance(by: 60, step: 1)
        #expect(await harness.state() == .awake)
        await harness.cycle.stop()
    }

    @Test func theShorterWaitIsNeverLongerThanTheIdleTime() async {
        let harness = CycleHarness(idle: 10, unusedWake: 30)
        #expect(await harness.cycle.sleepAfterUnusedWakeSeconds == 10)
        let defaulted = CycleHarness(idle: 15)
        #expect(await defaulted.cycle.sleepAfterUnusedWakeSeconds == 15, "without the setting, nothing changes")
    }

    @Test func theSettingsAreRead() async {
        var settings = Settings.load(environment: [:], envFileCandidates: [])
        settings.sleepAfterIdleSeconds = 15
        settings.sleepAfterUnusedWakeSeconds = 8
        let cycle = ListeningCycle(settings: settings, listener: FakeWakeListener(),
                                   openConversation: { _ in }, closeConversation: {}, currentActivity: { .idle })
        #expect(await cycle.sleepAfterUnusedWakeSeconds == 8)
        #expect(await cycle.sleepAfterIdleSeconds == 15)
    }
}
