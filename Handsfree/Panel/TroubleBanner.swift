//
//  TroubleBanner.swift
//  Handsfree
//
//  A banner at the top of the panel when something is wrong: an icon, what
//  is wrong in a sentence, what to do, and a button when there is something
//  to press. Red when it cannot work, amber when it works but needs a look.
//  New for Handsfree.
//

import SwiftUI

struct TroubleBanner: View {
    let trouble: PanelSnapshot.Trouble
    let onAction: (SetupItem.Action) -> Void

    var body: some View {
        let tone: PanelTone = trouble.severity == .error ? .stop : .hold
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .panelSymbol(15, .semibold)
                .foregroundStyle(tone.foreground)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(trouble.title)
                    .panelFont(.headline)
                    .foregroundStyle(DS.Panel.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(trouble.message)
                    .panelFont(.callout)
                    .foregroundStyle(DS.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = trouble.action {
                    Button(action.title) { onAction(action.perform) }
                        .buttonStyle(PanelPrimaryButtonStyle())
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous).fill(tone.tint))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous)
                .strokeBorder(trouble.severity == .error ? AnyShapeStyle(DS.Panel.stopEdge) : AnyShapeStyle(DS.Panel.holdEdge), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PanelCopy.troubleLabel(isError: trouble.severity == .error, title: trouble.title, message: trouble.message))
    }

    private var symbol: String {
        switch trouble.kind {
        case .voiceNotSetUp: return "exclamationmark.octagon.fill"
        case .notConnected: return "wifi.slash"
        case .cannotListen: return "mic.slash.fill"
        case .phraseNotHeard: return "ear.trianglebadge.exclamationmark"
        }
    }
}
