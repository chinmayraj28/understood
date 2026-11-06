//
//  StateSnapshots.swift
//  Handsfree
//
//  For design review: draws the companion's real views for chosen states into
//  PNG files, without putting anything on screen and without needing the
//  Screen Recording permission. `scripts/run_app.sh --render-states <folder>`
//  writes them and quits. Each state is drawn twice, over a light and over a
//  dark background, beside a drawn pointer, framed like the photographs in
//  docs/research/screens/ (600 by 340 points at 2x). New for Handsfree.
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
        // The panel while asleep, with Speech Recognition still to grant, as a helper sees it at first run.
        let facts = SetupFacts(
            hasElevenLabsKey: true, hasAnthropicKey: true, hasOpenRouterKey: true,
            microphone: .granted, accessibility: .granted, screenRecording: .granted,
            speechRecognition: .notAsked, needsSpeechRecognition: true, keysFilePath: "~/Library/Application Support/Handsfree/.env")
        let app = AppModel(setupFacts: facts)
        app.listening.waitingFor = "the Speech Recognition permission"
        let companion = CompanionModel(bus: ActivityBus())
        companion.handle(.asleep(wakePhrase: "Hey Handsfree"))
        let panel = PanelView(app: app, companion: companion, onSetupAction: { _ in }, onPlayDemo: {})
            .frame(width: 372)
            .environment(\.colorScheme, .dark)
        let panelURL = folder.appendingPathComponent("24-panel-asleep.png")
        if write(panel, to: panelURL) { written.append(panelURL) }
        return written
    }

    private static func measureStack(_ state: CompanionState) -> CGSize {
        let renderer = ImageRenderer(content: CompanionStack(state: state, alignsTrailing: false).fixedSize())
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    private static func write<Content: View>(_ view: Content, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
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
