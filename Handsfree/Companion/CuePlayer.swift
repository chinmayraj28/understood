//
//  CuePlayer.swift
//  Handsfree
//
//  Plays the waking and sleeping sounds (SoundCues.swift) as the ActivityBus
//  reports them. Uses NSSound with WAV data built in code: no audio engine of
//  our own, so it cannot compete with the voice session's or the wake
//  listener's use of the microphone. New for Handsfree.
//

import AppKit
import Foundation
import HFCore

@MainActor
final class CuePlayer {
    private let bus: ActivityBus
    private var rules = SoundCueRules()
    private var listeningTask: Task<Void, Never>?
    private var sounds: [SoundCue: NSSound] = [:]

    init(bus: ActivityBus = .shared) {
        self.bus = bus
        for cue in SoundCue.allCases {
            sounds[cue] = NSSound(data: CueTone.wavData(for: cue))
        }
    }

    func start() {
        guard listeningTask == nil else { return }
        let stream = bus.events()
        listeningTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                if let cue = self.rules.cue(for: event) { self.play(cue) }
            }
        }
    }

    func stop() {
        listeningTask?.cancel()
        listeningTask = nil
    }

    private func play(_ cue: SoundCue) {
        guard let sound = sounds[cue] else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
