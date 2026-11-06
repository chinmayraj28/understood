//
//  TaskCardView.swift
//  Handsfree
//
//  The task: its goal, its state as an icon and a word, and its steps as a
//  short timeline (done steps ticked, the current one marked), with how it
//  ended once it has. While it runs, this card is also the status: a small
//  moving dot and "Working" in its header. New for Handsfree.
//

import SwiftUI

struct TaskCardView: View {
    let task: PanelSnapshot.TaskCard
    /// Shown in the ready layout, after the task has ended: smaller, with no steps.
    let isLastTask: Bool

    /// How many of the newest steps are listed; earlier ones are counted.
    static let standardVisibleSteps = 5
    var visibleSteps = standardVisibleSteps
    /// False when the card above already says how the task ended.
    var showsResult = true

    /// Running right now: this card is then the status as well, so there is no separate "Working" card.
    private var isLive: Bool { task.isCurrent && task.status == .running }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    PanelSectionHeader(title: isLastTask ? PanelCopy.lastTaskTitle : PanelCopy.taskTitle).padding(.horizontal, -4)
                    if isLive {
                        liveIndicator
                    } else if !task.isCurrent && showsResult {
                        // Once ended, say how. (While it waits, the amber card above says so.)
                        PanelStatusTag(symbol: statusSymbol, text: PanelCopy.taskStatus(task.status), tone: statusTone)
                    }
                }
                Text(task.goal)
                    .panelFont(task.isCurrent ? .title : .headline)
                    .foregroundStyle(DS.Panel.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !isLastTask && !task.steps.isEmpty {
                    steps
                }

                if showsResult, let summary = task.summary, !summary.isEmpty {
                    // A last task that went well needs no highlight; anything else is called out.
                    if isLastTask && task.status == .done {
                        Text(summary)
                            .panelFont(.callout)
                            .foregroundStyle(DS.Panel.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        resultLine(summary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var steps: some View {
        let shown = Array(task.steps.suffix(visibleSteps))
        let hidden = task.steps.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            if hidden > 0 {
                Text(PanelCopy.earlierSteps(hidden))
                    .panelFont(.footnote)
                    .foregroundStyle(DS.Panel.textTertiary)
                    .padding(.leading, 22)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                let isCurrent = index == shown.count - 1 && task.isCurrent
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(isCurrent: isCurrent)
                        .frame(width: 14)
                    Text(step)
                        .panelFont(isCurrent ? .headline : .callout)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(DS.Panel.textPrimary) : AnyShapeStyle(DS.Panel.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isCurrent ? "\(PanelCopy.currentStepLabel): \(step)" : step)
            }
            Text(PanelCopy.stepsDone(doneCount))
                .panelFont(.footnote)
                .foregroundStyle(DS.Panel.textTertiary)
                .padding(.leading, 22)
                .padding(.top, 2)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func marker(isCurrent: Bool) -> some View {
        if isCurrent && task.status == .running {
            // Still: the card header already moves.
            Circle().fill(DS.Panel.accent).frame(width: 7, height: 7)
        } else if isCurrent {
            Image(systemName: "pause.circle.fill")
                .panelSymbol(11, .semibold)
                .foregroundStyle(DS.Panel.hold)
        } else {
            Image(systemName: "checkmark")
                .panelSymbol(9, .bold)
                .foregroundStyle(DS.Panel.textTertiary)
        }
    }

    /// A small moving dot and "Working", in the card header.
    private var liveIndicator: some View {
        HStack(spacing: 6) {
            PanelPulsingDot(tone: .accent, diameter: 7)
            Text(PanelCopy.taskStatus(.running))
                .panelFont(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(DS.Panel.accent)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// Steps finished: all of them once the task has ended, all but the current one while it runs.
    private var doneCount: Int {
        task.isCurrent ? max(0, task.steps.count - 1) : task.steps.count
    }

    private func resultLine(_ summary: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol)
                .panelSymbol(12, .semibold)
                .foregroundStyle(statusTone.foreground)
                .accessibilityHidden(true)
            Text(summary)
                .panelFont(.callout)
                .foregroundStyle(DS.Panel.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Panel.controlCornerRadius, style: .continuous).fill(statusTone.tint))
    }

    private var statusSymbol: String {
        switch task.status {
        case .running: return "cursorarrow.motionlines"
        case .waitingForAnswer: return "questionmark.bubble.fill"
        case .waitingForYes: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    private var statusTone: PanelTone {
        switch task.status {
        case .running: return .accent
        case .waitingForAnswer, .waitingForYes: return .hold
        case .done: return .success
        case .failed: return .stop
        case .stopped: return .neutral
        }
    }
}
