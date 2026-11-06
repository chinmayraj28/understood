//
//  PanelFooter.swift
//  Handsfree
//
//  The panel's bottom bar: Quit, with the wake mode and version kept quiet
//  on the right. At large text sizes, where they cannot share a line, the
//  quiet information moves under Quit; a word is never broken. There is no
//  "Play demo" here on purpose: the demo is a tool for reviewing and
//  recording, started from the command line only (scripts/run_app.sh
//  --demo), and must never start a second copy. New for Handsfree.
//

import SwiftUI

struct PanelFooter: View {
    let isAlwaysOpen: Bool
    let version: String
    let onQuit: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                quitButton
                Spacer(minLength: 8)
                information
            }
            VStack(alignment: .leading, spacing: 4) {
                quitButton
                information
                    .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, DS.Panel.inset)
        .padding(.vertical, 8)
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .panelSymbol(11, .semibold)
                    .accessibilityHidden(true)
                Text(PanelCopy.quit)
            }
            .fixedSize()
        }
        .buttonStyle(PanelQuietButtonStyle())
        .accessibilityLabel(PanelCopy.quit)
    }

    private var information: some View {
        Text("\(PanelCopy.footerMode(isAlwaysOpen: isAlwaysOpen)) \u{00B7} \(PanelCopy.version(version))")
            .panelFont(.footnote)
            .foregroundStyle(DS.Panel.textTertiary)
            .fixedSize()
    }
}
