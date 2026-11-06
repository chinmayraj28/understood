//
//  AppModel.swift
//  Handsfree
//
//  What the menu bar panel shows about the app itself (as opposed to the
//  session): setup status, which parts are real, and what memory knows.
//  New for Handsfree.
//

import Combine
import Foundation
import HFCore

@MainActor
final class AppModel: ObservableObject {
    @Published var setupFacts: SetupFacts
    @Published var wiring: [PartWiring] = []
    @Published var memorySummary = ""
    @Published var isDemo = false
    /// What wakes it, and how long it stays awake with nothing going on (from Settings).
    @Published var wakePhrase = "Hey Handsfree"
    @Published var sleepAfterIdleSeconds = 15.0
    /// WAKE_MODE=always: a conversation is kept open and no phrase is needed.
    @Published var isAlwaysOpen = false
    /// The wake listener, the conversation, and what has been heard (counts only).
    @Published var listening = ListeningStatus()

    var setupItems: [SetupItem] { SetupCheck.items(for: setupFacts) }
    var isReady: Bool { SetupCheck.isReady(setupFacts) }

    init(setupFacts: SetupFacts) {
        self.setupFacts = setupFacts
    }
}
