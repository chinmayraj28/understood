//
//  PanelRootView.swift
//  Handsfree
//
//  The menu bar panel: a header with the app and its state, any trouble
//  banners, then one of three layouts (setup checklist, ready, or active),
//  and a quiet footer with Quit. It draws a `PanelSnapshot` and nothing else,
//  so every state can be rendered and tested without the live app.
//
//  The panel's translucent background is the system's own material, put
//  behind this view by MenuBarPanelManager; here the background is clear
//  (or a flat stand-in when drawn to an image). New for Handsfree; it
//  replaces the Clicky-derived PanelView.
//

import SwiftUI

struct PanelRootView: View {
    let snapshot: PanelSnapshot
    let sleepAfterSeconds: Int
    /// For review renders: show the listening details opened out.
    var expandsDetails = false
    let onAction: (SetupItem.Action) -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.drawsForSnapshot) private var drawsForSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Taller than this, the body scrolls. MenuBarPanelManager lowers it on a small screen.
    @Environment(\.panelBodyMaxHeight) private var bodyMaxHeight

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(snapshot: snapshot, onClose: onClose)
            separator
            CappedScrollArea(maxHeight: bodyMaxHeight) {
                content
                    .padding(DS.Panel.inset)
            }
            separator
            PanelFooter(isAlwaysOpen: snapshot.isAlwaysOpen, version: snapshot.version, onQuit: onQuit)
        }
        .frame(width: DS.Panel.width)
        .background(drawsForSnapshot ? AnyShapeStyle(DS.Panel.snapshotBackground) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: DS.Panel.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Panel.cornerRadius, style: .continuous).strokeBorder(DS.Panel.panelEdge, lineWidth: 1))
        .animation(reduceMotion ? .easeOut(duration: DS.Animation.fast) : DS.Panel.change, value: snapshot.mode)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockSpacing) {
            ForEach(snapshot.trouble) { trouble in
                TroubleBanner(trouble: trouble, onAction: onAction)
            }
            switch snapshot.mode {
            case .setup:
                SetupChecklistView(snapshot: snapshot, onAction: onAction)
            case .ready:
                ReadyView(snapshot: snapshot, sleepAfterSeconds: sleepAfterSeconds)
            case .active:
                ActivityView(snapshot: snapshot, sleepAfterSeconds: sleepAfterSeconds)
            }
            if snapshot.mode != .setup && !snapshot.details.isEmpty {
                PanelDetailsView(lines: snapshot.details, isInitiallyExpanded: expandsDetails)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View {
        Rectangle().fill(DS.Panel.separator).frame(height: 1)
    }
}

/// The app's mark and name, its state as an icon and a word, and the close button.
private struct PanelHeader: View {
    let snapshot: PanelSnapshot
    let onClose: () -> Void

    /// Setup, then trouble, outrank what it is doing: the header must agree with any banner below it.
    private var state: (symbol: String, tone: PanelTone, status: String) {
        let status = PanelCopy.status(snapshot.activity, mode: snapshot.mode, needsAttention: snapshot.needsAttention)
        if snapshot.mode == .setup { return ("exclamationmark.circle.fill", .hold, status) }
        if snapshot.needsAttention {
            let hasError = snapshot.trouble.contains { $0.severity == .error }
            return ("exclamationmark.triangle.fill", hasError ? .stop : .hold, status)
        }
        return (snapshot.activity.symbol, snapshot.activity.tone, status)
    }

    var body: some View {
        let (symbol, tone, status) = state

        HStack(spacing: 10) {
            PanelBrandTile()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(PanelCopy.appName)
                        .panelFont(.headline)
                        .foregroundStyle(DS.Panel.textPrimary)
                    if snapshot.isDemo {
                        Text(PanelCopy.demoBadge)
                            .panelFont(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(DS.Panel.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.Panel.accentTint))
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .panelSymbol(10, .semibold)
                        .accessibilityHidden(true)
                    Text(status)
                        .panelFont(.callout)
                        .fontWeight(.medium)
                }
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(DS.Panel.textSecondary) : tone.foreground)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(PanelCopy.appName), \(status)")
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PanelCloseButtonStyle())
            .accessibilityLabel(PanelCopy.closeLabel)
            .help(PanelCopy.closeLabel)
        }
        .padding(.horizontal, DS.Panel.inset)
        .padding(.vertical, 12)
    }
}

/// For whoever is checking why it does not respond: the listener, the conversation and what it
/// has heard (counts only). Closed by default.
private struct PanelDetailsView: View {
    let lines: [String]
    @State private var isExpanded: Bool

    init(lines: [String], isInitiallyExpanded: Bool) {
        self.lines = lines
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: DS.Animation.fast)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .panelSymbol(9, .bold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(isExpanded ? PanelCopy.detailsHide : PanelCopy.detailsTitle)
                }
            }
            .buttonStyle(PanelQuietButtonStyle())
            .padding(.leading, -4)
            .accessibilityValue(isExpanded ? PanelCopy.detailsExpanded : PanelCopy.detailsCollapsed)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .panelFont(.footnote)
                            .foregroundStyle(DS.Panel.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
