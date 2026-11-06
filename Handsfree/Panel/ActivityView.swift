//
//  ActivityView.swift
//  Handsfree
//
//  The panel while Handsfree is awake or working: what it is doing right now
//  at a glance, the question in large amber type when it is waiting for a
//  yes or an answer, the task with its steps, and the conversation.
//  New for Handsfree.
//

import SwiftUI

struct ActivityView: View {
    let snapshot: PanelSnapshot
    let sleepAfterSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Panel.blockSpacing) {
            if snapshot.isAwaitingAnswer {
                PanelPromptCard(
                    isConfirmation: snapshot.activity == .waitingForYes || snapshot.task?.status == .waitingForYes,
                    question: snapshot.task?.question,
                    heldAction: snapshot.task?.heldAction)
            } else {
                PanelStatusCard(activity: snapshot.activity, subtitle: subtitle)
            }

            if let task = snapshot.task {
                // While a yes is awaited the question matters most, so only the newest steps are listed.
                TaskCardView(
                    task: task, isLastTask: false,
                    visibleSteps: snapshot.isAwaitingAnswer ? 2 : TaskCardView.standardVisibleSteps,
                    showsResult: !showsResultAbove)
            }

            PanelConversationSection(messages: snapshot.transcript)
        }
    }

    /// Just after a task ends, the status card says how it ended, so the task card need not.
    private var showsResultAbove: Bool {
        snapshot.task?.summary != nil && [.done, .failed, .stopped].contains(snapshot.activity)
    }

    /// While working, the newest step says more than a general line does.
    private var subtitle: String {
        if snapshot.activity == .working, let step = snapshot.task?.steps.last { return step }
        if showsResultAbove, let summary = snapshot.task?.summary { return summary }
        return PanelCopy.activitySubtitle(snapshot.activity, sleepAfterSeconds: sleepAfterSeconds, isAlwaysOpen: snapshot.isAlwaysOpen)
    }
}

/// What it is doing now: a large icon, a title and one line.
private struct PanelStatusCard: View {
    let activity: PanelSnapshot.Activity
    let subtitle: String

    var body: some View {
        PanelCard {
            HStack(spacing: 12) {
                PanelIconTile(symbol: activity.symbol, tone: activity.tone, size: 40)
                    .overlay(alignment: .topTrailing) {
                        // A small live dot while something is happening now.
                        if activity.isLive {
                            PanelPulsingDot(tone: activity.tone, diameter: 8)
                                .padding(2)
                                .background(Circle().fill(DS.Panel.card))
                                .offset(x: 4, y: -4)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(PanelCopy.activityTitle(activity))
                        .panelFont(.title)
                        .foregroundStyle(activity.tone == .neutral ? AnyShapeStyle(DS.Panel.textPrimary) : activity.tone.foreground)
                    Text(subtitle)
                        .panelFont(.callout)
                        .foregroundStyle(DS.Panel.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A question, or an action held for a yes: amber, with the question in large type.
private struct PanelPromptCard: View {
    let isConfirmation: Bool
    let question: String?
    let heldAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(isConfirmation ? PanelCopy.waitingForYesEyebrow : PanelCopy.questionEyebrow)
                    .panelFont(.eyebrow)
            } icon: {
                Image(systemName: isConfirmation ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .panelSymbol(11, .bold)
            }
            .foregroundStyle(DS.Panel.hold)

            if let question {
                Text(question)
                    .panelFont(.hero)
                    .foregroundStyle(DS.Panel.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let heldAction {
                Text(PanelCopy.heldAction(heldAction))
                    .panelFont(.callout)
                    .foregroundStyle(DS.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .panelSymbol(11, .semibold)
                    .accessibilityHidden(true)
                Text(isConfirmation ? PanelCopy.yesHint : PanelCopy.answerHint)
                    .panelFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DS.Panel.hold)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous).fill(DS.Panel.holdTint))
        .overlay(RoundedRectangle(cornerRadius: DS.Panel.cardCornerRadius, style: .continuous).strokeBorder(DS.Panel.holdEdge, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The conversation, newest at the bottom, scrolling once it is long.
private struct PanelConversationSection: View {
    let messages: [PanelSnapshot.Message]
    @Environment(\.panelTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader(title: PanelCopy.conversationTitle)
            if messages.isEmpty {
                PanelCard {
                    Text(PanelCopy.emptyConversation)
                        .panelFont(.callout)
                        .foregroundStyle(DS.Panel.textSecondary)
                }
            } else {
                CappedScrollArea(maxHeight: DS.Panel.threadMaxHeight * scale, keepsBottomInView: true, bottomID: messages.last?.id) {
                    ConversationThreadView(messages: messages)
                }
            }
        }
    }
}
