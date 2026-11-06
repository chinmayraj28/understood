//
//  StopListeningRuleTests.swift
//  HFDecisionsTests
//
//  "Stop listening" said during a task stops the task at once, with no network, even while a
//  question is open (6 Nov review). Sentences that only end in "stop", or name an object, still go
//  to Jev. And the instant rules never contradict a golden utterance label.
//

import Foundation
import HFCore
import Testing
@testable import HFDecisions

@Suite("Stop listening stops the task")
struct StopListeningRuleTests {
    @Test("The stop-listening family is an instant stop, running or asked", arguments: [
        "stop listening", "Stop listening.", "Okay, please stop listening", "stop listening to me",
        "Stop listening now", "stop listening to me now", "You can stop listening", "Stop listening, stop",
    ])
    func instantStop(sentence: String) {
        #expect(UtteranceRules.instantDecision(sentence, awaitingAnswer: false)?.label == .cancel, "\(sentence)")
    }

    /// What the app's sentence routing hands the stop watcher for the review's examples (the wake
    /// phrase already taken off the front: "Hey Handsfree stop" arrives as "stop"). Each is an
    /// instant stop while a task runs, with no network.
    @Test("The routed stop sentences are instant stops while a task runs", arguments: [
        "stop", "stop stop", "stop it", "no stop", "that's enough", "stop, that's all", "Stop listening, stop",
        "stop!", "stop listening", "Okay, please stop listening to me", "stop listening now",
    ])
    func routedStops(sentence: String) {
        #expect(UtteranceRules.instantDecision(sentence, awaitingAnswer: false)?.label == .cancel, "\(sentence)")
    }

    @Test("While a question is open, the whole phrase still ends the task", arguments: [
        "stop listening", "Please stop listening", "stop listening to me now",
    ])
    func endsTheTaskWhileAsked(sentence: String) {
        #expect(UtteranceRules.instantDecision(sentence, awaitingAnswer: true)?.label == .cancel, "\(sentence)")
    }

    @Test("Not instant: these go to Jev as before", arguments: [
        "I said stop listening to the music", "stop the music", "don't stop", "it won't stop",
        "okay stop listening to him and stop", "make the music stop",
    ])
    func leftToJev(sentence: String) {
        #expect(UtteranceRules.instantDecision(sentence, awaitingAnswer: false) == nil, "\(sentence)")
    }

    @Test("The stop watcher cancels at once on 'stop listening', without asking the classifier")
    func watcherCancelsWithoutTheNetwork() async {
        let runner = FakeRunner()
        let classifier = StubUtteranceClassifier(.other)
        let watcher = makeWatcher(runner, classifier)
        let decision = watcher.heard("okay, stop listening")
        #expect(decision?.label == .cancel)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 1)
        #expect(classifier.calls.isEmpty)
    }

    @Test("With no task running, 'stop listening' cancels nothing (the app only puts it to sleep)")
    func nothingRunning() async {
        let runner = FakeRunner(running: false)
        let watcher = makeWatcher(runner, StubUtteranceClassifier(.cancel))
        #expect(watcher.heard("stop listening") == nil)
        #expect(await watcher.waitUntilIdle())
        #expect(runner.cancelCount == 0)
    }

    /// The instant rules decide without Jev, so where they decide they must agree with every golden
    /// utterance label (or one of its accepted alternatives).
    @Test func instantRulesNeverContradictAGoldenLabel() throws {
        var decided = 0
        for example in try GoldenExample.bundled() where example.classifier == .utterance {
            guard let text = example.text, example.taskRunning != false else { continue }
            guard let decision = UtteranceRules.instantDecision(text, awaitingAnswer: example.question != nil) else { continue }
            decided += 1
            #expect(example.accepts(decision.label.rawValue), "\(text): rule says \(decision.label.rawValue), golden \(example.expected)")
        }
        #expect(decided > 20)
    }
}
