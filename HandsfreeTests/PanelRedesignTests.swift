//
//  PanelRedesignTests.swift
//  HandsfreeTests
//
//  The menu bar panel: which layout and which main button each state gets,
//  how the live model maps into a snapshot, that the wake phrase always comes
//  from settings, and that nothing the panel says mentions the app's insides.
//

import Foundation
import HFCore
import Testing

@Suite("Menu bar panel")
struct PanelRedesignTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func example(_ name: String) throws -> PanelStateCatalogue.Example {
        try #require(PanelStateCatalogue.examples(now: now).first { $0.name == name }, "No example named \(name)")
    }

    // MARK: - Each review state

    @Test("First run: a checklist, 0 of 4 done, and the main button allows the microphone")
    func firstRun() throws {
        let snapshot = try example("01-first-run").snapshot
        #expect(snapshot.mode == .setup)
        #expect(snapshot.setupSteps.map(\.kind) == [.microphone, .speechRecognition, .accessibility, .screenRecording])
        #expect(snapshot.setupDoneCount == 0)
        #expect(PanelCopy.setupProgress(done: snapshot.setupDoneCount, total: snapshot.setupSteps.count) == "0 of 4 done")
        #expect(snapshot.primaryAction == PanelSnapshot.Action(title: "Allow Microphone", perform: .askMacOS(.microphone)))
        #expect(snapshot.nextStep?.kind == .microphone)
        #expect(snapshot.setupSteps.allSatisfy { !$0.reason.isEmpty })
    }

    @Test("Half way through setup, Accessibility is next")
    func midSetup() throws {
        let snapshot = try example("02-mid-setup").snapshot
        #expect(snapshot.mode == .setup)
        #expect(snapshot.setupDoneCount == 2)
        #expect(snapshot.primaryAction == PanelSnapshot.Action(title: "Allow Accessibility", perform: .askMacOS(.accessibility)))
        #expect(snapshot.setupSteps.first { $0.kind == .microphone }?.stateLabel == "Done")
        #expect(snapshot.setupSteps.first { $0.kind == .screenRecording }?.stateLabel == "Needed")
    }

    @Test("A refused permission opens its page of System Settings")
    func refused() throws {
        let snapshot = try example("02b-setup-refused").snapshot
        #expect(snapshot.primaryAction == PanelSnapshot.Action(title: "Open Screen Recording Settings", perform: .openSettings(.screenRecording)))
        #expect(snapshot.nextStep?.stateLabel == "Turned off")
        #expect(snapshot.nextStep?.instructions.contains("Open Screen Recording Settings") == true)
    }

    @Test("Missing keys: a keys step that names the three keys and where the file goes")
    func keysMissing() throws {
        let snapshot = try example("03-keys-missing").snapshot
        #expect(snapshot.mode == .setup)
        #expect(snapshot.setupSteps.count == 5)
        #expect(snapshot.setupDoneCount == 4)
        #expect(snapshot.primaryAction == PanelSnapshot.Action(title: "Show Keys File", perform: .showKeysFile))
        let keys = try #require(snapshot.nextStep)
        #expect(keys.kind == .keys)
        #expect(keys.fileLines == [
            "ELEVENLABS_API_KEY=\u{2026}  (missing)", "ANTHROPIC_API_KEY=\u{2026}   (missing)", "OPENROUTER_API_KEY=\u{2026}  (missing)",
        ])
        #expect(keys.instructions.contains("three lines"))
        #expect(keys.detail == "~/Library/Application Support/Handsfree/.env")
        // Only the ones actually missing are marked.
        let oneMissing = PanelStateCatalogue.make(
            facts: PanelStateCatalogue.facts(anthropic: false), events: [.asleep(wakePhrase: "Hey Handsfree")], now: now)
        #expect(oneMissing.nextStep?.fileLines.filter { $0.hasSuffix("(missing)") } == ["ANTHROPIC_API_KEY=\u{2026}   (missing)"])
        // The keys step already asks for the whole file, so the optional-key note is not repeated.
        #expect(snapshot.setupNote == nil)
    }

    @Test("Only the optional key missing: no step, a quiet note, and setup is complete")
    func optionalKey() {
        let snapshot = PanelStateCatalogue.make(
            facts: PanelStateCatalogue.facts(openRouter: false), events: [.asleep(wakePhrase: "Hey Handsfree")], now: now)
        #expect(snapshot.mode == .ready)
        #expect(!snapshot.setupSteps.contains { $0.kind == .keys })
        #expect(snapshot.setupNote == PanelCopy.optionalKeyNote)
    }

    @Test("Ready and asleep: the hero layout, nothing to press, no trouble")
    func readyAsleep() throws {
        let snapshot = try example("04-ready-asleep").snapshot
        #expect(snapshot.mode == .ready)
        #expect(snapshot.activity == .asleep)
        #expect(snapshot.primaryAction == nil)
        #expect(snapshot.trouble.isEmpty)
        #expect(snapshot.task == nil)
    }

    @Test("Asleep after a task: still the ready layout, with the last task")
    func readyAfterTask() throws {
        let snapshot = try example("04b-ready-after-task").snapshot
        #expect(snapshot.mode == .ready)
        #expect(snapshot.task?.isCurrent == false)
        #expect(snapshot.task?.status == .done)
        #expect(!snapshot.memorySummary.isEmpty)
    }

    @Test("Just woken: the active layout, listening, an empty conversation")
    func listening() throws {
        let snapshot = try example("05-listening").snapshot
        #expect(snapshot.mode == .active)
        #expect(snapshot.activity == .listening)
        #expect(snapshot.transcript.isEmpty)
        #expect(snapshot.task == nil)
    }

    @Test("A running task: working, five steps, the newest is the current one")
    func taskRunning() throws {
        let snapshot = try example("06-task-running").snapshot
        #expect(snapshot.mode == .active)
        #expect(snapshot.activity == .working)
        let task = try #require(snapshot.task)
        #expect(task.status == .running)
        #expect(task.isCurrent)
        #expect(task.goal == PanelStateCatalogue.goal)
        #expect(task.steps.count == 5)
        #expect(task.steps.last == "Finding the Send button")
        #expect(!snapshot.isAwaitingAnswer)
    }

    @Test("Waiting for a yes: the question and the held action, four turns of conversation")
    func waitingForYes() throws {
        let snapshot = try example("07-waiting-for-yes").snapshot
        #expect(snapshot.mode == .active)
        #expect(snapshot.activity == .waitingForYes)
        #expect(snapshot.isAwaitingAnswer)
        #expect(snapshot.task?.status == .waitingForYes)
        #expect(snapshot.task?.question == PanelStateCatalogue.question)
        #expect(snapshot.task?.heldAction == PanelStateCatalogue.heldAction)
        #expect(snapshot.transcript.count == 4)
        #expect(snapshot.transcript.map(\.isFromUser) == [true, false, false, true])
        // Never a button that says yes for them: a yes is spoken.
        #expect(snapshot.primaryAction == nil)
    }

    @Test("A question that is not a confirmation is shown as a question")
    func question() {
        let snapshot = PanelStateCatalogue.make(
            facts: PanelStateCatalogue.facts(),
            events: [.listening, .taskStarted(goal: "Message Amma"), .waitingForAnswer(question: "Which Amma?")], now: now)
        #expect(snapshot.activity == .question)
        #expect(snapshot.task?.status == .waitingForAnswer)
        #expect(snapshot.task?.question == "Which Amma?")
        #expect(snapshot.task?.heldAction == nil)
    }

    @Test("Finished and failed tasks keep their summary")
    func finishedAndFailed() throws {
        let done = try example("08-task-finished").snapshot
        #expect(done.mode == .active)
        #expect(done.activity == .done)
        #expect(done.task?.status == .done)
        #expect(done.task?.isCurrent == false)
        #expect(done.task?.summary?.contains("Sent") == true)

        let failed = try example("08b-task-failed").snapshot
        #expect(failed.activity == .failed)
        #expect(failed.task?.status == .failed)
        #expect(failed.task?.summary?.contains("WhatsApp") == true)
    }

    @Test("Trouble: the voice not set up is an error banner over the ready layout")
    func voiceNotSetUp() throws {
        let snapshot = try example("09-trouble-voice").snapshot
        #expect(snapshot.mode == .ready)
        #expect(snapshot.trouble.map(\.kind) == [.voiceNotSetUp])
        #expect(snapshot.trouble.first?.severity == .error)
        #expect(snapshot.trouble.first?.title == "Handsfree\u{2019}s voice could not be set up")
        #expect(snapshot.details.first?.hasPrefix("Voice: not set up correctly") == true)
        // The ready layout must not promise it will wake while it cannot.
        #expect(!snapshot.canWake)
        #expect(try example("04-ready-asleep").snapshot.canWake)
        #expect(try example("09b-trouble-phrase-not-heard").snapshot.canWake)
    }

    @Test("The header agrees with any banner: \u{201C}Needs attention\u{201D}, never \u{201C}Asleep\u{201D} under a red banner")
    func headerAgreesWithTrouble() throws {
        for name in ["09-trouble-voice", "09b-trouble-phrase-not-heard", "09c-trouble-not-connected"] {
            let snapshot = try example(name).snapshot
            #expect(snapshot.needsAttention, "\(name)")
            #expect(PanelCopy.status(snapshot.activity, mode: snapshot.mode, needsAttention: snapshot.needsAttention) == "Needs attention")
        }
        let calm = try example("04-ready-asleep").snapshot
        #expect(!calm.needsAttention)
        #expect(PanelCopy.status(calm.activity, mode: calm.mode, needsAttention: calm.needsAttention) == "Asleep")
        // Setup outranks trouble in the header.
        #expect(PanelCopy.status(.asleep, mode: .setup, needsAttention: true) == "Setup needed")
    }

    @Test("The largest text examples are drawn at the largest size a carer can choose")
    func largestText() throws {
        for name in ["11b-largest-text-waiting", "11c-largest-text-setup", "11d-largest-text-ready"] {
            #expect(try example(name).textScale == PanelSnapshot.largestTextScale)
        }
    }

    @Test("Trouble: speech heard but never the phrase is a warning, from the third time, and never once it has woken")
    func phraseNotHeard() throws {
        #expect(try example("09b-trouble-phrase-not-heard").snapshot.trouble.map(\.kind) == [.phraseNotHeard])
        #expect(try example("09b-trouble-phrase-not-heard").snapshot.trouble.first?.severity == .warning)

        func trouble(heard: Int, woke: Bool) -> [PanelSnapshot.Trouble.Kind] {
            var listening = PanelStateCatalogue.asleepListening(now)
            for _ in 0..<heard { listening.record(.speechWithoutPhrase, at: now) }
            if woke { listening.record(.woke, at: now) }
            return PanelStateCatalogue.make(facts: PanelStateCatalogue.facts(), events: [.asleep(wakePhrase: "Hey Handsfree")], listening: listening, now: now)
                .trouble.map(\.kind)
        }
        #expect(trouble(heard: 2, woke: false).isEmpty)
        #expect(trouble(heard: 3, woke: false) == [.phraseNotHeard])
        #expect(trouble(heard: 9, woke: true).isEmpty)
    }

    @Test("Trouble: a dropped connection, and a wake listener that cannot run")
    func otherTrouble() throws {
        #expect(try example("09c-trouble-not-connected").snapshot.trouble.map(\.kind) == [.notConnected])

        var listening = PanelStateCatalogue.asleepListening(now)
        listening.record(.cannotListen(reason: "the microphone stopped"), at: now)
        var facts = PanelStateCatalogue.facts()
        let working = PanelStateCatalogue.make(facts: facts, events: [.asleep(wakePhrase: "Hey Handsfree")], listening: listening, now: now)
        #expect(working.trouble.map(\.kind) == [.cannotListen])
        #expect(working.trouble.first?.message.hasPrefix("The microphone stopped.") == true)
        #expect(working.primaryAction == nil)

        // With the microphone turned off, the banner's button opens its settings. (Setup also asks for it.)
        facts.microphone = .notGranted
        let micOff = PanelStateCatalogue.make(facts: facts, events: [.asleep(wakePhrase: "Hey Handsfree")], listening: listening, now: now)
        #expect(micOff.trouble.first?.action?.perform == .openSettings(.microphone))
    }

    @Test("A long session keeps every turn and every step for the panel to scroll")
    func longSession() throws {
        let snapshot = try example("10-long").snapshot
        #expect(snapshot.transcript.count >= 30)
        #expect(snapshot.task?.steps.count == 12)
        #expect((snapshot.task?.goal.count ?? 0) > 150)
        #expect(snapshot.mode == .active)
    }

    @Test("The larger-text example is the waiting state, drawn larger")
    func largerText() throws {
        let large = try example("11-larger-text")
        #expect(large.textScale > 1.3)
        #expect(large.snapshot == (try example("07-waiting-for-yes").snapshot))
    }

    // MARK: - Rules

    @Test("Every companion glyph maps to a panel activity")
    func glyphMapping() {
        let pairs: [(CompanionState.Glyph, PanelSnapshot.Activity)] = [
            (.asleep, .asleep), (.waking, .waking), (.connecting, .connecting), (.listening, .listening),
            (.userSpeaking, .hearing), (.agentSpeaking, .speaking), (.thinking, .working), (.moving, .working),
            (.clicking, .working), (.typing, .working), (.scrolling, .working), (.holding, .waitingForYes),
            (.asking, .question), (.stopped, .stopped), (.done, .done), (.failed, .failed), (.cancelled, .cancelled),
            (.disconnected, .notConnected),
        ]
        for (glyph, activity) in pairs { #expect(PanelSnapshotBuilder.activity(for: glyph) == activity) }
    }

    @Test("Always listening: the ready layout until something is said; no wake-phrase trouble")
    func alwaysOpen() {
        var listening = PanelStateCatalogue.awakeListening(now)
        listening.alwaysOpen = true
        for _ in 0..<5 { listening.record(.speechWithoutPhrase, at: now) }
        let quiet = PanelStateCatalogue.make(facts: PanelStateCatalogue.facts(), events: [.listening], listening: listening, isAlwaysOpen: true, now: now)
        #expect(quiet.mode == .ready)
        #expect(quiet.trouble.isEmpty)
        let talking = PanelStateCatalogue.make(facts: PanelStateCatalogue.facts(), events: [.listening, .userSaid("open Spotify")], listening: listening, isAlwaysOpen: true, now: now)
        #expect(talking.mode == .active)
    }

    @Test("The demo never shows setup or trouble")
    func demo() {
        var inputs = PanelSnapshotBuilder.Inputs(
            facts: PanelStateCatalogue.facts(microphone: .notAsked), companion: CompanionState(), log: SessionLog(),
            listening: ListeningStatus(), wakePhrase: "Hey Handsfree", sleepAfterSeconds: 25, isAlwaysOpen: false, isDemo: true,
            memorySummary: "", partsReal: 0, partsTotal: 0, version: "0.1.0", now: now)
        inputs.log.record(.voiceDisconnected(reason: "dropped"), at: now)
        let snapshot = PanelSnapshotBuilder.make(inputs)
        #expect(snapshot.mode != .setup)
        #expect(snapshot.trouble.isEmpty)
    }

    // MARK: - Wording

    @Test("The wake phrase shown comes from settings")
    func wakePhraseFromSettings() {
        let phrase = "Okay Computer"
        let ready = PanelStateCatalogue.make(
            facts: PanelStateCatalogue.facts(), events: [.asleep(wakePhrase: phrase)], wakePhrase: phrase, now: now)
        #expect(ready.wakePhrase == phrase)
        #expect(PanelCopy.sayPhrase(ready.wakePhrase) == "Say \u{201C}Okay Computer\u{201D}")
        let examples = PanelCopy.examples(wakePhrase: ready.wakePhrase, isAlwaysOpen: false)
        #expect(examples.count == 3)
        #expect(examples.allSatisfy { $0.text.contains(phrase) })

        var listening = PanelStateCatalogue.asleepListening(now)
        listening.record(.cannotListen(reason: "no microphone"), at: now)
        let trouble = PanelStateCatalogue.make(
            facts: PanelStateCatalogue.facts(), events: [.asleep(wakePhrase: phrase)], listening: listening, wakePhrase: phrase, now: now)
        #expect(trouble.trouble.first?.title.contains(phrase) == true)

        // The default phrase is never written into the panel's own copy or views.
        for file in Self.panelSourceFiles where !file.hasSuffix("PanelStateCatalogue.swift") {
            let source = (try? String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)) ?? ""
            #expect(!source.isEmpty, "Could not read \(file)")
            #expect(!Self.stringLiterals(in: source).contains { $0.contains("Hey Handsfree") }, "\(file) writes the wake phrase itself")
        }
    }

    static let bannedWords = ["tool", "sync", "agent id"]

    @Test("Nothing the panel says mentions tools, syncing or agent IDs")
    func noJargon() {
        var strings: [String] = []
        for example in PanelStateCatalogue.examples(now: now) {
            strings += Self.strings(in: example.snapshot)
        }
        let activities: [PanelSnapshot.Activity] = [
            .asleep, .waking, .connecting, .listening, .hearing, .speaking, .working, .question, .waitingForYes,
            .done, .failed, .stopped, .cancelled, .notConnected,
        ]
        for activity in activities {
            strings.append(PanelCopy.activityTitle(activity))
            strings.append(PanelCopy.activitySubtitle(activity, sleepAfterSeconds: 25, isAlwaysOpen: false))
            strings.append(PanelCopy.activitySubtitle(activity, sleepAfterSeconds: 25, isAlwaysOpen: true))
            for mode in [PanelSnapshot.Mode.setup, .ready, .active] { strings.append(PanelCopy.status(activity, mode: mode)) }
        }
        for status in [PanelSnapshot.TaskCard.Status.running, .waitingForAnswer, .waitingForYes, .done, .failed, .stopped] {
            strings.append(PanelCopy.taskStatus(status))
        }
        for permission in PermissionKind.allCases {
            strings += [PanelCopy.instructionsNotAsked(permission), PanelCopy.instructionsTurnedOff(permission)]
        }
        strings += PanelCopy.examples(wakePhrase: "Hey Handsfree", isAlwaysOpen: false).map(\.text)
        strings += PanelCopy.examples(wakePhrase: "Hey Handsfree", isAlwaysOpen: true).map(\.text)
        strings += [
            PanelCopy.setupTitle, PanelCopy.setupIntro, PanelCopy.keysInstructions, PanelCopy.optionalKeyNote, PanelCopy.readySubtitle,
            PanelCopy.alwaysOpenTitle, PanelCopy.alwaysOpenSubtitle, PanelCopy.cannotWakeSubtitle, PanelCopy.risingChime, PanelCopy.fallingChime(sleepAfterSeconds: 25),
            PanelCopy.voiceNotSetUpTitle, PanelCopy.voiceNotSetUpMessage, PanelCopy.notConnectedTitle,
            PanelCopy.notConnectedMessage(reason: nil), PanelCopy.yesHint, PanelCopy.answerHint, PanelCopy.needsAttention, PanelCopy.whereToFind,
            PanelCopy.voiceDetail(isReady: true, checkedAgo: "1 min ago"), PanelCopy.voiceDetail(isReady: false, checkedAgo: nil),
            PanelCopy.voiceDetail(isReady: nil, checkedAgo: nil), PanelCopy.partsDetail(real: 8, total: 9),
        ]
        #expect(strings.count > 100)
        for string in strings {
            for word in Self.bannedWords {
                #expect(!string.lowercased().contains(word), "\u{201C}\(string)\u{201D} contains \u{201C}\(word)\u{201D}")
            }
        }

        // And every string literal written in the panel's source files, in case one bypasses PanelCopy.
        for file in Self.panelSourceFiles {
            let source = (try? String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)) ?? ""
            #expect(!source.isEmpty, "Could not read \(file)")
            for literal in Self.stringLiterals(in: source) {
                for word in Self.bannedWords {
                    #expect(!literal.lowercased().contains(word), "\(file): \u{201C}\(literal)\u{201D} contains \u{201C}\(word)\u{201D}")
                }
            }
        }
    }

    // MARK: - Helpers

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static let panelSourceFiles = [
        "Handsfree/Panel/PanelCopy.swift", "Handsfree/Panel/PanelRootView.swift", "Handsfree/Panel/SetupChecklistView.swift",
        "Handsfree/Panel/ReadyView.swift", "Handsfree/Panel/ActivityView.swift", "Handsfree/Panel/TaskCardView.swift",
        "Handsfree/Panel/ConversationThreadView.swift", "Handsfree/Panel/TroubleBanner.swift", "Handsfree/Panel/PanelFooter.swift",
        "Handsfree/Panel/PanelComponents.swift", "Handsfree/Panel/PanelSnapshotBuilder.swift", "Handsfree/Panel/PanelView.swift",
        "Handsfree/Panel/MenuBarPanelManager.swift",
    ]

    /// Every user-visible string in a snapshot.
    static func strings(in snapshot: PanelSnapshot) -> [String] {
        var strings: [String] = []
        for step in snapshot.setupSteps {
            strings += [step.title, step.reason, step.stateLabel, step.instructions] + step.fileLines
            if let action = step.action { strings.append(action.title) }
        }
        if let note = snapshot.setupNote { strings.append(note) }
        for trouble in snapshot.trouble {
            strings += [trouble.title, trouble.message]
            if let action = trouble.action { strings.append(action.title) }
        }
        strings += snapshot.details
        return strings
    }

    /// The contents of the string literals in Swift source, skipping comment lines.
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            var current: String?
            var escaped = false
            for character in line {
                if var text = current {
                    if escaped { text.append(character); escaped = false; current = text; continue }
                    if character == "\\" { escaped = true; current = text; continue }
                    if character == "\"" { literals.append(text); current = nil; continue }
                    text.append(character)
                    current = text
                } else if character == "\"" {
                    current = ""
                }
            }
        }
        return literals
    }
}
