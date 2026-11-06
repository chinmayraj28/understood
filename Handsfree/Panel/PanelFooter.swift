//
//  PanelFooter.swift
//  Handsfree
//
//  The panel's bottom bar: Quit, with the wake mode and version kept quiet
//  on the right. There is no "Play demo" here on purpose: the demo is a tool
//  for reviewing and recording, started from the command line only
//  (scripts/run_app.sh --demo), and must never start a second copy.
//  New for Handsfree.
//

import SwiftUI

struct PanelFooter: View {
    let isAlwaysOpen: Bool
    let version: String
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onQuit) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .panelSymbol(11, .semibold)
                        .accessibilityHidden(true)
                    Text(PanelCopy.quit)
                }
            }
            .buttonStyle(PanelQuietButtonStyle())
            .accessibilityLabel(PanelCopy.quit)

            Spacer(minLength: 8)

            // One line when it fits; at larger text sizes, two lines rather than a cut-off word.
            ViewThatFits(in: .horizontal) {
                Text("\(PanelCopy.footerMode(isAlwaysOpen: isAlwaysOpen)) \u{00B7} \(PanelCopy.version(version))")
                    .lineLimit(1)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(PanelCopy.footerMode(isAlwaysOpen: isAlwaysOpen))
                    Text(PanelCopy.version(version))
                }
                .fixedSize()
            }
            .panelFont(.footnote)
            .foregroundStyle(DS.Panel.textTertiary)
            // Offered its width before the spacer, so it only wraps when it truly does not fit.
            .layoutPriority(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, DS.Panel.inset)
        .padding(.vertical, 8)
    }
}
