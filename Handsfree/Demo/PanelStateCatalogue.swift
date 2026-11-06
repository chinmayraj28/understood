//
//  PanelStateCatalogue.swift
//  Handsfree
//
//  The panel states used for design review and for the panel's tests. Each
//  one is made the way the live app makes it: permissions and keys, the
//  ActivityBus events that lead to the moment (applied to the companion's
//  state and the session log), and the listening status, all passed through
//  `PanelSnapshotBuilder`. `StateSnapshots` draws each in light and dark.
//  Pure. New for Handsfree.
//

import Foundation
import HFCore

enum PanelStateCatalogue {

    struct Example {
        let name: String
        let snapshot: PanelSnapshot
        var textScale: Double = 1
        var expandsDetails = false
    }

    static let wakePhrase = "Hey Handsfree"
    /// The settings default (`SLEEP_AFTER_IDLE_S`).
    static let sleepAfterSeconds = 15.0
    static let largestTextScale = PanelSnapshot.largestTextScale
    static let goal = "Message Amma: running late, ten minutes"
    static let question = "Send \u{201C}running late, ten minutes\u{201D} to Amma?"
    static let heldAction = "Click \u{201C}Send\u{201D} in WhatsApp"

    // MARK: - The states

    static func examples(now: Date = Date()) -> [Example] {
        let woken: [ActivityEvent] = [.asleep(wakePhrase: wakePhrase), .waking, .listening]
        let taskSoFar: [ActivityEvent] = woken + [
            .userSaid(goal),
            .agentSpeaking("Okay, messaging Amma."),
            .taskStarted(goal: goal),
            .progress("Opening WhatsApp"),
            .progress("Finding Amma"),
            .agentSpeaking("I can see two chats, Amma and Amma Work. Which one?"),
            .userSaid("Just Amma"),
            .progress("Opening the chat with Amma"),
            .progress("Writing the message"),
        ]
        let waiting = taskSoFar + [
            .thinking(caption: "Finding the Send button"),
            .heldForConfirmation(action: heldAction),
            .waitingForAnswer(question: question),
        ]

        var examples: [Example] = []

        // 1. First run: nothing granted, keys present, the wake listener needs Speech Recognition.
        examples.append(Example(name: "01-first-run", snapshot: make(
            facts: facts(microphone: .notAsked, speech: .notAsked, accessibility: .notAsked, screen: .notAsked),
            events: [.asleep(wakePhrase: wakePhrase)], now: now)))

        // 2. Half way: Microphone and Speech Recognition granted, Accessibility next.
        examples.append(Example(name: "02-mid-setup", snapshot: make(
            facts: facts(accessibility: .notAsked, screen: .notAsked),
            events: [.asleep(wakePhrase: wakePhrase)], now: now)))

        // 2b. A permission that was refused: the button opens System Settings instead.
        examples.append(Example(name: "02b-setup-refused", snapshot: make(
            facts: facts(screen: .notGranted),
            events: [.asleep(wakePhrase: wakePhrase)], now: now)))

        // 3. Keys missing: the permissions are done, the keys file is not.
        examples.append(Example(name: "03-keys-missing", snapshot: make(
            facts: facts(elevenLabs: false, anthropic: false, openRouter: false),
            events: [.asleep(wakePhrase: wakePhrase)], now: now)))

        // 4. Ready and asleep.
        examples.append(Example(name: "04-ready-asleep", snapshot: make(
            facts: facts(), events: [.asleep(wakePhrase: wakePhrase)], listening: asleepListening(now), now: now)))

        // 4b. Asleep again after a task, with something remembered.
        examples.append(Example(name: "04b-ready-after-task", snapshot: make(
            facts: facts(),
            events: waiting + [
                .userSaid("Yes"),
                .clicked(at: .zero),
                .taskEnded(status: .done, summary: "Sent \u{201C}running late, ten minutes\u{201D} to Amma on WhatsApp."),
                .asleep(wakePhrase: wakePhrase),
            ],
            listening: asleepListening(now),
            memory: "Amma is their mother; her chat is \u{201C}Amma\u{201D}, not \u{201C}Amma Work\u{201D}. They prefer WhatsApp for messages.",
            now: now)))

        // 5. Just woken: listening, nothing said yet.
        examples.append(Example(name: "05-listening", snapshot: make(
            facts: facts(), events: woken, listening: awakeListening(now), now: now)))

        // 6. A task running: five steps, the newest one in progress.
        examples.append(Example(name: "06-task-running", snapshot: make(
            facts: facts(), events: taskSoFar + [.thinking(caption: "Finding the Send button")],
            listening: awakeListening(now), now: now)))

        // 7. Waiting for a yes, with four turns of conversation.
        examples.append(Example(name: "07-waiting-for-yes", snapshot: make(
            facts: facts(), events: waiting, listening: awakeListening(now), now: now)))

        // 8. Finished, and failed with a plain reason.
        examples.append(Example(name: "08-task-finished", snapshot: make(
            facts: facts(),
            events: waiting + [
                .userSaid("Yes"),
                .clicked(at: .zero),
                .agentSpeaking("Sent."),
                .taskEnded(status: .done, summary: "Sent \u{201C}running late, ten minutes\u{201D} to Amma on WhatsApp."),
            ],
            listening: awakeListening(now), now: now)))
        examples.append(Example(name: "08b-task-failed", snapshot: make(
            facts: facts(),
            events: taskSoFar + [
                .agentSpeaking("WhatsApp is asking to link this Mac again, so I can\u{2019}t send it."),
                .taskEnded(status: .failed, summary: "WhatsApp is asking to link this Mac to the phone again. Someone needs to scan the code on the screen with the phone."),
            ],
            listening: awakeListening(now), now: now)))

        // 9. Trouble: the voice service's set-up does not match the app.
        var outOfStep = asleepListening(now)
        outOfStep.agent = AgentStatus(
            inSync: false, toolCount: 21, expectedToolCount: 24, checkedAt: now.addingTimeInterval(-40),
            problem: "The voice agent could not be updated.", missing: ["go_to_sleep", "start_task", "stop_task"], unexpected: [])
        examples.append(Example(name: "09-trouble-voice", snapshot: make(
            facts: facts(), events: [.asleep(wakePhrase: wakePhrase)], listening: outOfStep, now: now)))

        // 9b. Trouble: speech is heard but never the phrase (a warning, not an error).
        var notHeard = asleepListening(now)
        for _ in 0..<6 { notHeard.record(.speechWithoutPhrase, at: now.addingTimeInterval(-12)) }
        examples.append(Example(name: "09b-trouble-phrase-not-heard", snapshot: make(
            facts: facts(), events: [.asleep(wakePhrase: wakePhrase)], listening: notHeard, now: now),
            expandsDetails: true))

        // 9c. Trouble: the connection dropped in the middle of a task.
        examples.append(Example(name: "09c-trouble-not-connected", snapshot: make(
            facts: facts(), events: taskSoFar + [.voiceDisconnected(reason: "the connection to the voice service dropped")],
            listening: awakeListening(now), now: now)))

        // 10. A very long goal, many steps and thirty turns: the conversation scrolls, nothing clips.
        examples.append(Example(name: "10-long", snapshot: make(
            facts: facts(), events: longSession(), listening: awakeListening(now), now: now)))

        // 11. Larger text: the waiting-for-a-yes state at 1.4 times the standard size.
        examples.append(Example(name: "11-larger-text", snapshot: make(
            facts: facts(), events: waiting, listening: awakeListening(now), now: now), textScale: 1.4))

        // 11b to 11d. The largest text size, for the three busiest layouts. Every state is also drawn at
        // this size into the render folder's panel/largest/, for checking (see StateSnapshots).
        examples.append(Example(name: "11b-largest-text-waiting", snapshot: make(
            facts: facts(), events: waiting, listening: awakeListening(now), now: now), textScale: largestTextScale))
        examples.append(Example(name: "11c-largest-text-setup", snapshot: make(
            facts: facts(accessibility: .notAsked, screen: .notAsked),
            events: [.asleep(wakePhrase: wakePhrase)], now: now), textScale: largestTextScale))
        examples.append(Example(name: "11d-largest-text-ready", snapshot: make(
            facts: facts(), events: [.asleep(wakePhrase: wakePhrase)], listening: asleepListening(now), now: now),
            textScale: largestTextScale))

        return examples
    }

    // MARK: - Building blocks

    static func facts(
        elevenLabs: Bool = true, anthropic: Bool = true, openRouter: Bool = true,
        microphone: PermissionStatus = .granted, speech: PermissionStatus = .granted,
        accessibility: PermissionStatus = .granted, screen: PermissionStatus = .granted,
        needsSpeech: Bool = true
    ) -> SetupFacts {
        SetupFacts(
            hasElevenLabsKey: elevenLabs, hasAnthropicKey: anthropic, hasOpenRouterKey: openRouter,
            microphone: microphone, accessibility: accessibility, screenRecording: screen,
            speechRecognition: speech, needsSpeechRecognition: needsSpeech,
            keysFilePath: "~/Library/Application Support/Handsfree/.env")
    }

    static func make(
        facts: SetupFacts, events: [ActivityEvent], listening: ListeningStatus = ListeningStatus(),
        memory: String = "", wakePhrase: String = wakePhrase, isAlwaysOpen: Bool = false, now: Date
    ) -> PanelSnapshot {
        var companion = CompanionState()
        var log = SessionLog()
        for event in events {
            companion.apply(event, now: now)
            log.record(event, at: now)
        }
        var status = listening
        status.wakePhrase = wakePhrase
        status.sleepAfterIdleSeconds = sleepAfterSeconds
        return PanelSnapshotBuilder.make(PanelSnapshotBuilder.Inputs(
            facts: facts, companion: companion, log: log, listening: status, wakePhrase: wakePhrase,
            sleepAfterSeconds: sleepAfterSeconds, isAlwaysOpen: isAlwaysOpen, isDemo: false, memorySummary: memory,
            partsReal: 9, partsTotal: 9, version: "0.1.0", now: now))
    }

    static func asleepListening(_ now: Date) -> ListeningStatus {
        var status = ListeningStatus()
        status.language = "English (United Kingdom), en_GB (the Mac's own language; set WAKE_LANGUAGE to change it)"
        status.cycleState = "asleep"
        status.listenerRunning = true
        status.agent = AgentStatus(
            inSync: true, toolCount: 24, expectedToolCount: 24, checkedAt: now.addingTimeInterval(-90),
            problem: nil, missing: [], unexpected: [])
        status.record(.started(recognizer: "SpeechAnalyzer (en_GB)"), at: now.addingTimeInterval(-300))
        return status
    }

    static func awakeListening(_ now: Date) -> ListeningStatus {
        var status = asleepListening(now)
        status.cycleState = "awake"
        status.listenerRunning = false
        status.conversationOpen = true
        status.conversationConnected = true
        status.record(.woke, at: now.addingTimeInterval(-20))
        return status
    }

    /// A long goal, twelve steps and thirty turns of conversation (the goal is the first).
    static func longSession() -> [ActivityEvent] {
        let longGoal = "Find the email from the hospital about Thursday\u{2019}s appointment, add it to my calendar with a reminder "
            + "the evening before, and message Amma the time so she can drive me there"
        // Each entry: a step taken before the turn (if any), who speaks, and what they say.
        let script: [(step: String?, fromUser: Bool, text: String)] = [
            (nil, false, "Okay. I\u{2019}ll start with your email."),
            ("Opening Gmail", false, "There are three emails about appointments. One is from St Mary\u{2019}s Hospital, from Monday."),
            ("Searching for \u{201C}hospital\u{201D}", true, "That\u{2019}s the one"),
            ("Opening the email from St Mary\u{2019}s", false, "It says Thursday at 10:30, outpatients, level 2."),
            (nil, true, "Good"),
            ("Reading the appointment time", false, "Shall I call the calendar event \u{201C}Hospital appointment\u{201D}?"),
            (nil, true, "Call it St Mary\u{2019}s check-up"),
            ("Opening Google Calendar", false, "Okay. Thursday at 10:30, St Mary\u{2019}s check-up. How long is it?"),
            (nil, true, "An hour"),
            ("Creating an event on Thursday at 10:30", false, "What time should the reminder be?"),
            (nil, true, "Seven in the evening, the day before"),
            ("Adding a reminder the evening before", false, "Done: a reminder at 7 pm on Wednesday."),
            (nil, true, "Can you add the address?"),
            (nil, false, "The email gives St Mary\u{2019}s Hospital, Praed Street. I can add that as the place."),
            (nil, true, "Yes please"),
            ("Saving the event", false, "Saved. Now the message to Amma."),
            (nil, true, "Tell her it\u{2019}s at half ten"),
            ("Opening WhatsApp", false, "I\u{2019}ll say: \u{201C}Hospital on Thursday at 10:30, St Mary\u{2019}s. Can you drive me?\u{201D}"),
            (nil, true, "Add that we should leave at quarter to ten"),
            ("Finding Amma", false, "Okay, I\u{2019}ll add \u{201C}We should leave at 9:45.\u{201D}"),
            (nil, true, "Perfect"),
            ("Opening the chat with Amma", false, "I can see two chats, Amma and Amma Work. Which one?"),
            (nil, true, "Just Amma"),
            (nil, false, "Okay, the chat called Amma."),
            (nil, true, "Is the reminder definitely on?"),
            (nil, false, "Yes, 7 pm on Wednesday. I\u{2019}ll check it again at the end."),
            (nil, true, "Thanks"),
            ("Writing the message", false, "Writing the message now."),
            (nil, true, "Read it back to me before you send it"),
        ]
        var events: [ActivityEvent] = [.asleep(wakePhrase: wakePhrase), .waking, .listening, .userSaid(longGoal), .taskStarted(goal: longGoal)]
        for line in script {
            if let step = line.step { events.append(.progress(step)) }
            events.append(line.fromUser ? .userSaid(line.text) : .agentSpeaking(line.text))
        }
        events.append(.thinking(caption: "Writing the message"))
        return events
    }
}
