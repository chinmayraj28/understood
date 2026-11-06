import CoreGraphics
import Foundation
import HFCore
import os

/// Anything that can send a Messages API request. `ClaudeClient` is the real one.
public protocol MessagesCreating: Sendable {
    func createMessage(_ body: JSONValue) async throws -> JSONValue
}

extension ClaudeClient: MessagesCreating {}

/// Timings of the last run, for the timing experiments and the logs.
public struct ScreenAgentRunStats: Sendable, Equatable {
    /// Seconds each model call took, in order.
    public var modelSeconds: [Double] = []
    /// Seconds spent acting (pointer, keys, screenshots, safety checks) after each model call.
    public var actingSeconds: [Double] = []
    /// Computer actions carried out (not counting screenshots).
    public var actionsPerformed = 0
    public var inputTokens = 0
    public var cachedInputTokens = 0
    public var outputTokens = 0
    /// Where acting time went, in seconds over the whole run:
    /// "lookup" (naming the target), "confirm" (the gate, and the person if asked),
    /// "hands", "screenshot", "settle", "wait".
    public var actingBreakdown: [String: Double] = [:]
    /// Times a hold reached its bound and the agent carried on while the user still seemed to speak.
    public var holdBoundHits = 0
}

/// The screen agent: carries out a spoken goal the way a person at the Mac would.
///
/// One turn of the loop:
/// 1. LOOK: the model has the latest screenshot.
/// 2. DECIDE: Claude, with the computer-use toolset, answers with one or more
///    actions ("cmd+space", type "TextEdit", "Return", screenshot).
/// 3. CHECK: before each click, drag, Return or dangerous shortcut, the safety
///    backstop names the real target from the accessibility tree and asks
///    `context.confirm`. A no means the action is skipped and Claude is told.
/// 4. ACT: the real pointer and keyboard do it, visibly.
/// Then a fresh screenshot goes back to Claude, and the loop repeats until
/// Claude calls `task_finished`.
public final class ScreenAgent: TaskExecuting, @unchecked Sendable {
    private let hands: Hands
    private let eyes: Eyes
    private let labels: Labels
    private let client: MessagesCreating
    /// True while the user is speaking. New actions wait while it is true (bounded by
    /// `configuration.maxHoldSeconds`), so a spoken "stop" lands before the next click.
    fileprivate let holdWhile: @Sendable () -> Bool
    /// Where "thinking" and "listening" are posted for the companion. The app passes its bus; tests pass their own.
    fileprivate let activity: ActivityBus
    public let configuration: ScreenAgentConfiguration
    private let logger = Logger(subsystem: "com.handsfree", category: "HFScreenAgent")
    private let statsLock = NSLock()
    private var stats = ScreenAgentRunStats()

    /// - Parameter holdWhile: the app passes "the user is speaking right now" from the
    ///   voice session. While it returns true no new action starts. Defaults to never.
    public init(
        hands: Hands, eyes: Eyes, labels: Labels, client: MessagesCreating, configuration: ScreenAgentConfiguration,
        holdWhile: @escaping @Sendable () -> Bool = { false },
        activity: ActivityBus = .shared
    ) {
        self.holdWhile = holdWhile
        self.activity = activity
        self.hands = hands
        self.eyes = eyes
        self.labels = labels
        self.client = client
        self.configuration = configuration
    }

    /// Timings and token counts of the most recent run.
    public var lastRunStats: ScreenAgentRunStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    public func run(goal: String, context: TaskContext) async throws -> String {
        record { $0 = ScreenAgentRunStats() }
        // When the task is cancelled, freeze the pointer and keyboard at once, even
        // mid-glide or mid-word. The pending model request is cancelled by URLSession.
        // The hands stay halted: only the task runner releases them after a stop
        // (docs/ARCHITECTURE.md), so a stop cannot be undone by this task unwinding.
        return try await withTaskCancellationHandler {
            let session = AgentSession(agent: self, goal: goal, context: context)
            do {
                return try await session.run()
            } catch let error as StepLimitReached {
                throw error  // the runner words the "how far I got" summary from its progress log
            } catch is CancellationError {
                throw CancellationError()
            } catch is Halted {
                if Task.isCancelled { throw CancellationError() }
                throw SpeakableError("I stopped because the pointer and keyboard were halted.")
            } catch let error as SpeakableError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                logger.error("screen agent failed: \(String(describing: error), privacy: .private)")
                throw SpeakableError("Something went wrong while I was working, so I stopped.")
            }
        } onCancel: {
            hands.halt()
        }
    }

    fileprivate func record(_ update: (inout ScreenAgentRunStats) -> Void) {
        statsLock.lock()
        update(&stats)
        statsLock.unlock()
    }

    fileprivate var parts: (Hands, Eyes, Labels, MessagesCreating) { (hands, eyes, labels, client) }
}

/// The state of one run: the conversation so far and the latest screenshot.
/// Kept apart from `ScreenAgent` so the agent itself holds no per-task state.
private final class AgentSession {
    private let agent: ScreenAgent
    private let goal: String
    private let context: TaskContext
    private let hands: Hands
    private let eyes: Eyes
    private let labels: Labels
    private let client: MessagesCreating
    private let configuration: ScreenAgentConfiguration
    private let backstop: SafetyBackstop
    /// Keeps keys and clicks in windows the agent meant to use (see WindowGuard).
    private let windows = WindowGuard()
    /// What the last check found under the pointer, so the window guard knows what a click brought forward.
    private var lastCheckedTarget: UIElementInfo?
    private let logger = Logger(subsystem: "com.handsfree", category: "HFScreenAgent")

    private var messages: [JSONValue] = []
    /// The latest full screenshot. Every coordinate the model gives is in its pixels.
    private var latestShot: Shot?
    private var lastProgress = ""
    /// Replies that ended without a tool call. The second one ends the task as failed.
    private var unfinishedReplies = 0
    /// True after an action, until the next screenshot: that screenshot waits to settle.
    private var actedSinceScreenshot = false
    /// True once an action in this turn has run: the next one waits `settleSeconds` first.
    /// Measured: cmd+space, a typed name and Return sent back to back made Spotlight open
    /// Calculator, because Return arrived before Spotlight had updated its top hit.
    private var actedThisTurn = false
    /// True after a hold reached its bound while the signal still said "speaking".
    private var signalStuck = false

    init(agent: ScreenAgent, goal: String, context: TaskContext) {
        self.agent = agent
        self.goal = goal
        self.context = context
        (hands, eyes, labels, client) = agent.parts
        configuration = agent.configuration
        backstop = SafetyBackstop(labels: labels)
    }

    func run() async throws -> String {
        context.report("Looking at the screen")
        let firstShot = try await takeScreenshot()
        messages.append(["role": "user", "content": [.object(["type": "text", "text": .string(openingText())]), imageBlock(firstShot)]])

        while true {
            try context.step()
            try Task.checkCancellation()
            agent.activity.post(.thinking(caption: lastProgress.isEmpty ? "Deciding what to do" : lastProgress))

            let started = Date()
            let response = try await client.createMessage(requestBody())
            let modelSeconds = Date().timeIntervalSince(started)
            recordUsage(response, seconds: modelSeconds)

            if response["stop_reason"]?.stringValue == "refusal" {
                throw SpeakableError("Claude declined to help with that, so I stopped.")
            }
            let content = response["content"]?.arrayValue ?? []
            messages.append(["role": "assistant", "content": .array(content)])  // passed back unchanged

            let calls = content.compactMap(ToolCallParser.parse)
            if calls.isEmpty {
                // A task only succeeds through task_finished. A reply without a tool call
                // ("I couldn't find Priya.") is not success: nudge once, then fail with its words.
                let stopReason = response["stop_reason"]?.stringValue ?? ""
                if stopReason == "pause_turn" { continue }  // unfinished: send it back to carry on
                unfinishedReplies += 1
                let text = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                    .joined(separator: " ")
                if unfinishedReplies >= 2 {
                    let said = Speech.firstSentence(text)
                    throw SpeakableError(said.isEmpty ? "I stopped without finishing the task." : said)
                }
                let nudge = stopReason == "max_tokens"
                    ? "Your reply was cut off. Continue with fewer, shorter actions."
                    : "You replied without using a tool. If the goal is done or cannot be done, call task_finished with success true or false. If you need the person, call ask_user. Otherwise carry on with the next action."
                messages.append(["role": "user", "content": [["type": "text", "text": .string(nudge)]]])
                continue
            }

            let actingStarted = Date()
            let outcome = try await perform(calls)
            agent.record { $0.actingSeconds.append(Date().timeIntervalSince(actingStarted)) }

            if let finish = outcome.finish {
                let summary = Speech.firstSentence(finish.summary)
                if finish.success { return summary.isEmpty ? "Done." : summary }
                throw SpeakableError(summary.isEmpty ? "I couldn't finish that." : summary)
            }
            messages.append(["role": "user", "content": .array(outcome.results)])
            pruneOldScreenshots()
        }
    }

    // MARK: - One turn's actions

    private struct TurnOutcome {
        var results: [JSONValue] = []
        var finish: (success: Bool, summary: String)?
    }

    /// Carries out a turn's tool calls in order. Stops at the first refusal or
    /// failure, as the toolset documentation asks, and answers every later call
    /// with "not executed". Attaches a fresh screenshot to the last result when
    /// the screen may have changed and the model did not ask for one itself.
    private func perform(_ calls: [ToolCall]) async throws -> TurnOutcome {
        var outcome = TurnOutcome()
        actedThisTurn = false
        var stopped = false
        var screenMayHaveChanged = false
        var lastWasScreenshot = false

        for call in calls {
            if stopped || outcome.finish != nil {
                outcome.results.append(result(for: call, text: "Not executed: an earlier computer action in this turn failed.", isError: true))
                continue
            }
            switch call.request {
            case .finished(let success, let summary):
                outcome.finish = (success, summary)
                outcome.results.append(result(for: call, text: "OK"))

            case .prepareSend(let recipient, let expected):
                if let wrong = backstop.prepareSend(headerName: recipient, expectedName: expected) {
                    // Wrong chat: no confirmation is asked, the send that follows is not run.
                    let text = "Wrong chat: \(wrong). Do not send here. Open the chat of \(expected) first, or ask the person with ask_user."
                    outcome.results.append(result(for: call, text: text, isError: true))
                    stopped = true
                } else {
                    outcome.results.append(result(for: call, text: "OK"))
                }

            case .reportProgress(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != lastProgress {
                    lastProgress = trimmed
                    context.report(trimmed)
                }
                outcome.results.append(result(for: call, text: "OK"))

            case .askUser(let question, let options):
                let answer = try await context.askUser(question, options: options)
                outcome.results.append(result(for: call, text: "The person answered: \(answer)"))

            case .unknown(_, let reason):
                outcome.results.append(result(for: call, text: reason, isError: true))
                stopped = call.isComputer

            case .computer(let action):
                let (block, acted, failed) = try await performComputer(action, call: call)
                outcome.results.append(block)
                if acted { screenMayHaveChanged = true }
                lastWasScreenshot = action == .screenshot
                if failed { stopped = true }
            }
        }

        if screenMayHaveChanged && !lastWasScreenshot && outcome.finish == nil, let lastIndex = outcome.results.indices.last {
            let shot = try await takeScreenshot()
            if outcome.results[lastIndex]["is_error"]?.boolValue == true {
                // The API only allows text in an error result, so the screen goes after the results.
                outcome.results.append(["type": "text", "text": "The screen now:"])
                outcome.results.append(imageBlock(shot))
            } else {
                outcome.results[lastIndex] = appendImage(shot, to: outcome.results[lastIndex])
            }
        }
        return outcome
    }

    /// One computer action: map pixels to screen points, check it, do it.
    /// Returns the tool_result block, whether the screen may have changed, and
    /// whether the rest of the batch must be skipped.
    private func performComputer(_ action: ComputerAction, call: ToolCall) async throws -> (JSONValue, Bool, Bool) {
        switch action {
        case .screenshot:
            let shot = try await takeScreenshot()
            return (result(for: call, content: [imageBlock(shot)]), false, false)

        case .zoom(let region):
            guard let base = latestShot else { return (result(for: call, text: "Take a screenshot first.", isError: true), false, true) }
            let topLeft = base.screenPoint(imageX: region.minX, imageY: region.minY)
            let bottomRight = base.screenPoint(imageX: region.maxX, imageY: region.maxY)
            let screenRegion = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            let zoomed = try await grab { try await self.eyes.grab(region: screenRegion, maxLongEdge: self.configuration.screenshotLongEdge) }
            return (result(for: call, content: [imageBlock(zoomed)]), false, false)

        case .cursorPosition:
            let point = latestShot?.imagePoint(screenPoint: hands.pointerPosition) ?? hands.pointerPosition
            return (result(for: call, text: "X=\(Int(point.x.rounded())), Y=\(Int(point.y.rounded()))"), false, false)

        default:
            break
        }

        guard let shot = latestShot else { return (result(for: call, text: "Take a screenshot first.", isError: true), false, true) }
        let screenAction = mapToScreen(action, shot: shot)

        try await holdWhileUserSpeaks()  // do not start moving while the person is talking
        try await stopIfProtected(screenAction)

        // Glide to a click or drag's starting point FIRST, then name what is there:
        // a spot can change as the pointer arrives (WhatsApp's voice-message button
        // becomes Send once text is typed). The press itself then needs no glide.
        let glideStarted = Date()
        switch screenAction {
        case .click(_, _, let point?, _): try await perform { try await self.hands.move(to: point, duration: nil) }
        case .drag(let start, _): try await perform { try await self.hands.move(to: start, duration: nil) }
        default: break
        }
        add("hands", since: glideStarted)
        if case .click = screenAction { try await stopIfProtected(screenAction) }  // what is there now the pointer has arrived
        if case .drag = screenAction { try await stopIfProtected(screenAction) }

        // Typing must land in a real text box. Measured in WhatsApp: clicking the search
        // box sometimes left focus in the message box, and the name was typed there.
        if case .type = screenAction {
            let focused = await focusedTextEntry()
            try await stopIfProtected(screenAction)  // a password field is a protected surface: never typed into
            if let refusal = try await focusRefusal(focused) { return (result(for: call, text: refusal, isError: true), true, true) }
            guard let focused, focused.role.isTextEntry else {
                let front = await labels.frontmost()
                let place = ScreenAction.phrase(for: focused, frontApp: front.app)
                let text = "Not typed: keyboard focus is on \(place), not a text box. Click the box you mean first, check it has focus, then type."
                return (result(for: call, text: text, isError: true), false, true)
            }
        }

        // A repeated key is checked and pressed one press at a time: three Returns are three checks.
        if case .key(let combo, let repeatCount) = screenAction {
            for _ in 0..<repeatCount {
                try await stopIfProtected(.key(combo: combo, repeatCount: 1))
                // Focus is read at the moment of each press: an updater can take the front at any time.
                if let refusal = try await focusRefusal(await labels.focusedElement()) {
                    return (result(for: call, text: refusal, isError: true), true, true)
                }
                if let refusal = try await gate(screenAction) { return (result(for: call, text: refusal, isError: true), false, true) }
                try await timedAct(.key(combo: combo, repeatCount: 1))
                windows.didAct(.key(combo: combo, repeatCount: 1), target: nil)
            }
            return (result(for: call, text: "OK"), true, false)
        }

        lastCheckedTarget = nil
        if let refusal = try await gate(screenAction) { return (result(for: call, text: refusal, isError: true), false, true) }
        try await timedAct(screenAction)
        windows.didAct(screenAction, target: lastCheckedTarget)
        if case .type(let text) = screenAction { await backstop.recordTyped(text) }
        return (result(for: call, text: "OK"), true, false)
    }

    /// The one rule for password prompts, installers and updaters (HFCore'"'"'s ProtectedSurfaces):
    /// before every action of any kind, build it through the labels and, if it would land on
    /// such a window or a password field, stop the task. The user is not asked to confirm:
    /// a yes would still have the agent agreeing to an install or typing into a password prompt.
    private func stopIfProtected(_ action: ComputerAction) async throws {
        let probe: ScreenAction?
        switch action {
        case .click(_, _, let point, _): probe = await labels.clickAction(at: point ?? hands.pointerPosition)
        case .drag(let start, _): probe = await labels.clickAction(at: start, kind: .drag)
        case .move(let point): probe = await labels.clickAction(at: point)
        case .scroll(_, _, let point): probe = await labels.clickAction(at: point ?? hands.pointerPosition)
        case .key(let combo, _): probe = await labels.keyAction(KeyChord(combo) ?? KeyChord(key: combo))
        case .type(let text):
            // Typing lands where focus is, like a key press; a newline is a line break.
            probe = text.contains(where: \.isNewline) ? await labels.lineBreakAction() : await labels.keyAction(KeyChord(key: "typing"))
        default: probe = nil
        }
        guard let probe, probe.landsOnProtectedSurface else { return }
        logger.notice("stopping: the action would land on a protected window (\(probe.app, privacy: .public))")
        throw SpeakableError(ProtectedSurfaces.spokenRefusal)
    }

    /// Why a key press or typing must not go to where focus is now, or nil when it may.
    /// Throws for a system password prompt, installer or updater: the task stops.
    private func focusRefusal(_ focused: UIElementInfo?) async throws -> String? {
        let front = await labels.frontmost()
        let app = (focused?.app.isEmpty == false ? focused?.app : nil) ?? front.app
        let bundle = focused?.appBundleIdentifier.isEmpty == false ? focused!.appBundleIdentifier : await labels.frontmostBundleIdentifier()
        try stopIfProtected(app: app, bundleIdentifier: bundle)
        if WindowGuard.isOwnApp(app) {
            return "Not done: I can't tell what has keyboard focus, because my own overlay answered instead. Take a screenshot and try again in a moment."
        }
        if let awaited = windows.awaitedApp, app != awaited {
            return "Not typed: \(awaited) has not taken keyboard focus yet, so the keys would have gone to \(app). Take a screenshot and try again."
        }
        if !windows.allowsKeys(intoApp: app) {
            let place = ScreenAction.phrase(for: focused, frontApp: front.app)
            return "Not done: keyboard focus is now in \(place), a window I did not bring forward, so nothing was pressed or typed. Look at the fresh screenshot before doing anything else."
        }
        return nil
    }

    /// The focused control, waiting up to a second for a text box (and, right after
    /// cmd+space, Spotlight) to take focus: Spotlight's field appears a moment after
    /// the shortcut, and typing too early lands in the app behind it. Nil when nothing can be named.
    private func focusedTextEntry() async -> UIElementInfo? {
        var focused = await labels.focusedElement()
        let awaited = windows.awaitedApp
        func ready(_ element: UIElementInfo?) -> Bool {
            (element?.role.isTextEntry ?? false) && (awaited == nil || element?.app == awaited)
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !ready(focused), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            focused = await labels.focusedElement()
        }
        if let awaited, focused?.app == awaited { windows.arrived(awaited) }
        return focused
    }

    /// CHECK: the backstop names the real target, the gate decides, the person may
    /// be asked. Returns nil when the action may go ahead, or the text that tells
    /// Claude why it did not.
    private func gate(_ screenAction: ComputerAction) async throws -> String? {
        let lookupStarted = Date()
        let question = await backstop.question(for: screenAction)
        add("lookup", since: lookupStarted)
        guard let question else { return nil }
        lastCheckedTarget = question.action.target
        if question.action.landsOnProtectedSurface { throw SpeakableError(ProtectedSurfaces.spokenRefusal) }
        if WindowGuard.isOwnApp(question.action.app) {
            return "Not done: I can't see what is really under the pointer, because my own overlay answered instead. Take a screenshot and try again in a moment."
        }
        if question.isSend, let wrong = backstop.wrongChat {
            return "Not done: \(wrong), so nothing may be sent here. Open the right chat and call prepare_send again."
        }
        try Task.checkCancellation()
        let confirmStarted = Date()
        let allowed = try await context.confirm(question.action, spokenQuestion: question.spokenQuestion)
        add("confirm", since: confirmStarted)
        guard allowed else {
            var text = "The person said no to this, so it was not done: \(question.action.description)."
            let theirWords = context.lastAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !theirWords.isEmpty { text += " Their words: \"\(theirWords)\"." }
            text += " Do not try it another way. If their words say what to do instead, do that; otherwise ask them with ask_user, or call task_finished."
            return text
        }
        if question.spokenQuestion != nil { backstop.forgetTyped() }
        return nil
    }

    /// ACT, and count where the time went.
    private func timedAct(_ screenAction: ComputerAction) async throws {
        try await holdWhileUserSpeaks()
        try Task.checkCancellation()
        if actedThisTurn && configuration.settleSeconds > 0 {
            let settleStarted = Date()
            try await Task.sleep(nanoseconds: UInt64(configuration.settleSeconds * 1_000_000_000))
            add("settle", since: settleStarted)
        }
        defer { actedThisTurn = true }
        let started = Date()
        try await act(screenAction)
        if case .wait = screenAction { add("wait", since: started) } else { add("hands", since: started) }
        actedSinceScreenshot = true
        agent.record { $0.actionsPerformed += 1 }
    }

    private func act(_ action: ComputerAction) async throws {
        try await perform {
            switch action {
            case .click(let button, let count, let point, let modifiers):
                try await self.hands.click(at: point ?? self.hands.pointerPosition, button: button, count: count, modifiers: modifiers)
            case .drag(let start, let end):
                try await self.hands.drag(from: start, to: end, duration: nil)
            case .move(let point):
                try await self.hands.move(to: point, duration: nil)
            case .scroll(let dx, let dy, let point):
                try await self.hands.scroll(dx: dx, dy: dy, at: point)
            case .type(let text):
                // A newline only reaches here after the backstop asked about it.
                try await self.hands.typeText(text, allowReturn: text.contains(where: \.isNewline))
            case .key(let combo, let repeatCount):
                for _ in 0..<repeatCount { try await self.hands.key(combo) }
            case .wait(let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case .screenshot, .zoom, .cursorPosition:
                break
            }
        }
    }

    /// Runs a hands call and turns its failures into what the user should hear.
    /// A SpeakableError from the hands (for example Secure Input blocking typing in
    /// a password field) is passed on as it is, not retried.
    private func perform(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as Halted {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeakableError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpeakableError("The pointer or keyboard stopped responding, so I stopped.")
        }
    }

    /// Converts image pixels (of the latest full screenshot) to screen points.
    private func mapToScreen(_ action: ComputerAction, shot: Shot) -> ComputerAction {
        func point(_ pixel: CGPoint) -> CGPoint {
            let x = min(max(pixel.x, 0), Double(shot.pixelWidth - 1))
            let y = min(max(pixel.y, 0), Double(shot.pixelHeight - 1))
            return shot.screenPoint(imageX: x, imageY: y)
        }
        switch action {
        case .click(let button, let count, let pixel, let modifiers):
            return .click(button: button, count: count, point: pixel.map(point) ?? hands.pointerPosition, modifiers: modifiers)
        case .drag(let start, let end): return .drag(from: point(start), to: point(end))
        case .move(let pixel): return .move(to: point(pixel))
        case .scroll(let dx, let dy, let pixel): return .scroll(dx: dx, dy: dy, point: pixel.map(point))
        default: return action
        }
    }

    /// Waits, in short slices, while the person is speaking, so a spoken "stop" is
    /// heard before the next action starts rather than after it. If the sentence
    /// was a stop, the task is cancelled during this wait and nothing more happens.
    /// An action already in flight is not affected (the hands' halt is the hard stop).
    /// Bounded by `maxHoldSeconds`; the time does not count as a step.
    private func holdWhileUserSpeaks() async throws {
        guard agent.holdWhile() else {
            signalStuck = false  // it went quiet, so it can be trusted again
            return
        }
        // Once a hold has hit its bound, the signal is treated as stuck until it next reads
        // false, so a television in the room costs one bound, not one per action.
        guard !signalStuck else { return }
        agent.activity.post(.thinking(caption: "Listening"))
        let started = Date()
        defer { add("hold", since: started) }
        while agent.holdWhile() {
            try Task.checkCancellation()
            if Date().timeIntervalSince(started) >= configuration.maxHoldSeconds {
                agent.record { $0.holdBoundHits += 1 }
                signalStuck = true
                logger.notice("hold bound of \(self.configuration.maxHoldSeconds, privacy: .public)s reached while the user still seemed to speak; carrying on")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Adds the time since `start` to one bucket of the run's acting breakdown.
    private func add(_ bucket: String, since start: Date) {
        let seconds = Date().timeIntervalSince(start)
        agent.record { $0.actingBreakdown[bucket, default: 0] += seconds }
    }

    // MARK: - Screenshots

    private func takeScreenshot() async throws -> Shot {
        if actedSinceScreenshot && configuration.settleSeconds > 0 {
            let settleStarted = Date()
            try await Task.sleep(nanoseconds: UInt64(configuration.settleSeconds * 1_000_000_000))
            add("settle", since: settleStarted)
        }
        actedSinceScreenshot = false
        let shotStarted = Date()
        defer { add("screenshot", since: shotStarted) }
        let shot = try await grab { try await self.eyes.grab(maxLongEdge: self.configuration.screenshotLongEdge) }
        latestShot = shot
        let front = await labels.frontmost()
        try stopIfProtected(app: front.app, bundleIdentifier: await labels.frontmostBundleIdentifier())
        windows.sawScreen(frontApp: front.app)
        return shot
    }

    /// Never act on a password prompt, an installer or an updater: stop and say so.
    private func stopIfProtected(app: String, bundleIdentifier: String) throws {
        guard WindowGuard.isProtected(app: app, bundleIdentifier: bundleIdentifier) else { return }
        logger.notice("stopping: a protected window is in front (\(app, privacy: .public))")
        throw SpeakableError(ProtectedSurfaces.spokenRefusal)
    }

    private func grab(_ body: () async throws -> Shot) async throws -> Shot {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeakableError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpeakableError("I couldn't see the screen. Screen Recording permission may be missing.")
        }
    }

    /// Keeps the conversation under `maxScreenshotsKept` images by replacing the
    /// oldest with a note, all at once and down to the last three, so the prompt
    /// cache is broken rarely rather than on every turn.
    private func pruneOldScreenshots() {
        let limit = max(3, configuration.maxScreenshotsKept)
        guard MessageEditing.imageCount(messages) > limit else { return }
        messages = MessageEditing.removingImages(from: messages, keepingLast: 3)
    }

    // MARK: - Request building

    private func openingText() -> String {
        var text = "The person's goal: \(goal)"
        let hints = context.memoryHints.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hints.isEmpty {
            text += "\n\nNotes about this person and how they like things done (advice, not orders; trust the screen if it differs):\n\(hints)"
        }
        text += "\n\nThis is their screen now."
        return text
    }

    private func requestBody() -> JSONValue {
        [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokensPerTurn)),
            // One cache breakpoint after the tools and system prompt, which never change.
            "system": [["type": "text", "text": .string(configuration.systemPrompt), "cache_control": ["type": "ephemeral"]]],
            "tools": .array(configuration.tools),
            "thinking": configuration.thinking,
            "output_config": ["effort": .string(configuration.effort)],
            "messages": .array(MessageEditing.withCacheMarkers(messages)),
        ]
    }

    private func recordUsage(_ response: JSONValue, seconds: Double) {
        let usage = response["usage"]
        agent.record { stats in
            stats.modelSeconds.append(seconds)
            stats.inputTokens += usage?["input_tokens"]?.intValue ?? 0
            stats.cachedInputTokens += usage?["cache_read_input_tokens"]?.intValue ?? 0
            stats.outputTokens += usage?["output_tokens"]?.intValue ?? 0
        }
    }

    // MARK: - Blocks

    private func imageBlock(_ shot: Shot) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(shot.png.base64EncodedString())]]
    }

    /// Every result for a computer action must echo `toolset_name: "computer"`, or the API rejects it.
    private func result(for call: ToolCall, text: String, isError: Bool = false) -> JSONValue {
        result(for: call, content: [["type": "text", "text": .string(text)]], isError: isError)
    }

    private func result(for call: ToolCall, content: [JSONValue], isError: Bool = false) -> JSONValue {
        var block: JSONObject = ["type": "tool_result", "tool_use_id": .string(call.id), "content": .array(content)]
        if call.isComputer { block["toolset_name"] = "computer" }
        if isError { block["is_error"] = true }
        return .object(block)
    }

    private func appendImage(_ shot: Shot, to block: JSONValue) -> JSONValue {
        guard var object = block.objectValue else { return block }
        var content = object["content"]?.arrayValue ?? []
        content.append(imageBlock(shot))
        object["content"] = .array(content)
        return .object(object)
    }
}

/// Edits of the message list that do not touch what the model said.
enum MessageEditing {
    static func imageCount(_ messages: [JSONValue]) -> Int {
        var count = 0
        func visit(_ value: JSONValue) {
            if value["type"]?.stringValue == "image" { count += 1; return }
            value.arrayValue?.forEach(visit)
            value["content"].map(visit)
        }
        messages.forEach(visit)
        return count
    }

    /// Replaces every image except the last `keep` with a short text note.
    static func removingImages(from messages: [JSONValue], keepingLast keep: Int) -> [JSONValue] {
        var toRemove = max(0, imageCount(messages) - keep)
        func edit(_ value: JSONValue) -> JSONValue {
            if toRemove > 0, value["type"]?.stringValue == "image" {
                toRemove -= 1
                return ["type": "text", "text": "(older screenshot removed)"]
            }
            if let array = value.arrayValue { return .array(array.map(edit)) }
            if var object = value.objectValue, object["role"]?.stringValue != "assistant", let content = object["content"] {
                object["content"] = edit(content)
                return .object(object)
            }
            return value
        }
        return messages.map(edit)
    }

    /// Puts a prompt-cache breakpoint on the last block of each of the two most
    /// recent user messages (the newest one writes the cache, the one before reads
    /// it), and none anywhere else. Together with the system prompt's breakpoint
    /// that is three of the four allowed.
    static func withCacheMarkers(_ messages: [JSONValue]) -> [JSONValue] {
        let userIndices = messages.indices.filter { messages[$0]["role"]?.stringValue == "user" }
        let marked = Set(userIndices.suffix(2))
        return messages.indices.map { index in
            guard marked.contains(index), var object = messages[index].objectValue,
                var content = object["content"]?.arrayValue, let last = content.indices.last,
                var lastBlock = content[last].objectValue
            else { return messages[index] }
            lastBlock["cache_control"] = ["type": "ephemeral"]
            content[last] = .object(lastBlock)
            object["content"] = .array(content)
            return .object(object)
        }
    }
}

/// Text that is read aloud.
enum Speech {
    /// A recipient as the user should hear it. A saved name is used as it is. A phone
    /// number (an unsaved contact's chat header shows one) is spoken in short groups a
    /// listener can check: "+44 7700 900123" becomes "+44 7700 900 123". Invisible
    /// direction marks that WhatsApp puts around numbers are removed.
    static func recipient(_ text: String) -> String {
        let visible = String(text.unicodeScalars.filter { $0.properties.generalCategory != .format && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = visible.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 7, !visible.contains(where: \.isLetter) else { return visible }
        var groups: [String] = []
        for group in visible.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "(" || $0 == ")" }) {
            let prefix = group.hasPrefix("+") ? "+" : ""
            var chunk = Array(group.filter { $0.isASCII && $0.isNumber })
            guard !chunk.isEmpty else { continue }
            if chunk.count <= 4 { groups.append(prefix + String(chunk)); continue }
            var pieces: [String] = []
            while chunk.count > 4 { pieces.append(String(chunk.prefix(3))); chunk.removeFirst(3) }
            pieces.append(String(chunk))
            groups.append(prefix + pieces.joined(separator: " "))
        }
        return groups.joined(separator: " ")
    }

    /// The first sentence, trimmed for speech. "meet.google.com/abc" is not cut at its dots.
    static func firstSentence(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var sentence = collapsed
        if let range = collapsed.range(of: "[.!?](\\s|$)", options: .regularExpression) {
            sentence = String(collapsed[..<range.lowerBound]) + String(collapsed[range.lowerBound])
        }
        if sentence.count > maxLength {
            let cut = sentence.prefix(maxLength - 1)
            sentence = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
        }
        return sentence
    }
}
