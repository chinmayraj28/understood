import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFHands

// MARK: Glide

@Test func glidePostsIntermediatePositionsAndEndsExactlyOnTarget() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 100, y: 100))
    let hands = makeHands(poster)
    let target = CGPoint(x: 700.5, y: 400.25)
    try await hands.move(to: target, duration: 0.2)
    let moves = poster.moves
    #expect(moves.count >= 20)  // about 120 positions a second
    #expect(moves.last == target)
    #expect(hands.pointerPosition == target)
    var previous = 0.0
    for point in moves {  // the distance covered only grows
        let covered = Double(Glide.distance(CGPoint(x: 100, y: 100), point))
        #expect(covered >= previous - 0.0001)
        previous = covered
    }
    // Eased: the first step is much shorter than a middle step.
    let first = Glide.distance(CGPoint(x: 100, y: 100), moves[0])
    let middle = Glide.distance(moves[moves.count / 2 - 1], moves[moves.count / 2])
    #expect(first < middle / 3)
}

@Test func glideDurationScalesWithDistance() {
    #expect(Glide.duration(forDistance: 0) == 0)
    let short = Glide.duration(forDistance: 10)
    let medium = Glide.duration(forDistance: 100)
    let long = Glide.duration(forDistance: 1000)
    #expect(short >= 0.12 && short < medium && medium < long)
    #expect(long <= 1.0)
    #expect(abs(medium - 0.37) < 0.02)
    #expect(Glide.duration(forDistance: 100_000) == 1.0)
}

@Test func easingStartsAndEndsAtRest() {
    #expect(Glide.ease(0) == 0)
    #expect(Glide.ease(1) == 1)
    #expect(abs(Glide.ease(0.5) - 0.5) < 1e-9)
    #expect(Glide.ease(0.05) < 0.01)
}

@Test func aZeroDurationStillGlidesNeverTeleports() async throws {
    let poster = FakePoster(pointer: .zero)
    let hands = makeHands(poster)
    try await hands.move(to: CGPoint(x: 900, y: 600), duration: 0)
    #expect(poster.moves.count >= 12)  // the 0.12 s minimum at 120 a second
    poster.clear()
    try await hands.drag(from: CGPoint(x: 900, y: 600), to: CGPoint(x: 100, y: 600), duration: 0)
    let dragged = poster.events.filter { if case .mouse(.leftMouseDragged, _, _, _, _) = $0 { return true } else { return false } }
    #expect(dragged.count >= 12)  // the button is never held through a jump
}

@Test func glideTellsTheCompanionFirstWithTheRealDuration() async throws {
    let bus = ActivityBus()
    let poster = FakePoster(pointer: .zero)
    let hands = makeHands(poster, activity: bus)
    let posted = try await activity(of: bus) {
        try await hands.move(to: CGPoint(x: 300, y: 0), duration: 0.2)
        try await hands.move(to: CGPoint(x: 340, y: 0), duration: nil)
    }
    #expect(posted == [
        .pointerMoving(to: CGPoint(x: 300, y: 0), duration: 0.2),
        .pointerMoving(to: CGPoint(x: 340, y: 0), duration: Glide.duration(forDistance: 40)),
    ])
}

// MARK: Off-screen points and a blocked pointer

@Test func pointsJustOffScreenAreClampedAndFarOffAreRefused() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    try await hands.move(to: CGPoint(x: 1490, y: -10), duration: nil)
    #expect(hands.pointerPosition == CGPoint(x: 1469, y: 0))
    await #expect(throws: SpeakableError("That spot is off the screen.")) {
        try await hands.move(to: CGPoint(x: 5000, y: 300), duration: nil)
    }
    await #expect(throws: SpeakableError("That spot is off the screen.")) {
        try await hands.click(at: CGPoint(x: Double.nan, y: 3))
    }
}

@Test func aBlockedPointerStopsTheActionWithASpokenError() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 100, y: 100))
    poster.dropsPointerMoves = true  // a revoked permission, or a carer's hand on the mouse
    let hands = makeHands(poster)
    await #expect(throws: SpeakableError("Something is blocking my pointer, so I've stopped.")) {
        try await hands.click(at: CGPoint(x: 600, y: 300))
    }
    #expect(!poster.events.contains { if case .mouse(.leftMouseDown, _, _, _, _) = $0 { return true } else { return false } })
}

// MARK: Clicks

@Test func clickGlidesThenPressesWithAShortHold() async throws {
    let bus = ActivityBus()
    let poster = FakePoster(pointer: CGPoint(x: 10, y: 10))
    let hands = makeHands(poster, activity: bus)
    hands.clickHoldInterval = 0.03
    let times = TimeLog()
    poster.onEvent = { event in
        if case .mouse(let type, _, _, _, _) = event, type == .leftMouseDown || type == .leftMouseUp { times.add() }
    }
    let target = CGPoint(x: 500, y: 300)
    let posted = try await activity(of: bus) { try await hands.click(at: target, button: .left, count: 1, modifiers: []) }
    let events = poster.events
    let downIndex = events.firstIndex(of: .mouse(.leftMouseDown, target, .left, clickState: 1, flags: []))!
    #expect(downIndex > 5)  // there was a glide first
    #expect(events[downIndex - 1] == .mouse(.mouseMoved, target, .left, clickState: 0, flags: []))
    #expect(events[downIndex + 1] == .mouse(.leftMouseUp, target, .left, clickState: 1, flags: []))
    #expect(times.gaps.first! >= 0.025)  // held like a finger, not an instant
    #expect(poster.nothingHeld)
    #expect(posted.last == .clicked(at: target))
}

@Test func doubleClickCountsUpAndRightClickUsesTheRightButton() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 50, y: 50))
    let hands = makeHands(poster)
    try await hands.click(at: CGPoint(x: 50, y: 50), button: .left, count: 2, modifiers: [])
    let states = poster.events.compactMap { if case .mouse(.leftMouseDown, _, _, let state, _) = $0 { return state } else { return nil } }
    #expect(states == [1, 2])
    try await hands.click(at: CGPoint(x: 50, y: 50), button: .right, count: 1, modifiers: [])
    #expect(poster.events.contains(.mouse(.rightMouseDown, CGPoint(x: 50, y: 50), .right, clickState: 1, flags: [])))
    #expect(poster.nothingHeld)
}

@Test func commandClickHoldsCommandAroundTheClick() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 50, y: 50))
    let hands = makeHands(poster)
    try await hands.click(at: CGPoint(x: 50, y: 50), button: .left, count: 1, modifiers: [.command])
    let events = poster.events.filter { if case .mouse(.mouseMoved, _, _, _, _) = $0 { return false } else { return true } }
    #expect(events.first == .key(55, down: true, flags: .maskCommand))
    #expect(events.contains(.mouse(.leftMouseDown, CGPoint(x: 50, y: 50), .left, clickState: 1, flags: .maskCommand)))
    #expect(events.last == .key(55, down: false, flags: []))
}

// MARK: Drag

@Test func dragHoldsTheButtonWhileGliding() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 10, y: 10))
    let hands = makeHands(poster)
    try await hands.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100), duration: 0.15)
    let events = poster.events
    let down = events.firstIndex(of: .mouse(.leftMouseDown, CGPoint(x: 100, y: 100), .left, clickState: 1, flags: []))!
    let dragged = events[(down + 1)...].filter { if case .mouse(.leftMouseDragged, _, _, _, _) = $0 { return true } else { return false } }
    #expect(dragged.count >= 12)
    #expect(events.last == .mouse(.leftMouseUp, CGPoint(x: 400, y: 100), .left, clickState: 1, flags: []))
    #expect(poster.nothingHeld)
}

// MARK: Halt: the user's only brake

@Test func haltDuringAGlideFreezesAndTellsTheCompanionWhereItStopped() async throws {
    let bus = ActivityBus()
    let stream = bus.events()
    let poster = FakePoster(pointer: .zero)
    let hands = makeHands(poster, activity: bus)
    let glide = Task { try await hands.move(to: CGPoint(x: 1400, y: 900), duration: 1.0) }
    try await Task.sleep(nanoseconds: 150_000_000)
    let haltedAt = Date()
    hands.halt()
    await #expect(throws: Halted.self) { try await glide.value }
    #expect(Date().timeIntervalSince(haltedAt) < 0.05)
    let frozen = poster.pointerLocation
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(poster.pointerLocation == frozen)  // nothing more is posted
    #expect(frozen != CGPoint(x: 1400, y: 900))
    #expect(poster.nothingHeld)
    bus.post(.listening)
    var posted: [ActivityEvent] = []
    for await event in stream {
        if event == .listening { break }
        posted.append(event)
    }
    #expect(posted == [.pointerMoving(to: CGPoint(x: 1400, y: 900), duration: 1.0), .pointerMoving(to: frozen, duration: 0)])
}

@Test func haltDuringADragReleasesTheButtonWhereThePointerFroze() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 100, y: 100))
    let hands = makeHands(poster)
    let drag = Task { try await hands.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1300, y: 800), duration: 1.0) }
    try await Task.sleep(nanoseconds: 200_000_000)
    let haltedAt = Date()
    hands.halt()
    await #expect(throws: Halted.self) { try await drag.value }
    #expect(Date().timeIntervalSince(haltedAt) < 0.05)
    guard case .mouse(.leftMouseUp, let point, .left, _, _) = poster.events.last! else {
        Issue.record("the last event must release the button, got \(poster.events.last!)")
        return
    }
    #expect(point == poster.pointerLocation)
    #expect(poster.nothingHeld)
}

@Test func haltDuringLongTypingStopsMidSentence() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.004
    let text = String(repeating: "the quick brown fox ", count: 50)
    let typing = Task { try await hands.typeText(text) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let haltedAt = Date()
    hands.halt()
    await #expect(throws: Halted.self) { try await typing.value }
    #expect(Date().timeIntervalSince(haltedAt) < 0.05)
    let typedAtHalt = poster.typed
    #expect(!typedAtHalt.isEmpty && typedAtHalt.count < text.count)
    #expect(text.hasPrefix(typedAtHalt))
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(poster.typed == typedAtHalt)
    #expect(poster.nothingHeld)
}

/// Every wait inside an action is halt-aware: a one-second pause still stops within 50 ms.
@Test(arguments: ["drag hold", "click hold", "between clicks", "media key settle", "between characters", "between scroll events"])
func haltDuringEveryKindOfPause(_ pause: String) async throws {
    let poster = FakePoster(pointer: CGPoint(x: 200, y: 200))
    let hands = makeHands(poster)
    let action: Task<Void, Error>
    switch pause {
    case "drag hold":
        hands.dragHoldInterval = 1
        action = Task { try await hands.drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 600, y: 200), duration: nil) }
    case "click hold":
        hands.clickHoldInterval = 1
        action = Task { try await hands.click(at: CGPoint(x: 200, y: 200)) }
    case "between clicks":
        hands.multiClickInterval = 1
        action = Task { try await hands.click(at: CGPoint(x: 200, y: 200), button: .left, count: 2, modifiers: []) }
    case "media key settle":
        hands.hardwareKeySettle = 1
        action = Task { try await hands.key("play_pause") }
    case "between characters":
        hands.typingInterval = 1
        action = Task { try await hands.typeText("abc") }
    default:
        hands.scrollInterval = 1
        action = Task { try await hands.scroll(dx: 0, dy: 10, at: nil) }
    }
    try await Task.sleep(nanoseconds: 200_000_000)  // well inside the one-second pause
    let haltedAt = Date()
    hands.halt()
    await #expect(throws: Halted.self) { try await action.value }
    #expect(Date().timeIntervalSince(haltedAt) < 0.05, "\(pause)")
    #expect(poster.nothingHeld, "\(pause)")
}

@Test func haltDuringAShortcutReleasesModifiers() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    poster.onEvent = { [weak hands] event in
        if case .key(55, true, _) = event { hands?.halt() }  // the moment Command goes down
    }
    await #expect(throws: Halted.self) { try await hands.key("cmd+shift+t") }
    #expect(!poster.keyDowns.contains { $0.code == 17 })  // T was never pressed
    #expect(poster.nothingHeld)
}

@Test func haltDoesNotPostToTheCompanion() async throws {
    // The task runner owns `.halted`; one spoken stop must reach the companion once.
    let bus = ActivityBus()
    let hands = makeHands(FakePoster(), activity: bus)
    let posted = await activity(of: bus) { hands.halt() }
    #expect(posted.isEmpty)
}

@Test func whileHaltedEveryActionRefusesAndResumeClearsIt() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.halt()
    #expect(hands.isHalted)
    await #expect(throws: Halted.self) { try await hands.key("return") }
    await #expect(throws: Halted.self) { try await hands.typeText("hi") }
    #expect(poster.events.isEmpty)
    hands.resume()
    #expect(!hands.isHalted)
    try await hands.key("return")
    #expect(poster.keyDowns.map(\.code) == [36])
}

@Test func aHaltIsNotLostWhenResumeComesBeforeTheNextStep() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.01
    // Halt and resume straight away, between two characters.
    poster.onEvent = { [weak hands] event in
        if case .typedKey(_, "c", true, _) = event {
            hands?.halt()
            hands?.resume()
        }
    }
    await #expect(throws: Halted.self) { try await hands.typeText("abcdefghij") }
    #expect(poster.typed == "abc")
    poster.onEvent = nil
    try await hands.typeText("ok")  // an action requested after the resume runs
    #expect(poster.typed == "abcok")
}

@Test func actionsQueuedBeforeAHaltAreHaltedEvenIfResumedBeforeTheyStart() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.01
    let first = Task { try await hands.typeText(String(repeating: "a", count: 40)) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let queued = Task { try await hands.typeText("queued") }
    try await Task.sleep(nanoseconds: 20_000_000)
    hands.halt()
    hands.resume()
    await #expect(throws: Halted.self) { try await first.value }
    await #expect(throws: Halted.self) { try await queued.value }
    #expect(!poster.typed.contains("q"))
}

@Test func aCancelledCallerLeavesTheQueueAtOnce() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.01
    let long = Task { try await hands.typeText(String(repeating: "x", count: 200)) }  // about 2 s
    try await Task.sleep(nanoseconds: 30_000_000)
    let waiting = Task { try await hands.key("return") }
    try await Task.sleep(nanoseconds: 30_000_000)
    let cancelledAt = Date()
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(Date().timeIntervalSince(cancelledAt) < 0.05)
    #expect(!poster.keyDowns.contains { $0.code == 36 })  // its Return never happened
    hands.halt()
    _ = try? await long.value
}

@Test func swiftTaskCancellationAlsoStopsTheHands() async throws {
    let poster = FakePoster(pointer: .zero)
    let hands = makeHands(poster)
    let glide = Task { try await hands.move(to: CGPoint(x: 1000, y: 0), duration: 1.0) }
    try await Task.sleep(nanoseconds: 100_000_000)
    glide.cancel()
    await #expect(throws: (any Error).self) { try await glide.value }
    #expect(poster.pointerLocation.x < 1000)
    #expect(poster.nothingHeld)
}

// MARK: Stuck keys

@Test func creatingTheHandsReleasesAnythingLeftHeld() {
    let poster = FakePoster(pointer: CGPoint(x: 30, y: 40))
    poster.simulateStuck(button: .left, modifiers: [.maskCommand, .maskShift])  // a crashed earlier run
    _ = makeHands(poster)
    #expect(poster.events.contains(.mouse(.leftMouseUp, CGPoint(x: 30, y: 40), .left, clickState: 1, flags: [])))
    #expect(poster.events.contains(.key(55, down: false, flags: .maskShift)))
    #expect(poster.events.contains(.key(56, down: false, flags: [])))
    #expect(poster.heldButtons.isEmpty && poster.heldModifierFlags.isEmpty)
}

@Test func aHaltReleasesWhatTheSystemStillHolds() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.01
    let typing = Task { try await hands.typeText("abcdefghijklmnop") }
    try await Task.sleep(nanoseconds: 40_000_000)
    poster.simulateStuck(modifiers: .maskControl)  // something else left Control down
    hands.halt()
    _ = try? await typing.value
    #expect(poster.heldModifierFlags.isEmpty)
    #expect(poster.events.contains(.key(59, down: false, flags: [])))
}

@Test func releaseEverythingIsPublicAndSafeWhenNothingIsHeld() {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.releaseEverything()
    #expect(poster.events.isEmpty)
}

// MARK: Typing

@Test func typeTextRefusesALineBreakUnlessAllowedAndTypesNothing() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    for text in ["hello\nworld", "a\r\nb", "x\u{2028}y"] {
        await #expect(throws: SpeakableError.self) { try await hands.typeText(text, allowReturn: false) }
    }
    #expect(poster.events.isEmpty)  // not even the first word was typed
    try await hands.typeText("hello\nworld", allowReturn: true)
    #expect(poster.typed == "helloworld")
    #expect(poster.keyDowns.map(\.code) == [36])
}

@Test func charactersOnTheLayoutAreTypedWithTheirRealKeys() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    try await hands.typeText("Hi a!")
    let downs = poster.events.filter { if case .typedKey(_, _, true, _) = $0 { return true } else { return false } }
    #expect(downs == [
        .typedKey(4, "H", down: true, flags: .maskShift),  // the H key with Shift, carrying "H"
        .typedKey(34, "i", down: true, flags: []),
        .typedKey(49, " ", down: true, flags: []),
        .typedKey(0, "a", down: true, flags: []),
        .typedKey(18, "!", down: true, flags: .maskShift),
    ])
    poster.clear()
    let azerty = makeHands(poster, layout: AzertyLayout())
    try await azerty.typeText("a")
    #expect(poster.events.first == .typedKey(12, "a", down: true, flags: []))  // the A key is where US has Q
}

@Test func charactersWithNoKeyAreTypedAsTextOnly() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    let text = "Café — 你好 👋🏽 👨‍👩‍👧 “q” é"
    try await hands.typeText(text)
    #expect(poster.typed == text)
    let textOnly = poster.events.compactMap { if case .text(let piece, true) = $0 { return piece } else { return nil } }
    #expect(textOnly.contains("é") && textOnly.contains("👨‍👩‍👧") && textOnly.contains("👋🏽") && textOnly.contains("你"))
    #expect(!textOnly.contains("C") && !textOnly.contains("a"))  // those had real keys
    #expect(poster.keyDowns.isEmpty)  // no Return, no shortcuts
    #expect(poster.nothingHeld)
}

@Test func typeTextTypesTabAsTheTabKey() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    try await hands.typeText("a\tb")
    #expect(poster.typed == "ab")
    #expect(poster.keyDowns.map(\.code) == [48])
}

@Test func typingPaceDefaultsToAFastHumanTypist() {
    let hands = SystemHands(poster: FakePoster(), layout: USKeyboardLayout(), activity: ActivityBus())
    #expect(hands.typingInterval == 0.04)
    #expect(hands.clickHoldInterval == 0.03)
}

@Test func longEmojiSequencesAreSplitWithinTheEventLimit() {
    #expect(SystemHands.eventSizedPieces(of: Character("👨‍👩‍👧‍👦")) == ["👨‍👩‍👧‍👦"])
    let long = Character("e" + String(repeating: "\u{301}", count: 30))
    let pieces = SystemHands.eventSizedPieces(of: long)
    #expect(pieces.allSatisfy { $0.utf16.count <= 20 })
    #expect(pieces.joined() == String(long))
}

// MARK: Permission

@Test func missingAccessibilityIsASpokenError() async throws {
    let poster = FakePoster()
    poster.trusted = false
    let hands = makeHands(poster)
    do {
        try await hands.click(at: CGPoint(x: 10, y: 10))
        Issue.record("should have thrown")
    } catch let error as SpeakableError {
        #expect(error.spokenMessage.contains("Accessibility"))
        #expect(error.spokenMessage.hasSuffix("."))
    }
    #expect(poster.events.isEmpty)
}

// MARK: Scroll

@Test func scrollFlipsToQuartzSignsAndSpreadsLinesOverAFewEvents() async throws {
    let bus = ActivityBus()
    let poster = FakePoster(pointer: CGPoint(x: 10, y: 10))
    let hands = makeHands(poster, activity: bus)
    let posted = try await activity(of: bus) { try await hands.scroll(dx: 0, dy: 10, at: nil) }
    let scrolls = poster.events.compactMap { if case .scroll(let vertical, let horizontal) = $0 { return (vertical, horizontal) } else { return nil } }
    #expect(scrolls.count == 10)
    #expect(scrolls.map(\.0).reduce(0, +) == -10)  // positive dy (down) is negative for Quartz
    #expect(poster.moves.isEmpty)
    #expect(posted == [.scrolled])
}

@Test func longScrollUsesAtMostTwelveEventsAndGlidesToTheSpotFirst() async throws {
    let poster = FakePoster(pointer: CGPoint(x: 10, y: 10))
    let hands = makeHands(poster)
    try await hands.scroll(dx: -7, dy: -5000, at: CGPoint(x: 600, y: 400))
    #expect(poster.moves.last == CGPoint(x: 600, y: 400))
    let scrolls = poster.events.compactMap { if case .scroll(let vertical, let horizontal) = $0 { return (vertical, horizontal) } else { return nil } }
    #expect(scrolls.count == 12)
    #expect(scrolls.map(\.0).reduce(0, +) == 5000)
    #expect(scrolls.map(\.1).reduce(0, +) == 7)
}

// MARK: One action at a time

@Test func concurrentCallsDoNotInterleave() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    async let first: Void = hands.typeText("aaaaaaaaaa")
    async let second: Void = hands.typeText("bbbbbbbbbb")
    _ = try await (first, second)
    let typed = poster.typed
    #expect(typed == "aaaaaaaaaabbbbbbbbbb" || typed == "bbbbbbbbbbaaaaaaaaaa")
}

/// Records when events happen, for checking holds.
final class TimeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Date] = []
    func add() { lock.withLock { times.append(Date()) } }
    var gaps: [TimeInterval] {
        lock.withLock { zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) } }
    }
}

@Test func pacedTypingUsesTheIntervalAsked() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    hands.typingInterval = 0.02
    let started = Date()
    try await hands.typeText("abcdefghij", allowReturn: false, characterInterval: 0.001)
    let quick = Date().timeIntervalSince(started)
    let normalStart = Date()
    try await hands.typeText("abcdefghij")
    let normal = Date().timeIntervalSince(normalStart)
    #expect(quick < 0.1 && normal >= 0.19)
    #expect(poster.typed == "abcdefghijabcdefghij")
}
