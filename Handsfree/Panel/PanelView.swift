//
//  PanelView.swift
//  Handsfree
//
//  The real panel: watches the app's model and the companion, and draws a
//  fresh `PanelSnapshot` of them with `PanelRootView` whenever either
//  changes. All the deciding happens in `PanelSnapshotBuilder`, which is unit
//  tested; this file only gathers the inputs. AppCoordinator creates it for
//  MenuBarPanelManager. New for Handsfree (6 Nov); it replaces the first panel,
//  which was adapted from Clicky's CompanionPanelView.swift.
//

import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var companion: CompanionModel
    let onSetupAction: (SetupItem.Action) -> Void

    var body: some View {
        // Redrawn every 10 s as well, so "checked 1 min ago" in the details stays true.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            PanelRootView(
                snapshot: snapshot(now: context.date),
                sleepAfterSeconds: Int(app.sleepAfterIdleSeconds.rounded()),
                onAction: onSetupAction,
                onClose: { NotificationCenter.default.post(name: .handsfreeDismissPanel, object: nil) },
                onQuit: { NSApp.terminate(nil) })
        }
        .environment(\.panelTextScale, Self.textScale())
    }

    private func snapshot(now: Date) -> PanelSnapshot {
        PanelSnapshotBuilder.make(PanelSnapshotBuilder.Inputs(
            facts: app.setupFacts,
            companion: companion.state,
            log: companion.log,
            listening: app.listening,
            wakePhrase: app.wakePhrase,
            sleepAfterSeconds: app.sleepAfterIdleSeconds,
            isAlwaysOpen: app.isAlwaysOpen,
            isDemo: app.isDemo,
            memorySummary: app.memorySummary,
            partsReal: app.wiring.filter(\.isReal).count,
            partsTotal: app.wiring.count,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            now: now))
    }

    /// The carer's text size for the panel (`defaults write com.handsfree.Handsfree PanelTextScale 1.3`),
    /// from 1 to 1.6. macOS has no system-wide text size for apps to follow.
    static func textScale(defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: "PanelTextScale")
        guard stored > 0 else { return 1 }
        return CGFloat(min(max(stored, 1), PanelSnapshot.largestTextScale))
    }
}
