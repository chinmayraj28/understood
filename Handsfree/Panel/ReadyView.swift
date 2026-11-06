//
//  ReadyView.swift
//  Handsfree
//
//  The panel when Handsfree is set up and asleep: a calm hero with the wake
//  phrase (from settings) in large type, three things to try, what the two
//  chimes mean, and, if there is one, the last task and what it remembers.
//  New for Handsfree.
//

import SwiftUI

struct ReadyView: View {
    let snapshot: PanelSnapshot
    let sleepAfterSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockSpacing) {
            hero

            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    PanelSectionHeader(title: PanelCopy.examplesTitle).padding(.horizontal, -4)
                    ForEach(PanelCopy.examples(wakePhrase: snapshot.wakePhrase, isAlwaysOpen: snapshot.isAlwaysOpen), id: \.text) { example in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: example.symbol)
                                .panelSymbol(12, .medium)
                                .foregroundStyle(DS.Panel.accent)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(example.text)
                                .panelFont(.body)
                                .foregroundStyle(DS.Panel.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !snapshot.isAlwaysOpen {
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelSectionHeader(title: PanelCopy.soundsTitle).padding(.horizontal, -4)
                        chimeRow(symbol: "arrow.up.right", text: PanelCopy.risingChime)
                        chimeRow(symbol: "arrow.down.right", text: PanelCopy.fallingChime(sleepAfterSeconds: sleepAfterSeconds))
                    }
                }
            }

            if let task = snapshot.task, !task.isCurrent {
                TaskCardView(task: task, isLastTask: true)
            }

            if !snapshot.memorySummary.isEmpty {
                PanelCard {
                    VStack(alignment: .leading, spacing: 6) {
                        PanelSectionHeader(title: PanelCopy.memoryTitle).padding(.horizontal, -4)
                        Text(snapshot.memorySummary)
                            .panelFont(.callout)
                            .foregroundStyle(DS.Panel.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Iris when ready, amber when always listening, grey when a problem above stops it waking.
    private var heroTone: PanelTone {
        if !snapshot.canWake { return .neutral }
        return snapshot.isAlwaysOpen ? .hold : .accent
    }

    private var heroSubtitle: String {
        if !snapshot.canWake { return PanelCopy.cannotWakeSubtitle }
        return snapshot.isAlwaysOpen ? PanelCopy.alwaysOpenSubtitle : PanelCopy.readySubtitle
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(heroTone.tint)
                    .frame(width: 56, height: 56)
                Image(systemName: snapshot.isAlwaysOpen ? "ear.badge.waveform" : "moon.zzz.fill")
                    .panelSymbol(24, .semibold)
                    .foregroundStyle(heroTone.foreground)
            }
            .accessibilityHidden(true)

            Text(snapshot.isAlwaysOpen ? PanelCopy.alwaysOpenTitle : PanelCopy.sayPhrase(snapshot.wakePhrase))
                .panelFont(.hero)
                .foregroundStyle(snapshot.canWake ? AnyShapeStyle(DS.Panel.textPrimary) : AnyShapeStyle(DS.Panel.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(heroSubtitle)
                .panelFont(.callout)
                .foregroundStyle(snapshot.isAlwaysOpen ? AnyShapeStyle(DS.Panel.hold) : AnyShapeStyle(DS.Panel.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private func chimeRow(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .panelSymbol(11, .bold)
                .foregroundStyle(DS.Panel.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .panelFont(.callout)
                .foregroundStyle(DS.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
