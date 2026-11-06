import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFHands

private func parse(_ text: String, layout: KeyboardLayout = USKeyboardLayout()) throws -> [Chord] {
    try KeyTable.parse(text, layout: layout)
}

@Test(arguments: ["cmd+shift+t", "command shift t", "Command-Shift-T", "shift+cmd+t", "⌘⇧T", "press command shift t"])
func shortcutSpellingsAgree(_ spelling: String) throws {
    let chords = try parse(spelling.replacingOccurrences(of: "⌘⇧", with: "⌘ ⇧ "))
    #expect(chords.count == 1)
    #expect(chords[0].label == "shift+cmd+t")
    #expect(chords[0].key == .code(17, extraFlags: []))
    #expect(chords[0].flags == [.maskShift, .maskCommand])
}

@Test func sequencesSplitWhereAKeyCompletesAChord() throws {
    let chords = try parse("down down enter")
    #expect(chords.map(\.label) == ["down", "down", "enter"])
    #expect(try parse("command a then delete").map(\.label) == ["cmd+a", "delete"])
    #expect(try parse("command and s").map(\.label) == ["cmd+s"])
}

@Test(arguments: [
    ("return", 36), ("enter", 36), ("escape", 53), ("esc", 53), ("tab", 48), ("space", 49), ("backspace", 51),
    ("forward_delete", 117), ("page down", 121), ("page_up", 116), ("up arrow", 126), ("arrow left", 123),
    ("home", 115), ("end", 119), ("f5", 96), ("f12", 111),
])
func namedKeys(_ name: String, _ code: Int) throws {
    let chords = try parse(name)
    #expect(chords.count == 1)
    guard case .code(let parsed, _) = chords[0].key else { Issue.record("not a code key"); return }
    #expect(parsed == CGKeyCode(code))
}

@Test(arguments: [
    ("volume_up", 0), ("volume_down", 1), ("brightness_up", 2), ("brightness_down", 3), ("mute", 7),
    ("play_pause", 16), ("next_track", 17), ("previous_track", 18), ("volume up", 0), ("play", 16),
])
func hardwareKeys(_ name: String, _ number: Int) throws {
    let chords = try parse(name)
    #expect(chords.count == 1)
    #expect(chords[0].key == .hardware(Int32(number)))
    #expect(chords[0].modifiers.isEmpty)
}

@Test func fineVolumeStepCarriesShiftAndOption() throws {
    let chord = try parse("shift+option+volume_up")[0]
    #expect(chord.key == .hardware(0))
    #expect(chord.flags == [.maskShift, .maskAlternate])
    #expect(chord.label == "option+shift+volume_up")
}

@Test func arrowKeysCarryTheFlagsRealHardwareSets() throws {
    let chord = try parse("cmd+up")[0]
    #expect(chord.flags == [.maskCommand, .maskSecondaryFn, .maskNumericPad])
}

@Test func symbolsAndSpokenPunctuation() throws {
    #expect(try parse("cmd+,")[0].key == .code(43, extraFlags: []))
    #expect(try parse("command comma")[0].key == .code(43, extraFlags: []))
    #expect(try parse("cmd+=")[0].label == "cmd+=")
    #expect(try parse("command plus")[0].key == .code(24, extraFlags: []))
    #expect(try parse("cmd -")[0].key == .code(27, extraFlags: []))
    let question = try parse("command question mark")[0]
    #expect(question.key == .code(44, extraFlags: []) && question.modifiers == [.shift, .command])
}

@Test func lettersFollowTheCurrentLayout() throws {
    // On AZERTY the A key is where Q is on a US keyboard. A fixed US table
    // would turn "cmd+a" into Command+Q, which quits the app.
    #expect(try parse("cmd+a", layout: AzertyLayout())[0].key == .code(12, extraFlags: []))
    #expect(try parse("cmd+a")[0].key == .code(0, extraFlags: []))
}

@Test(arguments: ["", "command", "control shift", "blorp", "command banana"])
func badKeysAreSpokenErrors(_ text: String) {
    do {
        _ = try parse(text)
        Issue.record("\(text) should not parse")
    } catch let error as SpeakableError {
        #expect(error.spokenMessage.hasSuffix("."))
        #expect(error.spokenMessage.count < 80)
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Test func returnIsRecognisedAsSending() throws {
    #expect(try parse("return")[0].isReturn)
    #expect(try parse("enter")[0].isReturn)
    #expect(try !parse("shift tab")[0].isReturn)
}

@Test func keyPressesModifiersInOrderAndReleasesInReverse() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    try await hands.key("cmd+shift+t")
    #expect(poster.events == [
        .key(56, down: true, flags: .maskShift),
        .key(55, down: true, flags: [.maskShift, .maskCommand]),
        .key(17, down: true, flags: [.maskShift, .maskCommand]),
        .key(17, down: false, flags: [.maskShift, .maskCommand]),
        .key(55, down: false, flags: .maskShift),
        .key(56, down: false, flags: []),
    ])
}

@Test func hardwareKeysArePostedAsSystemKeys() async throws {
    let poster = FakePoster()
    let hands = makeHands(poster)
    try await hands.key("volume_up")
    #expect(poster.events == [.hardware(0, down: true, flags: []), .hardware(0, down: false, flags: [])])
    try await hands.key("play_pause")
    #expect(poster.events.suffix(2) == [.hardware(16, down: true, flags: []), .hardware(16, down: false, flags: [])])
    #expect(poster.nothingHeld)
}

@Test func liveLayoutReadsLettersWithoutReturnOrSpace() {
    let map = LiveKeyboardLayout.readLayout()
    for letter in "abcdefghijklmnopqrstuvwxyz0123456789" {
        #expect(map[letter] != nil, "missing \(letter)")
    }
    #expect(!map.values.contains { KeyTable.returnKeyCodes.contains($0.0) })
}
