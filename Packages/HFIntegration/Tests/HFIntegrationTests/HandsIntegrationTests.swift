import CoreGraphics
import Foundation
import HFCore
import HFHands
import HFTasks
import Testing

// The REAL SystemHands behind the runner's halt and resume hooks, posting into a
// recorder instead of the real Mac: a spoken stop must freeze a long glide within
// tens of milliseconds and leave no button held down.

/// Records every event SystemHands would post. Nothing reaches the real system.
final class RecordingPoster: EventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var pointer = CGPoint(x: 100, y: 100)
    private var events: [String] = []

    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var mouseMoves: Int { recorded.filter { $0.hasPrefix("move") }.count }
    var buttonsDown: Int { recorded.filter { $0 == "down" }.count - recorded.filter { $0 == "up" }.count }

    func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        lock.lock()
        defer { lock.unlock() }
        pointer = point
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: events.append("down")
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: events.append("up")
        default: events.append("move")
        }
    }
    func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) { lock.lock(); events.append(down ? "key down" : "key up"); lock.unlock() }
    func postTypedKey(code: CGKeyCode, text: String, down: Bool, flags: CGEventFlags) {
        lock.lock(); events.append("typed \(text)"); lock.unlock()
    }
    func postText(_ text: String, down: Bool) { lock.lock(); events.append("text \(text)"); lock.unlock() }
    func postScroll(vertical: Int32, horizontal: Int32) { lock.lock(); events.append("scroll"); lock.unlock() }
    func postHardwareKey(_ key: Int32, down: Bool, flags: CGEventFlags) { lock.lock(); events.append("hardware"); lock.unlock() }
    var pointerLocation: CGPoint { lock.lock(); defer { lock.unlock() }; return pointer }
    var mainDisplayBounds: CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    var canPostEvents: Bool { true }
    /// Buttons down and not yet released, worked out from what was posted.
    var heldButtons: [CGMouseButton] { buttonsDown > 0 ? [.left] : [] }
    var heldModifierFlags: CGEventFlags { [] }
}

struct USKeyboard: KeyboardLayout {
    func key(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? { (0, character.isUppercase) }
    func typingKey(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? { (0, character.isUppercase) }
}

/// Glides the real hands slowly to Send, then clicks it.
struct LongGlideExecutor: TaskExecuting {
    let hands: any Hands
    let glideStarted = Log<Bool>()
    func run(goal: String, context: TaskContext) async throws -> String {
        context.report("Moving to Send")
        glideStarted.append(true)
        try await hands.move(to: CGPoint(x: 1300, y: 800), duration: 2)
        try await hands.click(at: CGPoint(x: 1300, y: 800))
        return "Clicked."
    }
}

@Suite(.serialized) struct HandsIntegrationTests {

    @Test("A stop freezes the real SystemHands mid-glide and nothing is left held down")
    func haltFreezesRealGlide() async throws {
        let activity = ActivityLog()
        let poster = RecordingPoster()
        let hands = SystemHands(poster: poster, layout: USKeyboard(), activity: activity.bus)
        let executor = LongGlideExecutor(hands: hands)
        let recorder = EventRecorder()
        var configuration = TaskRunner.Configuration()
        configuration.tick = 0.01
        configuration.cancelGrace = 0.5
        let runner = TaskRunner(
            executor: executor, gate: KeywordGate(), sink: recorder.sink, configuration: configuration,
            onCancel: { hands.halt() }, onTaskEnd: { _, _ in hands.resume() }, activityBus: activity.bus)
        defer { runner.shutdown() }

        _ = runner.start(goal: "Click Send")
        #expect(await waitUntil { poster.mouseMoves >= 12 })  // about 100 ms into a 2 s glide (one step per 1/120 s)
        let movesAtStop = poster.mouseMoves
        let begin = ContinuousClock.now
        _ = runner.cancel(taskID: nil)
        #expect(hands.isHalted)

        // The glide throws at its next step; the executor unwinds; the runner releases the hands.
        #expect(await waitUntil(timeout: 1) { !hands.isHalted })
        #expect(secondsSince(begin) < 0.25, "frozen and released in \(secondsSince(begin)) s")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(poster.mouseMoves <= movesAtStop + 3, "the pointer kept moving after stop: \(poster.mouseMoves - movesAtStop) more steps")
        #expect(poster.mouseMoves < 240, "the 2 s glide must not complete")
        #expect(!poster.recorded.contains("down"), "the click after the glide never happens")
        #expect(poster.buttonsDown == 0)
        #expect(recorder.events.last?.status == .cancelled)
    }

    @Test("One spoken stop posts .halted to the companion exactly once")
    func haltedPostedOnce() async throws {
        let activity = ActivityLog()
        let poster = RecordingPoster()
        let hands = SystemHands(poster: poster, layout: USKeyboard(), activity: activity.bus)
        let recorder = EventRecorder()
        var configuration = TaskRunner.Configuration()
        configuration.tick = 0.01
        let runner = TaskRunner(
            executor: LongGlideExecutor(hands: hands), gate: KeywordGate(), sink: recorder.sink,
            configuration: configuration, onCancel: { hands.halt() }, onTaskEnd: { _, _ in hands.resume() },
            activityBus: activity.bus)
        defer { runner.shutdown() }
        _ = runner.start(goal: "Click Send")
        #expect(await waitUntil { poster.mouseMoves >= 5 })
        _ = runner.cancel(taskID: nil)
        #expect(await activity.waitFor { if case .taskEnded = $0 { true } else { false } })
        try? await Task.sleep(nanoseconds: 50_000_000)
        let halts = activity.events.filter { $0 == .halted }.count
        #expect(halts == 1, "the companion saw \(halts) halted events for one stop")
    }
}
