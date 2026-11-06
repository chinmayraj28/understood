//
//  ConversationThreadView.swift
//  Handsfree
//
//  The conversation as a message thread: what the person said on the right
//  in iris, what Handsfree said on the left in grey. Side and colour are
//  backed by a name ("You", "Handsfree") over the first line of each turn,
//  and VoiceOver reads "You said: …" or "Handsfree said: …". New for Handsfree.
//

import SwiftUI

struct ConversationThreadView: View {
    let messages: [PanelSnapshot.Message]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let startsTurn = index == 0 || messages[index - 1].isFromUser != message.isFromUser
                MessageBubble(message: message, showsName: startsTurn)
                    .padding(.top, startsTurn && index > 0 ? 6 : 0)
                    .id(message.id)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct MessageBubble: View {
    let message: PanelSnapshot.Message
    let showsName: Bool

    var body: some View {
        HStack(spacing: 0) {
            if message.isFromUser { Spacer(minLength: 44) }
            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 3) {
                if showsName {
                    Text(message.isFromUser ? PanelCopy.you : PanelCopy.appName)
                        .panelFont(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(DS.Panel.textTertiary)
                        .padding(.horizontal, 4)
                }
                Text(message.text)
                    .panelFont(.body)
                    .foregroundStyle(message.isFromUser ? AnyShapeStyle(Color.white) : AnyShapeStyle(DS.Panel.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Panel.bubbleCornerRadius, style: .continuous)
                            .fill(message.isFromUser ? AnyShapeStyle(DS.Panel.accentFill) : AnyShapeStyle(DS.Panel.assistantBubble)))
            }
            if !message.isFromUser { Spacer(minLength: 44) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PanelCopy.saidBy(isFromUser: message.isFromUser)): \(message.text)")
    }
}
