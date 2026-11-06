//
//  SessionLog.swift
//  Handsfree
//
//  What the menu bar panel shows about this session: the live transcript of
//  what was heard and said, the current task with its progress, and the last
//  few tasks. Built from the same ActivityBus events as the companion. Pure
//  value type, unit tested. New for Handsfree.
//

import Foundation
import HFCore

struct SessionLog: Equatable {
    enum Speaker: Equatable {
        case user
        case assistant
    }

    struct TranscriptLine: Equatable, Identifiable {
        let id: Int
        let speaker: Speaker
        let text: String
        let time: Date
    }

    struct TaskRecord: Equatable {
        var goal: String
        var status: TaskStatus
        /// Progress lines in order, newest last.
        var steps: [String]
        var startedAt: Date
        var endedAt: Date?
        var summary: String?
        /// The question or held action the task is waiting on, if any.
        var waitingOn: String?
    }

    static let maximumTranscriptLines = 40
    static let maximumStepsPerTask = 30
    static let maximumRecentTasks = 5

    private(set) var transcript: [TranscriptLine] = []
    private(set) var currentTask: TaskRecord?
    private(set) var recentTasks: [TaskRecord] = []
    /// Why the voice connection dropped, while it is down.
    private(set) var voiceProblem: String?
    private var nextLineID = 0

    mutating func record(_ event: ActivityEvent, at time: Date) {
        switch event {
        case .userSaid(let text):
            appendLine(.user, text, time)
        case .agentSpeaking(let text):
            // The voice package may post a sentence more than once as it streams; keep one.
            if transcript.last?.speaker == .assistant && transcript.last?.text == text { return }
            appendLine(.assistant, text, time)
        case .listening:
            voiceProblem = nil
        case .voiceDisconnected(let reason):
            voiceProblem = reason
        case .taskStarted(let goal):
            if let unfinished = currentTask { finish(unfinished) }
            currentTask = TaskRecord(goal: goal, status: .running, steps: [], startedAt: time)
        case .progress(let text), .thinking(let text):
            appendStep(text)
            currentTask?.waitingOn = nil
            if currentTask?.status == .needsInput { currentTask?.status = .running }
        case .waitingForAnswer(let question):
            currentTask?.status = .needsInput
            currentTask?.waitingOn = question
        case .heldForConfirmation(let action):
            currentTask?.status = .needsInput
            currentTask?.waitingOn = "Waiting for a yes before: \(action)"
        case .taskEnded(let status, let summary):
            guard var task = currentTask else { return }
            task.status = status
            task.summary = summary
            task.endedAt = time
            task.waitingOn = nil
            finish(task)
            currentTask = nil
        case .userSpeaking, .pointerMoving, .clicked, .typing, .scrolled, .halted:
            break
        }
    }

    private mutating func appendLine(_ speaker: Speaker, _ text: String, _ time: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(TranscriptLine(id: nextLineID, speaker: speaker, text: trimmed, time: time))
        nextLineID += 1
        if transcript.count > Self.maximumTranscriptLines {
            transcript.removeFirst(transcript.count - Self.maximumTranscriptLines)
        }
    }

    private mutating func appendStep(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var task = currentTask else { return }
        if task.steps.last == trimmed { return }
        task.steps.append(trimmed)
        if task.steps.count > Self.maximumStepsPerTask { task.steps.removeFirst() }
        currentTask = task
    }

    private mutating func finish(_ task: TaskRecord) {
        recentTasks.insert(task, at: 0)
        if recentTasks.count > Self.maximumRecentTasks { recentTasks.removeLast() }
    }
}
