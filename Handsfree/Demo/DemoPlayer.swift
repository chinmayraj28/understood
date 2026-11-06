//
//  DemoPlayer.swift
//  Handsfree
//
//  Plays DemoScript on the real ActivityBus, so the companion and the panel
//  react exactly as they would to the real packages. Glides a simulated
//  pointer instead of the user's real one. New for Handsfree.
//

import AppKit
import Foundation
import HFCore
import os

@MainActor
final class DemoPlayer {
    private let bus: ActivityBus
    private let pointer: PointerTracker
    private let model: CompanionModel
    private let backdrop: DemoBackdropModel
    private let screenSize: CGSize
    private let mainDisplayHeight: CGFloat
    private let loops: Bool
    private let freezeMoment: String?
    private let momentLogURL: URL?
    private let logger = Logger(subsystem: "com.handsfree", category: "demo")

    private var steps: [DemoStep] = []
    private var nextStepIndex = 0
    private var startedAt = Date()
    private var frameTimer: Timer?
    private var typedSoFar = 0

    init(
        bus: ActivityBus, pointer: PointerTracker, model: CompanionModel, backdrop: DemoBackdropModel,
        mainScreen: NSScreen, loops: Bool, freezeMoment: String?, momentLogURL: URL?
    ) {
        self.bus = bus
        self.pointer = pointer
        self.model = model
        self.backdrop = backdrop
        self.screenSize = mainScreen.frame.size
        self.mainDisplayHeight = mainScreen.frame.height
        self.loops = loops
        self.freezeMoment = freezeMoment
        self.momentLogURL = momentLogURL
    }

    func play() {
        steps = DemoScript.steps(screen: screenSize)
        if let freezeMoment, DemoScript.indexOfMoment(freezeMoment, in: steps) == nil {
            logger.error("Unknown demo moment \(freezeMoment, privacy: .public). Known: \(DemoScript.moments.joined(separator: ", "), privacy: .public)")
        }
        if let momentLogURL { try? Data().write(to: momentLogURL) }
        model.afterEvent = { [weak self] event in self?.react(to: event) }
        restart()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func restart() {
        nextStepIndex = 0
        startedAt = Date()
        typedSoFar = 0
        backdrop.reset()
        pointer.placeSimulatedPointer(atAppKitPoint: appKitPoint(DemoLayout.pointerStart(screen: screenSize)))
    }

    private func advance() {
        let elapsed = Date().timeIntervalSince(startedAt)
        while nextStepIndex < steps.count && steps[nextStepIndex].time <= elapsed {
            let step = steps[nextStepIndex]
            nextStepIndex += 1
            if let event = step.event { bus.post(event) }
            if let moment = step.moment {
                recordMoment(moment)
                if moment == freezeMoment {
                    freeze()
                    return
                }
            }
        }
        if nextStepIndex >= steps.count && elapsed > DemoScript.duration(screen: screenSize) {
            if loops { restart() } else { stop() }
        }
    }

    /// Holds the current look still: no more steps, and nothing expires.
    private func freeze() {
        stop()
        // Let the events just posted arrive and their entrance animations finish first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.model.isFrozen = true
        }
    }

    /// The demo's side effects that the real hands and apps would produce.
    private func react(to event: ActivityEvent) {
        switch event {
        case .pointerMoving(let destination, let duration):
            if duration > 0 {
                pointer.glideSimulatedPointer(toAppKitPoint: appKitPoint(destination), seconds: duration)
            } else {
                pointer.placeSimulatedPointer(atAppKitPoint: appKitPoint(destination))
            }
        case .clicked(let point):
            pointer.placeSimulatedPointer(atAppKitPoint: appKitPoint(point))
            backdrop.click(atTopLeft: point, screen: screenSize)
            typedSoFar = 0
        case .halted:
            // The real hands freeze mid-glide on "stop"; so does the demo's pointer.
            pointer.freezeSimulatedPointer()
        case .typing:
            typedSoFar += 3
            backdrop.type(characterCount: typedSoFar)
        default:
            break
        }
    }

    private func appKitPoint(_ topLeft: CGPoint) -> CGPoint {
        OverlayGeometry.appKitPoint(fromTopLeft: topLeft, mainDisplayHeight: mainDisplayHeight)
    }

    /// Appends "<moment> <unix time>" so a script can photograph each moment as it happens.
    private func recordMoment(_ moment: String) {
        logger.notice("demo moment \(moment, privacy: .public)")
        guard let momentLogURL, let handle = try? FileHandle(forWritingTo: momentLogURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("\(moment) \(Date().timeIntervalSince1970)\n".utf8))
    }
}
