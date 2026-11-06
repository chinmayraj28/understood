import Foundation
import HFCore
import HFEyes
import HFHands
import HFScreenAgent

// hf-agent: run one goal with the real screen agent, from a terminal.
//
//   swift run hf-agent "Open TextEdit and type hello"
//   swift run hf-agent --model claude-haiku-5-5 --effort low "..."
//
// It MOVES THE REAL POINTER AND TYPES ON THE REAL KEYBOARD. There is no safety
// gate here, so every action the backstop would check is asked on this
// terminal instead (y to allow, anything else refuses). Ctrl+C freezes the
// pointer and keyboard at once and stops the run.

/// A TaskContext for the terminal: questions and confirmations on standard input.
final class TerminalContext: TaskContext, @unchecked Sendable {
    let taskID = "cli"
    let goal: String
    let memoryHints: String
    private(set) var lastAnswer = ""
    private let maxSteps: Int
    /// Non-interactive mode for short scripted runs: checks naming one of these apps are
    /// allowed, every other check is refused, and questions get `fixedAnswer`.
    var allowedApps: [String] = []
    var fixedAnswer: String?
    /// Refuse anything that could send: a Send-like target, Return outside a search
    /// field, or a click on a control that cannot be named (it might be Send).
    var neverSend = false
    /// What the person "says" when --never-send refuses a send, e.g. "No, don't send it. Clear the box."
    var declineWords: String?
    private var steps = 0
    private let started = Date()

    init(goal: String, memoryHints: String, maxSteps: Int) {
        self.goal = goal
        self.memoryHints = memoryHints
        self.maxSteps = maxSteps
    }

    private func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }

    /// Reads a line without blocking the Swift concurrency pool.
    private func readAnswer() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: readLine() ?? "") }
        }
    }

    func askUser(_ question: String, options: [String]) async throws -> String {
        print("\(stamp()) QUESTION \(question)\(options.isEmpty ? "" : " [\(options.joined(separator: " / "))]")")
        if let fixedAnswer {
            print("> \(fixedAnswer) (scripted)")
            lastAnswer = fixedAnswer
            return fixedAnswer
        }
        print("> ", terminator: "")
        fflush(stdout)
        lastAnswer = await readAnswer()
        try Task.checkCancellation()
        return lastAnswer
    }

    func confirm(_ action: ScreenAction, spokenQuestion: String?) async throws -> Bool {
        let actionDescription = action.description
        print("\(stamp()) CHECK \(actionDescription)")
        if let spokenQuestion { print("        would ask: \(spokenQuestion)") }
        if neverSend, let reason = Self.sendLikeReason(action) {
            print("        REFUSED (scripted --never-send: \(reason))")
            // For a send, the scripted answer is what the person "said", so the agent can act on it.
            lastAnswer = reason == "target cannot be named" ? "no" : (declineWords ?? "no")
            return false
        }
        if !allowedApps.isEmpty {
            let allowed = allowedApps.contains { actionDescription.contains(" in \($0)") }
            print("        \(allowed ? "allowed" : "REFUSED") (scripted: only \(allowedApps.joined(separator: ", ")))")
            lastAnswer = allowed ? "yes" : "no"
            return allowed
        }
        print("        allow? [y/N] ", terminator: "")
        fflush(stdout)
        lastAnswer = await readAnswer()
        try Task.checkCancellation()
        return lastAnswer.lowercased().hasPrefix("y")
    }

    /// Why `--never-send` refuses an action, read from its structured fields; nil to let it through.
    static func sendLikeReason(_ action: ScreenAction) -> String? {
        let role = action.target?.role
        switch action.kind {
        case .pressKey where action.key?.isReturn == true, .typeLineBreak:
            return role == .searchField ? nil : "Return outside a search field"
        case .click, .doubleClick, .rightClick, .drag:
            guard let target = action.target, target.isNamed else { return "target cannot be named" }
            if !Set(target.words).isDisjoint(with: ["send", "post", "reply", "submit", "share"]) { return "looks like Send" }
            return nil
        case .pressKey:
            return nil
        }
    }

    func report(_ progress: String) { print("\(stamp()) PROGRESS \(progress)") }

    func step() throws {
        steps += 1
        print("\(stamp()) STEP \(steps)")
        if steps > maxSteps { throw StepLimitReached(limit: maxSteps) }
    }
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var settings = Settings.load()
var configuration = ScreenAgentConfiguration(settings: settings)
var goalWords: [String] = []
var allowedApps: [String] = []
var fixedAnswer: String?
var neverSend = false
var declineWords: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--model": configuration.model = arguments.isEmpty ? configuration.model : arguments.removeFirst()
    case "--effort": configuration.effort = arguments.isEmpty ? configuration.effort : arguments.removeFirst()
    case "--long-edge": configuration.screenshotLongEdge = Int(arguments.isEmpty ? "" : arguments.removeFirst()) ?? 1280
    case "--allow-in": allowedApps = (arguments.isEmpty ? "" : arguments.removeFirst()).split(separator: ",").map(String.init)
    case "--answer": fixedAnswer = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--never-send": neverSend = true
    case "--decline-words": declineWords = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--test-contact":
        // The demo's first task, aimed only at the safe test contact from .env.
        guard !settings.testWhatsAppContact.isEmpty else { print("TEST_WHATSAPP_CONTACT is not set"); exit(2) }
        goalWords = ["WhatsApp \(settings.testWhatsAppContact): running late, ten minutes"]
        neverSend = true
    case "--settle": configuration.settleSeconds = Double(arguments.isEmpty ? "" : arguments.removeFirst()) ?? configuration.settleSeconds
    case "--steps": settings.maxTaskSteps = Int(arguments.isEmpty ? "" : arguments.removeFirst()) ?? settings.maxTaskSteps
    default: goalWords.append(argument)
    }
}
let goal = goalWords.joined(separator: " ")
guard !goal.isEmpty else {
    print("usage: hf-agent [--model M] [--effort low|medium|high] [--long-edge 1280] [--steps N] \"<goal>\"")
    exit(2)
}
let missing = Permissions.missing().filter { $0.name != "Microphone" }
guard missing.isEmpty else {
    for permission in missing { print("Missing permission: \(permission.name). \(permission.howToGrant)") }
    exit(1)
}

// MARK: - Run

let hands = SystemHands()
let client = ClaudeClient(settings: settings)
client.onAPIError = { status, message in print("        API \(status): \(message)") }
let labels = AccessibilityLabels()
let agent = ScreenAgent(hands: hands, eyes: ScreenEyes(), labels: labels, client: client, configuration: configuration)
let context = TerminalContext(goal: goal, memoryHints: "", maxSteps: settings.maxTaskSteps)
context.allowedApps = allowedApps
context.fixedAnswer = fixedAnswer
context.neverSend = neverSend
context.declineWords = declineWords
print("model \(configuration.model), effort \(configuration.effort), screenshots \(configuration.screenshotLongEdge)px. Ctrl+C stops.")

let run = Task {
    // Web pages in Chrome and Electron apps are unnamed until the eyes switch their
    // accessibility on; it takes effect about two seconds later. No wait is paid for it:
    // the first model turn (2 to 3 s) runs meanwhile, and the agent's first look at a
    // web page comes after that. Restored before exit.
    let switched = await labels.enableWebContent()
    if !switched.isEmpty { print("web content switched on in \(switched.joined(separator: ", "))") }
    let started = Date()
    do {
        let summary = try await agent.run(goal: goal, context: context)
        print("DONE: \(summary)")
    } catch let error as SpeakableError {
        print("FAILED: \(error.spokenMessage)")
    } catch is StepLimitReached {
        print("FAILED: ran out of steps")
    } catch is CancellationError {
        print("STOPPED")
    } catch {
        print("FAILED: \(error)")
    }
    let stats = agent.lastRunStats
    let turns = stats.modelSeconds.map { String(format: "%.1f", $0) }.joined(separator: " ")
    let acting = stats.actingSeconds.map { String(format: "%.1f", $0) }.joined(separator: " ")
    print(String(format: "total %.1fs; model turns [%@]; acting [%@]; actions %d; tokens in %d (cached %d) out %d",
                 Date().timeIntervalSince(started), turns, acting, stats.actionsPerformed,
                 stats.inputTokens, stats.cachedInputTokens, stats.outputTokens))
    let breakdown = stats.actingBreakdown.sorted { $0.value > $1.value }
        .map { String(format: "%@ %.1fs", $0.key, $0.value) }.joined(separator: ", ")
    print("acting breakdown: \(breakdown)")
    // There is no task runner here, so this tool releases the hands itself, once the run has ended.
    hands.resume()
    let restored = labels.restoreWebContentSwitches()
    if !restored.isEmpty { print("web content switches restored in \(restored.joined(separator: ", "))") }
    // A hardware key (volume, media) posted just before exit can be lost, so wait a moment.
    try? await Task.sleep(nanoseconds: 500_000_000)
    exit(0)
}

// Ctrl+C: freeze the hands first, then cancel the run.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
var interruptCount = 0
interrupt.setEventHandler {
    interruptCount += 1
    hands.halt()
    hands.releaseEverything()
    run.cancel()
    if interruptCount > 1 {  // a second Ctrl+C: leave now, but put the browsers back first
        _ = labels.restoreWebContentSwitches()
        exit(130)
    }
}
interrupt.resume()
dispatchMain()
