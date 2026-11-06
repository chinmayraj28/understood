//
//  CompanionModel.swift
//  Handsfree
//
//  Listens to the ActivityBus and keeps the companion's state and the session
//  log current for the overlay and the menu bar panel. The rules live in
//  CompanionState and SessionLog; this class only feeds them events and the
//  time. New for Handsfree (Clicky's CompanionManager drove its overlay from
//  its own push-to-talk pipeline instead of an event bus).
//

import Combine
import Foundation
import HFCore
import os

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var state = CompanionState()
    @Published private(set) var log = SessionLog()
    /// Demo freeze: hold the current look still, so it can be inspected and photographed.
    @Published var isFrozen = false

    /// Called after every event, for parts that react to events (the demo's simulated pointer).
    var afterEvent: ((ActivityEvent) -> Void)?

    private let bus: ActivityBus
    private var listeningTask: Task<Void, Never>?
    private var expiryTimer: Timer?
    private let logger = Logger(subsystem: "com.handsfree", category: "companion")

    init(bus: ActivityBus = .shared) {
        self.bus = bus
    }

    func start() {
        guard listeningTask == nil else { return }
        let stream = bus.events()
        listeningTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                self.handle(event)
            }
        }
        // Ten times a second is plenty for captions and states to end on time.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireOldItems() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    func stop() {
        listeningTask?.cancel()
        listeningTask = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    func handle(_ event: ActivityEvent) {
        let now = Date()
        state.apply(event, now: now)
        log.record(event, at: now)
        if case .userSpeaking = event {} else { logger.debug("event: \(String(describing: event), privacy: .private)") }
        afterEvent?(event)
    }

    /// The wake listener heard speech that was not the phrase (no words are passed).
    func heardSpeechWithoutPhrase() {
        state.heardSpeechWithoutPhrase(now: Date())
    }

    private func expireOldItems() {
        guard !isFrozen else { return }
        var updated = state
        updated.expire(now: Date())
        if updated != state { state = updated }
    }
}
