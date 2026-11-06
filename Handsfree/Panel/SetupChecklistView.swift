//
//  SetupChecklistView.swift
//  Handsfree
//
//  The panel at first run: a checklist for whoever is setting Handsfree up.
//  One row per requirement, each with an icon, a one-line reason and its
//  state in words. The next step is opened out with what to do and one
//  primary button; the progress ("2 of 4 done") is shown above. New for
//  Handsfree; the meaning of the wording comes from SetupCheck.
//

import SwiftUI

struct SetupChecklistView: View {
    let snapshot: PanelSnapshot
    let onAction: (SetupItem.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PanelCopy.setupTitle)
                    .panelFont(.title)
                    .foregroundStyle(DS.Panel.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(PanelCopy.setupIntro)
                    .panelFont(.callout)
                    .foregroundStyle(DS.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            SetupProgressBar(done: snapshot.setupDoneCount, total: snapshot.setupSteps.count)
                .padding(.horizontal, 4)

            PanelCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.setupSteps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 {
                            Rectangle().fill(DS.Panel.separator).frame(height: 1).padding(.leading, 52)
                        }
                        SetupStepRow(step: step, isNext: step.id == snapshot.nextStep?.id, onAction: onAction)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(PanelCopy.setupTitle)

            if let note = snapshot.setupNote {
                SetupNote(symbol: "info.circle", title: nil, text: note)
            }
            SetupNote(symbol: "menubar.arrow.up.rectangle", title: PanelCopy.whereToFindTitle, text: PanelCopy.whereToFind)
        }
    }
}

/// "2 of 4 done", with one segment per step.
private struct SetupProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < done ? AnyShapeStyle(DS.Panel.success) : AnyShapeStyle(DS.Panel.quietFillHover))
                        .frame(height: 4)
                }
            }
            Text(PanelCopy.setupProgress(done: done, total: total))
                .panelFont(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(DS.Panel.textSecondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PanelCopy.setupProgressLabel)
        .accessibilityValue(PanelCopy.setupProgress(done: done, total: total))
    }
}

private struct SetupStepRow: View {
    let step: PanelSnapshot.SetupStep
    let isNext: Bool
    let onAction: (SetupItem.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PanelIconTile(symbol: symbol, tone: step.isDone ? .success : (isNext ? .accent : .neutral))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.title)
                        .panelFont(.headline)
                        .foregroundStyle(DS.Panel.textPrimary)
                    Spacer(minLength: 4)
                    PanelStatusTag(symbol: stateSymbol, text: step.stateLabel, tone: stateTone, isQuiet: !step.isDone && !isNext)
                }
                // A finished step needs no explaining: one line keeps the list short.
                if !step.isDone {
                    Text(step.reason)
                        .panelFont(.callout)
                        .foregroundStyle(DS.Panel.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isNext && !step.isDone {
                    nextStepDetail
                }
            }
            .padding(.top, step.isDone ? 4 : 0)
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, step.isDone ? 8 : 12)
        .background(isNext ? AnyShapeStyle(DS.Panel.accentTint.opacity(0.5)) : AnyShapeStyle(Color.clear))
    }

    @ViewBuilder private var nextStepDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.instructions)
                .panelFont(.callout)
                .foregroundStyle(DS.Panel.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = step.detail {
                Text(detail)
                    .panelFont(.mono)
                    .foregroundStyle(DS.Panel.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Panel.quietFill))
                    .accessibilityLabel(PanelCopy.fileLocation(detail))
            }
            if !step.fileLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(step.fileLines, id: \.self) { line in
                        Text(line)
                            .panelFont(.mono)
                            .foregroundStyle(DS.Panel.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Panel.quietFill))
                .accessibilityElement(children: .combine)
            }
            if let action = step.action {
                Button(action.title) { onAction(action.perform) }
                    .buttonStyle(PanelPrimaryButtonStyle())
            }
        }
        .padding(.top, 8)
    }

    private var symbol: String {
        switch step.kind {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .keys: return "key.fill"
        }
    }

    private var stateSymbol: String {
        if step.isDone { return "checkmark" }
        return step.stateLabel == PanelCopy.stepTurnedOff ? "exclamationmark" : "circle"
    }

    private var stateTone: PanelTone {
        if step.isDone { return .success }
        return step.stateLabel == PanelCopy.stepTurnedOff ? .stop : (isNext ? .accent : .neutral)
    }
}

/// A quiet note under the checklist.
private struct SetupNote: View {
    let symbol: String
    let title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .panelSymbol(13, .medium)
                .foregroundStyle(DS.Panel.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .panelFont(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(DS.Panel.textSecondary)
                }
                Text(text)
                    .panelFont(.footnote)
                    .foregroundStyle(DS.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
