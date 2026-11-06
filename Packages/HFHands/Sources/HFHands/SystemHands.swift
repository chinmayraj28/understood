import CoreGraphics
import Foundation
import HFCore
import os

/// The agent's hands: the real pointer and keyboard of this Mac, used visibly.
///
/// The pointer always glides to its targets (never less than `minimumGlideDuration`),
/// clicks are held briefly the way a finger presses, and text is typed a
/// character at a time at a fast typist's pace.
///
/// **Stop.** Every action is cut into small steps: one pointer position every
/// 1/120 s, one character at a time, and every wait sliced into 5 ms pieces.
/// The stop flag is checked before each one, so `halt()` freezes an action
/// within a few milliseconds wherever it is, including in the middle of a
/// click's hold, a drag's hold or the settle after a media key. Anything held
/// down when that happens (a mouse button, Command) is released before
/// `Halted` is thrown, and then `releaseEverything()` clears anything the
/// system still thinks is held.
///
/// **Halt is safe by construction.** `halt()` stops every action that was
/// already requested, including ones still waiting their turn, even if
/// `resume()` is called before they reach their next step. `resume()` only
/// lets actions requested after it run.
///
/// Calls run one at a time, in order. A caller whose Swift task is cancelled
/// while waiting its turn leaves the queue at once.
public final class SystemHands: Hands, @unchecked Sendable {
    private let poster: EventPosting
    private let layout: KeyboardLayout
    private let activity: ActivityBus
    private let gate = ActionGate()
    private let haltLock = NSLock()
    private var halted = false
    /// Counts halts. An action remembers the count when it was requested; if it
    /// has moved on, that action was halted, whatever `halted` says now.
    private var haltGeneration = 0
    private let logger = Logger(subsystem: "com.handsfree", category: "HFHands")

    /// Pause between typed characters. 40 ms is a fast human typist (about 300
    /// words a minute in bursts): slow enough that autocomplete fields such as
    /// Gmail's To field keep up, fast enough for a sentence in a couple of seconds.
    public var typingInterval: TimeInterval = 0.04
    /// How long a click holds the button down. Some web pages, Electron apps
    /// and Catalyst controls ignore a click with no hold.
    public var clickHoldInterval: TimeInterval = 0.03
    /// Pause between the clicks of a double or triple click (well inside the
    /// system's double-click interval).
    public var multiClickInterval: TimeInterval = 0.06
    /// How long the button is held before a drag starts moving, so apps
    /// recognise a drag rather than a click.
    public var dragHoldInterval: TimeInterval = 0.08
    /// Wait after volume, media and brightness keys: measured, the system loses
    /// such a key if the sender moves on (or exits) at once, and the settle also
    /// lets callers read the new level straight after.
    public var hardwareKeySettle: TimeInterval = 0.12
    /// Pause between scroll wheel events.
    public var scrollInterval: TimeInterval = 0.012
    /// The shortest glide, whatever the caller asks for, so the pointer always
    /// visibly travels and never teleports.
    public var minimumGlideDuration: TimeInterval = 0.12
    /// The longest glide.
    public static let maximumGlideDuration: TimeInterval = 3
    /// Points this far outside the screen are pulled in to the edge; further out is an error.
    public static let offScreenTolerance: CGFloat = 40
    /// After a glide the real pointer must be this close to the target, or
    /// something (a revoked permission, a carer's hand on the mouse) is blocking it.
    public static let pointerTolerance: CGFloat = 2

    /// The real Mac. Releases any button or modifier a previous run left held.
    public convenience init(activity: ActivityBus = .shared) {
        self.init(poster: QuartzEventPoster(), layout: LiveKeyboardLayout(), activity: activity)
    }

    /// Any poster: pass a `RecordingEventPoster` to test against these real hands
    /// without touching the Mac.
    public init(poster: EventPosting, layout: KeyboardLayout, activity: ActivityBus) {
        self.poster = poster
        self.layout = layout
        self.activity = activity
        releaseEverything()
    }

    // MARK: Stop flag

    public func halt() {
        // The task runner posts `.halted` for the companion; the hands only stop.
        haltLock.withLock {
            halted = true
            haltGeneration += 1
        }
    }

    public func resume() {
        haltLock.withLock { halted = false }
    }

    public var isHalted: Bool { haltLock.withLock { halted } }

    public var pointerPosition: CGPoint { poster.pointerLocation }

    /// Lets go of every mouse button and modifier the system believes is held.
    ///
    /// If this process was killed between a key or button going down and its
    /// release, macOS keeps it held until real input arrives, and this app's
    /// users cannot press a key to clear a stuck Command. Called when the hands
    /// are created and after every halt; the app should also call it at launch
    /// and at quit.
    public func releaseEverything() {
        let location = poster.pointerLocation
        for button in poster.heldButtons {
            let upType: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
            poster.postMouse(upType, at: location, button: button, clickState: 1, flags: [])
        }
        var remaining = poster.heldModifierFlags
        let modifiers: [(CGEventFlags, [CGKeyCode])] = [
            (.maskCommand, [55, 54]), (.maskShift, [56, 60]), (.maskAlternate, [58, 61]), (.maskControl, [59, 62]),
        ]
        for (flag, codes) in modifiers where remaining.contains(flag) {
            remaining.subtract(flag)
            for code in codes { poster.postKey(code: code, down: false, flags: remaining) }  // left and right keys
        }
    }

    // MARK: Pointer

    public func move(to point: CGPoint, duration: TimeInterval?) async throws {
        try await perform { action in
            let target = try self.onScreen(point)
            try await self.glide(to: target, duration: duration, dragging: nil, action: &action)
        }
    }

    public func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {
        try await perform { action in
            let target = try self.onScreen(point)
            let clicks = min(3, max(1, count))
            try await self.glide(to: target, duration: nil, dragging: nil, action: &action)
            try self.pressModifiers(modifiers, action: &action)
            let flags = Self.flags(for: modifiers)
            let (downType, upType, _, quartzButton) = Self.mouseTypes(for: button)
            for clickNumber in 1...clicks {
                try self.checkpoint(action)
                self.poster.postMouse(downType, at: target, button: quartzButton, clickState: clickNumber, flags: flags)
                action.buttons.append(button)
                try await self.pause(self.clickHoldInterval, action)  // a finger's press, not an instant
                self.poster.postMouse(upType, at: target, button: quartzButton, clickState: clickNumber, flags: flags)
                action.buttons.removeAll { $0 == button }
                if clickNumber < clicks { try await self.pause(self.multiClickInterval, action) }
            }
            self.releaseModifiers(action: &action)
            self.activity.post(.clicked(at: target))
        }
    }

    public func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws {
        try await perform { action in
            let from = try self.onScreen(start)
            let to = try self.onScreen(end)
            try await self.glide(to: from, duration: nil, dragging: nil, action: &action)
            try self.checkpoint(action)
            self.poster.postMouse(.leftMouseDown, at: from, button: .left, clickState: 1, flags: [])
            action.buttons.append(.left)
            try await self.pause(self.dragHoldInterval, action)
            try await self.glide(to: to, duration: duration, dragging: .left, action: &action)
            try await self.pause(self.dragHoldInterval / 2, action)
            self.poster.postMouse(.leftMouseUp, at: to, button: .left, clickState: 1, flags: [])
            action.buttons.removeAll()
        }
    }

    public func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws {
        try await perform { action in
            if let point {
                try await self.glide(to: try self.onScreen(point), duration: nil, dragging: nil, action: &action)
            }
            guard dx != 0 || dy != 0 else { return }
            self.activity.post(.scrolled)
            // At most 12 wheel events, so a long scroll is still quick, each
            // carrying an even share of the lines. Quartz counts positive as up
            // and left, the opposite of this protocol, hence the minus signs.
            let events = min(12, max(abs(dx), abs(dy)))
            for index in 0..<events {
                try self.checkpoint(action)
                let vertical = Self.share(of: dy, part: index, of: events)
                let horizontal = Self.share(of: dx, part: index, of: events)
                self.poster.postScroll(vertical: Int32(clamping: -vertical), horizontal: Int32(clamping: -horizontal))
                if index < events - 1 { try await self.pause(self.scrollInterval, action) }
            }
        }
    }

    // MARK: Keyboard

    public func key(_ combo: String) async throws {
        try await perform { action in
            let chords = try KeyTable.parse(combo, layout: self.layout)
            for chord in chords {
                try self.press(chord, action: &action)
            }
            if chords.contains(where: { if case .hardware = $0.key { return true } else { return false } }) {
                try await self.pause(self.hardwareKeySettle, action)
            }
        }
    }

    public func typeText(_ text: String, allowReturn: Bool) async throws {
        try await typeText(text, allowReturn: allowReturn, characterInterval: typingInterval)
    }

    /// Types at a chosen pace. Search fields that only filter (Spotlight, a
    /// browser's address bar) take text quickly; the default suits autocomplete fields.
    public func typeText(_ text: String, allowReturn: Bool, characterInterval: TimeInterval) async throws {
        // Refuse before typing anything, so a message is never half typed.
        if !allowReturn, text.contains(where: \.isNewline) {
            throw SpeakableError("I won't type a line break there, because Return can send the message.")
        }
        try await perform { action in
            self.activity.post(.typing)
            for character in text {
                try self.checkpoint(action)
                if character.isNewline {
                    try self.press(Chord(modifiers: [], key: .code(36, extraFlags: []), label: "return"), action: &action)
                } else if character == "\t" {
                    try self.press(Chord(modifiers: [], key: .code(48, extraFlags: []), label: "tab"), action: &action)
                } else if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                    continue  // other control characters have no key
                } else {
                    self.type(character)
                }
                try await self.pause(characterInterval, action)
            }
        }
    }

    /// One character: the real key when the layout has one (so key handlers in
    /// web pages, Electron apps and terminals see the right key), with the exact
    /// text attached; otherwise a text-only event.
    private func type(_ character: Character) {
        let text = String(character)
        let key: (code: CGKeyCode, needsShift: Bool)? = character == " " ? (49, false) : layout.typingKey(for: character)
        if let key {
            let flags: CGEventFlags = key.needsShift ? .maskShift : []
            poster.postTypedKey(code: key.code, text: text, down: true, flags: flags)
            poster.postTypedKey(code: key.code, text: text, down: false, flags: flags)
        } else {
            for piece in Self.eventSizedPieces(of: character) {
                poster.postText(piece, down: true)
                poster.postText(piece, down: false)
            }
        }
    }

    // MARK: Internals

    /// One action in flight: the halt count when it was requested, and what it holds down.
    struct Action {
        let generation: Int
        var buttons: [MouseButton] = []
        var modifiers: [KeyModifier] = []
    }

    /// Runs one action: remembers the halt count, waits its turn, checks
    /// permission, and releases anything still held however the action ends.
    private func perform(_ body: @escaping (inout Action) async throws -> Void) async throws {
        var action = Action(generation: haltLock.withLock { haltGeneration })
        try await gate.enter()
        do {
            try checkpoint(action)
            guard poster.canPostEvents else { throw SpeakableError(Permissions.accessibilityMissingSentence) }
            try await body(&action)
            release(&action)
            await gate.leave()
        } catch {
            release(&action)
            if error is Halted || error is CancellationError {
                logger.info("action stopped: \(String(describing: error), privacy: .public)")
                releaseEverything()
            }
            await gate.leave()
            throw error
        }
    }

    private func checkpoint(_ action: Action) throws {
        let stopped = haltLock.withLock { halted || haltGeneration != action.generation }
        if stopped { throw Halted() }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Waits, in 5 ms slices that each check the stop flag.
    private func pause(_ seconds: TimeInterval, _ action: Action) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            try checkpoint(action)
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.005) * 1_000_000_000))
        }
    }

    private func onScreen(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { throw SpeakableError("That spot is off the screen.") }
        let screen = poster.mainDisplayBounds
        let tolerance = Self.offScreenTolerance
        guard screen.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else {
            throw SpeakableError("That spot is off the screen.")
        }
        return CGPoint(
            x: min(max(point.x, screen.minX), screen.maxX - 1),
            y: min(max(point.y, screen.minY), screen.maxY - 1))
    }

    private func glide(to target: CGPoint, duration: TimeInterval?, dragging: MouseButton?, action: inout Action) async throws {
        let start = poster.pointerLocation
        let distance = Glide.distance(start, target)
        let requested = duration ?? Glide.duration(forDistance: distance)
        // Never a teleport: anything that moves takes at least the minimum glide.
        let seconds = distance < 1 ? 0 : min(Self.maximumGlideDuration, max(minimumGlideDuration, requested))
        // Tell the companion first, with the real duration, so it moves with the pointer.
        activity.post(.pointerMoving(to: target, duration: seconds))
        let moveType: CGEventType
        let button: CGMouseButton
        if let dragging {
            (_, _, moveType, button) = Self.mouseTypes(for: dragging)
        } else {
            (moveType, button) = (.mouseMoved, .left)
        }
        let flags = Self.flags(for: action.modifiers)
        do {
            for point in Glide.path(from: start, to: target, duration: seconds) {
                try checkpoint(action)
                poster.postMouse(moveType, at: point, button: button, clickState: 0, flags: flags)
                if seconds > 0 { try await pause(Glide.stepInterval, action) }
            }
        } catch {
            // Stopped part way: tell the companion where the pointer really is.
            activity.post(.pointerMoving(to: poster.pointerLocation, duration: 0))
            throw error
        }
        try await checkPointerArrived(at: target, action)
    }

    /// Dropped-event detection: the real pointer must be where we put it.
    private func checkPointerArrived(at target: CGPoint, _ action: Action) async throws {
        if Glide.distance(poster.pointerLocation, target) <= Self.pointerTolerance { return }
        try await pause(0.03, action)  // the window server can lag a moment behind
        if Glide.distance(poster.pointerLocation, target) <= Self.pointerTolerance { return }
        if !poster.canPostEvents { throw SpeakableError(Permissions.accessibilityMissingSentence) }
        throw SpeakableError("Something is blocking my pointer, so I've stopped.")
    }

    private func press(_ chord: Chord, action: inout Action) throws {
        try checkpoint(action)
        try pressModifiers(chord.modifiers, action: &action)
        try checkpoint(action)  // a stop between the modifiers and the key presses nothing
        switch chord.key {
        case .code(let code, _):
            poster.postKey(code: code, down: true, flags: chord.flags)
            poster.postKey(code: code, down: false, flags: chord.flags)
        case .hardware(let key):
            poster.postHardwareKey(key, down: true, flags: chord.flags)
            poster.postHardwareKey(key, down: false, flags: chord.flags)
        }
        releaseModifiers(action: &action)
    }

    /// Presses modifiers one by one, as fingers would, each carrying the flags held so far.
    private func pressModifiers(_ modifiers: [KeyModifier], action: inout Action) throws {
        for modifier in KeyTable.modifierOrder where modifiers.contains(modifier) && !action.modifiers.contains(modifier) {
            try checkpoint(action)
            action.modifiers.append(modifier)
            poster.postKey(code: KeyTable.modifierKeyCodes[modifier]!, down: true, flags: Self.flags(for: action.modifiers))
        }
    }

    private func releaseModifiers(action: inout Action) {
        while let modifier = action.modifiers.popLast() {
            poster.postKey(code: KeyTable.modifierKeyCodes[modifier]!, down: false, flags: Self.flags(for: action.modifiers))
        }
    }

    /// Lets go of what this action holds: buttons first (at the pointer), then modifiers.
    private func release(_ action: inout Action) {
        for button in action.buttons.reversed() {
            let (_, upType, _, quartzButton) = Self.mouseTypes(for: button)
            poster.postMouse(upType, at: poster.pointerLocation, button: quartzButton, clickState: 1, flags: [])
        }
        action.buttons.removeAll()
        releaseModifiers(action: &action)
    }

    static func flags(for modifiers: [KeyModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.formUnion(KeyTable.flag(for: $1)) }
    }

    static func mouseTypes(for button: MouseButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    /// Splits `total` into `parts` near-equal integers; returns part `index`.
    static func share(of total: Int, part index: Int, of parts: Int) -> Int {
        guard parts > 0 else { return 0 }
        let base = total / parts
        let remainder = abs(total % parts)
        return base + (index < remainder ? total.signum() : 0)
    }

    /// Quartz accepts at most 20 UTF-16 units per key event; a character is
    /// almost always far shorter, but long emoji sequences are split safely.
    static func eventSizedPieces(of character: Character) -> [String] {
        let text = String(character)
        guard text.utf16.count > 20 else { return [text] }
        var pieces: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if current.utf16.count + String(scalar).utf16.count > 20 {
                pieces.append(current)
                current = ""
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Lets one action run at a time, in the order they arrive. A caller whose
/// task is cancelled while waiting leaves the queue at once and throws.
actor ActionGate {
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func enter() async throws {
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().continuation.resume()  // the turn passes straight to the next caller
        }
    }
}

/// Hands that can type at a chosen pace. `SystemHands` conforms; the quick tools
/// use it for fields that take text quickly, and fall back to the normal pace
/// with any other `Hands`.
public protocol PacedTyping: Sendable {
    func typeText(_ text: String, allowReturn: Bool, characterInterval: TimeInterval) async throws
}

extension SystemHands: PacedTyping {}
