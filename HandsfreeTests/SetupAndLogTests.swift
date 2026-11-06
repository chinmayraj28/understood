//
//  SetupAndLogTests.swift
//  HandsfreeTests
//
//  First-run checks, the session log, launch options, overlay geometry and the demo script.
//

import CoreGraphics
import Foundation
import HFCore
import Testing

@Suite("First-run checks")
struct SetupCheckTests {
    func facts(
        elevenLabs: Bool = true, anthropic: Bool = true, openRouter: Bool = true,
        microphone: PermissionStatus = .granted, accessibility: PermissionStatus = .granted,
        screenRecording: PermissionStatus = .granted, speech: PermissionStatus = .granted,
        needsSpeech: Bool = true
    ) -> SetupFacts {
        SetupFacts(
            hasElevenLabsKey: elevenLabs, hasAnthropicKey: anthropic, hasOpenRouterKey: openRouter,
            microphone: microphone, accessibility: accessibility, screenRecording: screenRecording,
            speechRecognition: speech, needsSpeechRecognition: needsSpeech,
            keysFilePath: "/repo/.env")
    }

    @Test("Everything in place means nothing to do")
    func allReady() {
        #expect(SetupCheck.items(for: facts()).isEmpty)
        #expect(SetupCheck.isReady(facts()))
    }

    @Test("Each missing permission is blocking, with the right button")
    func missingPermissions() {
        let notAsked = SetupCheck.items(for: facts(microphone: .notAsked, accessibility: .notAsked, screenRecording: .notAsked, speech: .notAsked))
        #expect(notAsked.map(\.id) == ["microphone", "speechRecognition", "accessibility", "screenRecording"])
        #expect(notAsked.allSatisfy { $0.isBlocking })
        #expect(notAsked[0].action == .askMacOS(.microphone))
        #expect(notAsked[1].action == .askMacOS(.speechRecognition))
        #expect(notAsked[2].action == .askMacOS(.accessibility))
        #expect(notAsked[3].action == .askMacOS(.screenRecording))

        let refused = SetupCheck.items(for: facts(microphone: .notGranted, accessibility: .notGranted, screenRecording: .notGranted, speech: .notGranted))
        #expect(refused[0].action == .openSettings(.microphone))
        #expect(refused[1].action == .openSettings(.speechRecognition))
        #expect(refused[2].action == .openSettings(.accessibility))
        #expect(refused[3].action == .openSettings(.screenRecording))
        #expect(SetupCheck.missingPermissions(facts(speech: .notGranted)) == [.speechRecognition])
        #expect(!SetupCheck.isReady(facts(speech: .notAsked)))
        #expect(!SetupCheck.isReady(facts(accessibility: .notGranted)))
        #expect(SetupCheck.missingPermissions(facts(accessibility: .notGranted)) == [.accessibility])
    }

    @Test("Missing keys are named, with where to put them")
    func missingKeys() {
        let oneMissing = SetupCheck.items(for: facts(anthropic: false))
        #expect(oneMissing.count == 1)
        #expect(oneMissing[0].title == "A key is missing")
        #expect(oneMissing[0].instructions.contains("ANTHROPIC_API_KEY"))
        #expect(oneMissing[0].instructions.contains("/repo/.env"))
        #expect(oneMissing[0].isBlocking)

        let twoMissing = SetupCheck.items(for: facts(elevenLabs: false, anthropic: false))
        #expect(twoMissing[0].title == "Two keys are missing")
        #expect(twoMissing[0].instructions.contains("ELEVENLABS_API_KEY and ANTHROPIC_API_KEY"))
    }

    @Test("Speech Recognition is only asked for when the wake phrase is used")
    func speechOnlyForTheWakePhrase() {
        let alwaysOpen = facts(speech: .notAsked, needsSpeech: false)
        #expect(SetupCheck.items(for: alwaysOpen).isEmpty)
        #expect(SetupCheck.isReady(alwaysOpen))
        #expect(SetupCheck.missingPermissions(alwaysOpen).isEmpty)
        let item = SetupCheck.items(for: facts(speech: .notAsked)).first
        #expect(item?.instructions.contains("wake phrase") == true)
        #expect(item?.instructions.contains("leaves the Mac") == true, "the helper is told no audio leaves the Mac while it waits")
    }

    @Test("A missing OpenRouter key is a note, not a blocker")
    func openRouterOptional() {
        let items = SetupCheck.items(for: facts(openRouter: false))
        #expect(items.count == 1)
        #expect(!items[0].isBlocking)
        #expect(SetupCheck.isReady(facts(openRouter: false)))
    }

    @Test("Instructions are written for a helper, never empty")
    func wording() {
        let everything = SetupCheck.items(for: facts(
            elevenLabs: false, anthropic: false, openRouter: false,
            microphone: .notAsked, accessibility: .notGranted, screenRecording: .notAsked, speech: .notAsked))
        #expect(everything.count == 6)
        for item in everything {
            #expect(!item.instructions.isEmpty)
            #expect(item.instructions.hasSuffix("."))
        }
    }
}

@Suite("Session log")
struct SessionLogTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Transcript keeps both sides in order and drops streamed duplicates")
    func transcript() {
        var log = SessionLog()
        log.record(.userSaid("Message Amma"), at: start)
        log.record(.agentSpeaking("Okay."), at: start)
        log.record(.agentSpeaking("Okay."), at: start)
        log.record(.userSaid("   "), at: start)
        #expect(log.transcript.map(\.text) == ["Message Amma", "Okay."])
        #expect(log.transcript.map(\.speaker) == [.user, .assistant])
    }

    @Test("Transcript is capped")
    func transcriptCap() {
        var log = SessionLog()
        for index in 0..<100 { log.record(.userSaid("line \(index)"), at: start) }
        #expect(log.transcript.count == SessionLog.maximumTranscriptLines)
        #expect(log.transcript.last?.text == "line 99")
    }

    @Test("A task collects its steps, waits, and lands in recent tasks")
    func taskLifecycle() {
        var log = SessionLog()
        log.record(.taskStarted(goal: "Message Amma"), at: start)
        log.record(.thinking(caption: "Looking at the screen"), at: start)
        log.record(.progress("Opening WhatsApp"), at: start)
        log.record(.progress("Opening WhatsApp"), at: start)
        #expect(log.currentTask?.steps == ["Looking at the screen", "Opening WhatsApp"])
        log.record(.heldForConfirmation(action: "Click Send"), at: start)
        #expect(log.currentTask?.status == .needsInput)
        #expect(log.currentTask?.waitingOn?.contains("Click Send") == true)
        log.record(.progress("Sending"), at: start)
        #expect(log.currentTask?.status == .running)
        #expect(log.currentTask?.waitingOn == nil)
        log.record(.taskEnded(status: .done, summary: "Sent."), at: start)
        #expect(log.currentTask == nil)
        #expect(log.recentTasks.first?.status == .done)
        #expect(log.recentTasks.first?.summary == "Sent.")
    }

    @Test("The voice problem shows while disconnected")
    func voiceProblem() {
        var log = SessionLog()
        log.record(.voiceDisconnected(reason: "No network"), at: start)
        #expect(log.voiceProblem == "No network")
        log.record(.listening, at: start)
        #expect(log.voiceProblem == nil)
        log.record(.voiceDisconnected(reason: "No network"), at: start)
        log.record(.asleep(wakePhrase: "Hey Handsfree"), at: start)
        #expect(log.voiceProblem == nil, "asleep is how it waits, not a problem")
    }
}

@Suite("Launch options")
struct LaunchOptionsTests {
    @Test("Parses the demo and test options and ignores what macOS adds")
    func parse() {
        let options = LaunchOptions.parse([
            "-NSDocumentRevisionsDebugMode", "YES", "--demo", "--backdrop", "--quit-after", "12.5",
            "--freeze", "holding", "--capturable", "--moment-log", "/tmp/moments.log",
        ])
        #expect(options.isDemo)
        #expect(options.showsBackdrop)
        #expect(options.quitAfterSeconds == 12.5)
        #expect(options.demoFreezeMoment == "holding")
        #expect(options.overlayIsCapturable)
        #expect(options.demoMomentLogPath == "/tmp/moments.log")
        #expect(LaunchOptions.parse(["--render-states", "/tmp/states"]).renderStatesFolder == "/tmp/states")
        #expect(LaunchOptions.parse([]).renderStatesFolder == nil)
        #expect(LaunchOptions.parse(["--sync-only", "--quit-after", "12"]).syncOnly)
        #expect(!LaunchOptions.parse([]).syncOnly)
        #expect(!options.requestsPermissionsAtLaunch)
    }

    @Test("No options means the normal app")
    func defaults() {
        #expect(LaunchOptions.parse([]) == LaunchOptions())
        #expect(LaunchOptions.parse(["--quit-after", "soon"]).quitAfterSeconds == nil)
    }
}

@Suite("Overlay geometry")
struct OverlayGeometryTests {
    @Test("HFCore points and AppKit points convert both ways")
    func conversions() {
        let topLeft = CGPoint(x: 100, y: 50)
        let appKit = OverlayGeometry.appKitPoint(fromTopLeft: topLeft, mainDisplayHeight: 956)
        #expect(appKit == CGPoint(x: 100, y: 906))
        #expect(OverlayGeometry.topLeftPoint(fromAppKit: appKit, mainDisplayHeight: 956) == topLeft)
        // A second display to the right of the main one, same height.
        let secondScreen = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        #expect(OverlayGeometry.canvasPoint(fromAppKit: CGPoint(x: 1500, y: 1000), screenFrame: secondScreen) == CGPoint(x: 30, y: 80))
    }

    @Test("Opens below and to the right when there is room, without covering the tip")
    func defaultPlacement() {
        let placement = OverlayGeometry.companionPlacement(
            pointer: CGPoint(x: 200, y: 200), canvasSize: CGSize(width: 1470, height: 956), cursorScale: 1,
            stackSize: CGSize(width: 300, height: 40))
        #expect(!placement.opensToLeft)
        #expect(!placement.opensUpward)
        #expect(placement.glyphCenter.x > 200 && placement.glyphCenter.y > 200)
        #expect(placement.stackCenter.x - 150 > placement.glyphCenter.x)
    }

    @Test("Mirrors to the left near the right edge and above near the bottom")
    func edgePlacement() {
        let canvas = CGSize(width: 1470, height: 956)
        let stack = CGSize(width: 380, height: 200)
        let nearRight = OverlayGeometry.companionPlacement(pointer: CGPoint(x: 1400, y: 200), canvasSize: canvas, cursorScale: 1, stackSize: stack)
        #expect(nearRight.opensToLeft)
        #expect(nearRight.stackCenter.x + stack.width / 2 <= nearRight.glyphCenter.x)
        let nearBottom = OverlayGeometry.companionPlacement(pointer: CGPoint(x: 200, y: 900), canvasSize: canvas, cursorScale: 1, stackSize: stack)
        #expect(nearBottom.opensUpward)
        #expect(nearBottom.glyphCenter.y < 900)
        #expect(nearBottom.stackCenter.y + stack.height / 2 <= canvas.height - OverlayGeometry.edgeMargin)
    }

    @Test("Never places anything off screen, even in a corner")
    func corners() {
        let canvas = CGSize(width: 1470, height: 956)
        let stack = CGSize(width: 380, height: 220)
        for pointer in [CGPoint(x: 0, y: 0), CGPoint(x: 1470, y: 956), CGPoint(x: 1470, y: 0), CGPoint(x: 0, y: 956)] {
            let placement = OverlayGeometry.companionPlacement(pointer: pointer, canvasSize: canvas, cursorScale: 2, stackSize: stack)
            #expect(placement.stackCenter.x - stack.width / 2 >= OverlayGeometry.edgeMargin - 0.001)
            #expect(placement.stackCenter.x + stack.width / 2 <= canvas.width - OverlayGeometry.edgeMargin + 0.001)
            #expect(placement.stackCenter.y - stack.height / 2 >= OverlayGeometry.edgeMargin - 0.001)
            #expect(placement.stackCenter.y + stack.height / 2 <= canvas.height - OverlayGeometry.edgeMargin + 0.001)
        }
    }

    @Test("A bigger pointer pushes the companion further away")
    func cursorScale() {
        let normal = OverlayGeometry.companionPlacement(pointer: CGPoint(x: 200, y: 200), canvasSize: CGSize(width: 1470, height: 956), cursorScale: 1, stackSize: .zero)
        let large = OverlayGeometry.companionPlacement(pointer: CGPoint(x: 200, y: 200), canvasSize: CGSize(width: 1470, height: 956), cursorScale: 2.5, stackSize: .zero)
        #expect(large.glyphCenter.x > normal.glyphCenter.x)
        #expect(large.glyphCenter.y > normal.glyphCenter.y)
    }

    @Test("Smoothstep eases in and out")
    func smoothstep() {
        #expect(OverlayGeometry.smoothstep(0) == 0)
        #expect(OverlayGeometry.smoothstep(1) == 1)
        #expect(OverlayGeometry.smoothstep(0.5) == 0.5)
        #expect(OverlayGeometry.smoothstep(2) == 1)
    }
}

@Suite("Demo script")
struct DemoScriptTests {
    let screen = CGSize(width: 1470, height: 956)

    @Test("Steps are in time order")
    func ordered() {
        let times = DemoScript.steps(screen: screen).map(\.time)
        #expect(times == times.sorted())
    }

    @Test("Every named moment exists, once, in order")
    func moments() {
        let steps = DemoScript.steps(screen: screen)
        let named = steps.compactMap(\.moment)
        #expect(named == DemoScript.moments)
    }

    @Test("Playing the demo reaches every companion glyph")
    func coversEveryGlyph() {
        let steps = DemoScript.steps(screen: screen)
        var state = CompanionState()
        var seen: Set<String> = []
        let start = Date(timeIntervalSince1970: 0)
        var stepIndex = 0
        // Simulate 60 frames a second, like the real player and expiry timer.
        var time = 0.0
        while time < DemoScript.duration(screen: screen) {
            while stepIndex < steps.count && steps[stepIndex].time <= time {
                if let event = steps[stepIndex].event { state.apply(event, now: start.addingTimeInterval(time)) }
                stepIndex += 1
            }
            state.expire(now: start.addingTimeInterval(time))
            seen.insert(String(describing: state.glyph))
            time += 1.0 / 60.0
        }
        let everyGlyph: [CompanionState.Glyph] = [
            .asleep, .waking,
            .listening, .userSpeaking, .agentSpeaking, .thinking, .moving, .clicking, .typing, .scrolling,
            .holding, .asking, .stopped, .done, .failed, .disconnected,
        ]
        for glyph in everyGlyph {
            #expect(seen.contains(String(describing: glyph)), "the demo never shows \(glyph)")
        }
        #expect(state.isAsleep, "the demo ends asleep, as the app does after a quiet spell")
        #expect(state.sleepHint == "Say \u{201C}\(DemoScript.wakePhrase)\u{201D}")
    }

    @Test("Pointer targets land inside the practice window's controls")
    func targetsOnControls() {
        let window = DemoLayout.windowRect(screen: screen)
        for step in DemoScript.steps(screen: screen) {
            if case .clicked(let point) = step.event {
                #expect(window.contains(point))
            }
        }
        let send = DemoLayout.sendButtonRect(screen: screen)
        #expect(send.maxX <= window.maxX)
    }
}
