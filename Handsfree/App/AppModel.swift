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

    var setupItems: [SetupItem] { SetupCheck.items(for: setupFacts) }
    var isReady: Bool { SetupCheck.isReady(setupFacts) }

    init(setupFacts: SetupFacts) {
        self.setupFacts = setupFacts
    }
}
