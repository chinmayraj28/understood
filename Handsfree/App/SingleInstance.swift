//
//  SingleInstance.swift
//  Handsfree
//
//  Only one copy of Handsfree may run. Two copies mean two overlays, two wake
//  listeners on one microphone and possibly two conversations answering at
//  once. On 6 Nov the user saw exactly that: the real app and a demo copy
//  started from its panel. So at launch, before anything is created, the app
//  looks for another running process with its bundle identifier, whatever its
//  path, build configuration or how it was started (`open -n` included). If
//  one is already running, the new copy asks it to show its panel and quits.
//  The decision is a pure function, unit tested with fake process lists.
//  New for Handsfree.
//

import Foundation

/// One running copy of the app, as macOS reports it.
struct RunningCopy: Equatable {
    let processID: Int32
    let launchDate: Date?
}

enum SingleInstance {
    enum Decision: Equatable {
        /// No other copy: carry on starting.
        case run
        /// Another copy was running first: let it show its panel, and quit.
        case handOver(to: Int32)
    }

    /// The posted name a second copy uses to ask the first to show its panel.
    static let showPanelNotification = "com.handsfree.Handsfree.showPanel"

    /// Which copy keeps running: the one launched first. If two start in the same instant (or a
    /// launch date is missing), the lower process id wins, so both never quit and both never stay.
    static func decide(me: RunningCopy, others: [RunningCopy]) -> Decision {
        let rivals = others.filter { $0.processID != me.processID }
        guard let first = rivals.min(by: launchedEarlier) else { return .run }
        return launchedEarlier(first, me) ? .handOver(to: first.processID) : .run
    }

    private static func launchedEarlier(_ lhs: RunningCopy, _ rhs: RunningCopy) -> Bool {
        if let left = lhs.launchDate, let right = rhs.launchDate, left != right { return left < right }
        return lhs.processID < rhs.processID
    }

    /// Whether this launch takes part in the one-copy rule. `--render-states` only draws images
    /// into a folder and quits: no overlay, no microphone, no status file. It is the one way to
    /// review the look while the user's copy is running, so it is exempt.
    static func applies(to options: LaunchOptions) -> Bool {
        options.renderStatesFolder == nil
    }
}
