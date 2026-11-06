//
//  PanelView.swift
//  Handsfree
//
//  The panel under the menu bar icon. It is for the person helping: setup,
//  a glance at what is happening, the transcript, the task, what has been
//  learned, and Quit. Nothing in it is needed to use the product.
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): CompanionPanelView.swift.
//  Kept: the layout (header with a glowing status dot, name and status text,
//  close button; sections separated by hairlines; a footer with Quit), the
//  permission row pattern (icon, name, granted dot or an action button), the
//  dark rounded background with a two-layer shadow. Removed: push-to-talk
//  copy, the email form, the model picker, the onboarding video and the
//  "DM Farza" button. New: setup items with carer wording, the live
//  transcript, the task with its steps, the memory summary and the parts list.
//

import HFCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var companion: CompanionModel
    let onSetupAction: (SetupItem.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hairline

            if !app.setupItems.isEmpty && !app.isDemo {
                section("SETUP") { setupList }
                hairline
            }

            if !app.isDemo {
                section("LISTENING") { listeningSection }
                hairline
            }

            section("TO START") {
                Text(SetupCheck.howToStart(wakePhrase: app.wakePhrase, sleepAfterSeconds: app.sleepAfterIdleSeconds, alwaysOpen: app.isAlwaysOpen))
                    .font(.system(size: 12))
                    .foregroundColor(app.isAlwaysOpen ? DS.Colors.holdText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            hairline

            section(taskSectionTitle) { taskSection }
            hairline

            section("CONVERSATION") { transcript }
            hairline

            section("WHAT IT HAS LEARNED") {
                Text(app.memorySummary.isEmpty ? "Nothing yet. It learns names and preferences as you use it." : app.memorySummary)
                    .font(.system(size: 12))
                    .foregroundColor(app.memorySummary.isEmpty ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            hairline

            partsSection
            hairline
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                .fill(DS.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(0.7), radius: 4)
            Text("Handsfree")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
            if app.isDemo {
                Text("DEMO")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(DS.Colors.accentSubtle))
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(statusColor == DS.Colors.muted ? DS.Colors.textTertiary : statusColor)
            Button {
                NotificationCenter.default.post(name: .handsfreeDismissPanel, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        if !app.isReady && !app.isDemo { return "Setup needed" }
        switch companion.state.glyph {
        case .holding: return "Waiting for a yes"
        case .asking: return "Asked a question"
        case .stopped: return "Stopped"
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .userSpeaking: return "Hearing you"
        case .agentSpeaking: return "Speaking"
        case .thinking, .moving, .clicking, .typing, .scrolling: return "Working"
        case .done: return "Done"
        case .failed: return "Couldn\u{2019}t finish"
        case .cancelled: return "Cancelled"
        case .listening: return "Listening"
        case .asleep: return "Asleep"
        case .waking: return "Waking"
        }
    }

    private var statusColor: Color {
        if !app.isReady && !app.isDemo { return DS.Colors.hold }
        switch companion.state.glyph {
        case .holding, .asking: return DS.Colors.hold
        case .stopped, .failed: return DS.Colors.stop
        case .disconnected, .connecting, .cancelled, .asleep: return DS.Colors.muted
        case .done: return DS.Colors.success
        default: return DS.Colors.accent
        }
    }

    // MARK: - Setup

    private var setupList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if app.setupItems.contains(where: \.isBlocking) {
                Text("These steps need someone at the Mac. The person using Handsfree cannot do them by voice.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(app.setupItems) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(item.isBlocking ? DS.Colors.hold : DS.Colors.textTertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                            if let action = item.action, let title = item.actionTitle {
                                Button(title) { onSetupAction(action) }
                                    .buttonStyle(DSPrimaryButtonStyle())
                            }
                        }
                        Text(item.instructions)
                            .font(.system(size: 11.5))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(SetupCheck.whereToFindIt)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// For whoever is checking why it does not respond: which permissions it has, whether the
    /// wake listener runs, whether a conversation is open, and what it has heard (counts only).
    private var listeningSection: some View {
        let status = app.listening
        return VStack(alignment: .leading, spacing: 6) {
            permissionSummary
            ForEach([status.listenerLine, status.languageLine, status.conversationLine, status.heardLine(now: Date())].filter { !$0.isEmpty }, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Clicky's permission rows, condensed: one line per permission with a granted dot.
    private var permissionSummary: some View {
        HStack(spacing: 14) {
            permissionDot("Microphone", app.setupFacts.microphone)
            if app.setupFacts.needsSpeechRecognition {
                permissionDot("Speech", app.setupFacts.speechRecognition)
            }
            permissionDot("Accessibility", app.setupFacts.accessibility)
            permissionDot("Screen", app.setupFacts.screenRecording)
        }
        .padding(.top, 2)
    }

    private func permissionDot(_ name: String, _ status: PermissionStatus) -> some View {
        HStack(spacing: 5) {
            Circle().fill(status == .granted ? DS.Colors.success : DS.Colors.hold).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(status == .granted ? DS.Colors.success : DS.Colors.textTertiary)
        }
    }

    // MARK: - Task

    private var taskSectionTitle: String {
        companion.log.currentTask == nil ? "LAST TASK" : "NOW"
    }

    @ViewBuilder private var taskSection: some View {
        if let task = companion.log.currentTask ?? companion.log.recentTasks.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.goal)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(label(for: task.status))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(color(for: task.status))
                }
                if let waitingOn = task.waitingOn {
                    Text(waitingOn)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.holdText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(task.steps.suffix(5).enumerated()), id: \.offset) { index, step in
                    let isLatest = index == task.steps.suffix(5).count - 1 && task.status == .running
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: isLatest ? "circle.fill" : "checkmark")
                            .font(.system(size: isLatest ? 6 : 9, weight: .bold))
                            .foregroundColor(isLatest ? DS.Colors.accent : DS.Colors.textTertiary)
                            .frame(width: 10)
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundColor(isLatest ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    }
                }
                if let summary = task.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
        } else {
            Text("No task yet. Ask for something like \u{201C}message Amma that I\u{2019}m running late\u{201D}.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(for status: TaskStatus) -> String {
        switch status {
        case .running: return "WORKING"
        case .needsInput: return "WAITING"
        case .done: return "DONE"
        case .failed: return "FAILED"
        case .cancelled: return "STOPPED"
        }
    }

    private func color(for status: TaskStatus) -> Color {
        switch status {
        case .running: return DS.Colors.accentText
        case .needsInput: return DS.Colors.hold
        case .done: return DS.Colors.success
        case .failed: return DS.Colors.stopText
        case .cancelled: return DS.Colors.muted
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        let lines = companion.log.transcript.suffix(8)
        if lines.isEmpty {
            Text(companion.log.voiceProblem ?? (companion.state.glyph == .asleep
                ? "Asleep. Nothing is heard until someone says \u{201C}\(companion.state.wakePhrase)\u{201D}."
                : "Nothing said yet."))
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.speaker == .user ? "You" : "Handsfree")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(line.speaker == .user ? DS.Colors.textTertiary : DS.Colors.accentText)
                            .frame(width: 64, alignment: .leading)
                        Text(line.text)
                            .font(.system(size: 12))
                            .foregroundColor(line.speaker == .user ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if let problem = companion.log.voiceProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.holdText)
                }
            }
        }
    }

    // MARK: - Parts and footer

    private var partsSection: some View {
        let realCount = app.wiring.filter(\.isReal).count
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(app.wiring) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(part.isReal ? DS.Colors.success : DS.Colors.muted).frame(width: 6, height: 6)
                        Text(part.part).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                        Text(part.isReal ? part.package : "stand-in").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("PARTS  \(realCount) of \(app.wiring.count) real")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text("Quit Handsfree")
                }
            }
            .buttonStyle(DSTextButtonStyle())
            Spacer()
            // No "Play demo" here: the demo is a tool for reviewing and recording, started from the
            // command line only (scripts/run_app.sh --demo), and must never start a second copy.
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var hairline: some View {
        Rectangle().fill(DS.Colors.borderSubtle.opacity(0.7)).frame(height: 1).padding(.horizontal, 16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
