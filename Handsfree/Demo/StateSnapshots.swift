//
//  StateSnapshots.swift
//  Handsfree
//
//  For design review: draws the companion's real views for chosen states into
//  PNG files, without putting anything on screen and without needing the
//  Screen Recording permission. `scripts/run_app.sh --render-states <folder>`
//  writes them and quits. Each state is drawn twice, over a light and over a
//  dark background, beside a drawn pointer, framed like the photographs in
//  docs/research/screens/ (600 by 340 points at 2x). It also draws the menu bar panel: from a real
//  AppModel through PanelView (24, 26), and every state of PanelStateCatalogue, light and dark,
//  into <folder>/panel/. New for Handsfree.
//

import AppKit
import HFCore
import SwiftUI

@MainActor
enum StateSnapshots {
    /// Each scene is the events that lead to the state, applied in order.
    static let scenes: [(name: String, events: [ActivityEvent])] = [
        ("20-asleep", [.asleep(wakePhrase: "Hey Handsfree")]),
        ("21-waking", [.asleep(wakePhrase: "Hey Handsfree"), .waking]),
        ("22-awake", [.asleep(wakePhrase: "Hey Handsfree"), .waking, .listening]),
        ("23-woken-with-request", [.asleep(wakePhrase: "Hey Handsfree"), .waking, .listening, .userSaid("open Spotify")]),
        // Drawn with `heardSpeechWithoutPhrase` applied after the events (see `render`).
        ("25-asleep-heard-something", [.asleep(wakePhrase: "Hey Handsfree")]),
        // Existing states, for comparison in the same frame.
        ("cmp-resting", [.listening]),
        ("cmp-disconnected", [.voiceDisconnected(reason: "dropped")]),
        ("cmp-holding", [.taskStarted(goal: "Message Amma"), .heldForConfirmation(action: "Click button \u{201C}Send\u{201D} in WhatsApp"),
                         .waitingForAnswer(question: "Send \u{201C}running late\u{201D} to Amma?")]),
    ]

    static let canvas = CGSize(width: 600, height: 340)
    static let pointer = CGPoint(x: 262, y: 160)

    /// Draws every scene into `folder`. Returns the files written.
    @discardableResult
    static func render(to folder: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        let start = Date()
        for scene in scenes {
            var state = CompanionState()
            for event in scene.events { state.apply(event, now: start) }
            if scene.name.hasSuffix("heard-something") { state.heardSpeechWithoutPhrase(now: start) }
            for (suffix, background) in [("light", Color.white), ("dark", Color(hex: "#1D1C22"))] {
                let url = folder.appendingPathComponent("\(scene.name)-\(suffix).png")
                if write(SnapshotCanvas(state: state, background: background, stackSize: measureStack(state)), to: url) {
                    written.append(url)
                }
            }
        }
        // The panel as a helper sees it: at first run on this Mac (nothing granted yet; Speech
        // Recognition asked for only if the wake listener needs it here), and once set up and asleep.
        let needsSpeech = RealParts.wakeListenerNeedsSpeechRecognition()
        let firstRun = SetupFacts(
            hasElevenLabsKey: true, hasAnthropicKey: true, hasOpenRouterKey: true,
            microphone: .notAsked, accessibility: .notAsked, screenRecording: .notAsked,
            speechRecognition: .notAsked, needsSpeechRecognition: needsSpeech, keysFilePath: "~/Library/Application Support/Handsfree/.env")
        var ready = firstRun
        ready.microphone = .granted; ready.accessibility = .granted; ready.screenRecording = .granted; ready.speechRecognition = .granted
        for (name, facts, asleep) in [("24-panel-first-run", firstRun, false), ("26-panel-asleep-ready", ready, true)] {
            let app = AppModel(setupFacts: facts)
            let companion = CompanionModel(bus: ActivityBus())
            if asleep {
                app.listening.cycleState = "asleep"
                app.listening.listenerRunning = true
                app.listening.record(.started(recognizer: "SpeechAnalyzer (en_IN)"), at: start)
                app.listening.record(.speechWithoutPhrase, at: start)
                app.listening.record(.woke, at: start)
                companion.handle(.asleep(wakePhrase: "Hey Handsfree"))
            } else {
                app.listening.waitingFor = needsSpeech ? "the Microphone permission and the Speech Recognition permission" : "the Microphone permission"
            }
            // Drawn through PanelView, exactly as the app does, from a real AppModel and CompanionModel.
            for scheme in [ColorScheme.light, .dark] {
                let panel = PanelView(app: app, companion: companion, onSetupAction: { _ in })
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
                    .background(scheme == .dark ? Color(hex: "#121116") : Color(hex: "#D7D6DD"))
                    .environment(\.colorScheme, scheme)
                let url = folder.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png")
                if write(panel, to: url, palette: true) { written.append(url) }
            }
        }
        written += renderPanelStates(to: folder.appendingPathComponent("panel"), now: start)
        return written
    }

    /// The menu bar panel in every state of `PanelStateCatalogue`, in light and dark, into `folder`.
    /// Every state is also drawn at the largest text size, light only, into `folder/largest/`, for checking
    /// that nothing truncates or breaks a word (not kept in docs/).
    static func renderPanelStates(to folder: URL, now: Date) -> [URL] {
        let largest = folder.appendingPathComponent("largest")
        try? FileManager.default.createDirectory(at: largest, withIntermediateDirectories: true)
        var written: [URL] = []
        for example in PanelStateCatalogue.examples(now: now) {
            for scheme in [ColorScheme.light, .dark] {
                let url = folder.appendingPathComponent("\(example.name)-\(scheme == .light ? "light" : "dark").png")
                let frame = PanelSnapshotFrame(example: example)
                    .environment(\.colorScheme, scheme)
                if write(frame, to: url, palette: true) { written.append(url) }
            }
            guard example.textScale == 1 else { continue }
            var large = example
            large.textScale = PanelStateCatalogue.largestTextScale
            let url = largest.appendingPathComponent("\(example.name)-largest.png")
            if write(PanelSnapshotFrame(example: large).environment(\.colorScheme, .light), to: url, palette: true) { written.append(url) }
        }
        return written
    }

    private static func measureStack(_ state: CompanionState) -> CGSize {
        let renderer = ImageRenderer(content: CompanionStack(state: state, alignsTrailing: false).fixedSize())
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    /// Draws `view` at 2x into a PNG. With `palette`, a 256-colour PNG (a third of the size), for files kept in docs/.
    private static func write<Content: View>(_ view: Content, to url: URL, palette: Bool = false) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.drawsForSnapshot, true))
        renderer.scale = 2
        if palette, let image = renderer.cgImage { return PalettePNG.write(image, to: url) }
        guard let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// One frame: a drawn pointer, and the companion placed beside it exactly as the overlay places it.
private struct SnapshotCanvas: View {
    let state: CompanionState
    let background: Color
    let stackSize: CGSize

    var body: some View {
        let pointer = StateSnapshots.pointer
        let placement = OverlayGeometry.companionPlacement(
            pointer: pointer, canvasSize: StateSnapshots.canvas, cursorScale: 1, stackSize: stackSize)
        ZStack(alignment: .topLeading) {
            background
            SimulatedPointerArrow()
                .position(x: pointer.x + 7, y: pointer.y + 10.5)
            CompanionGlyphView(glyph: state.glyph, isResting: state.isResting, voiceLevel: state.voiceLevel)
                .position(placement.glyphCenter)
            CompanionStack(state: state, alignsTrailing: placement.opensToLeft)
                .fixedSize()
                .position(placement.stackCenter)
        }
        .frame(width: StateSnapshots.canvas.width, height: StateSnapshots.canvas.height)
        .environment(\.colorScheme, .dark)
    }
}

/// One panel state, framed on a plain desktop-coloured margin so its corners and shadow show.
private struct PanelSnapshotFrame: View {
    let example: PanelStateCatalogue.Example
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PanelRootView(
            snapshot: example.snapshot,
            sleepAfterSeconds: Int(PanelStateCatalogue.sleepAfterSeconds),
            expandsDetails: example.expandsDetails,
            onAction: { _ in }, onClose: {}, onQuit: {})
            .environment(\.panelTextScale, CGFloat(example.textScale))
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .background(colorScheme == .dark ? Color(hex: "#121116") : Color(hex: "#D7D6DD"))
    }
}
