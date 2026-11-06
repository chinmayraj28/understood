import Carbon
import CoreGraphics
import Foundation
import HFCore

// Every key name `Hands.key(_:)` accepts. Names are case-insensitive; join a
// shortcut with "+" ("cmd+shift+t") or spaces ("command shift t"); underscores
// and spaces are interchangeable ("page_down" = "page down").
//
// Modifiers   cmd / command / ⌘, shift / ⇧, option / opt / alt / ⌥,
//             ctrl / control / ⌃, fn / function / globe
// Named keys  return, enter, tab, space, delete / backspace, forward_delete,
//             escape / esc, up, down, left, right (also "up arrow", "arrow up"),
//             home, end, page_up, page_down, f1 ... f12
// Hardware    volume_up, volume_down, mute, play_pause, next_track,
//             previous_track, brightness_up, brightness_down
//             (the keys on the top row; with shift+option they move in quarter steps)
// Characters  any single character on the current keyboard layout: a, 7, =, [, ?
// Spoken      plus / equals, minus / dash / hyphen, comma, period / dot / full stop,
//             slash, backslash, semicolon, quote / apostrophe, backtick / grave,
//             left_bracket, right_bracket, question_mark
//
// Letter keys are looked up in the CURRENT keyboard layout, because key codes
// are physical positions: with a fixed US table, "cmd+a" on a French AZERTY
// keyboard would press the key that types "q" there, which is Command+Q (quit).

/// One key press with modifiers held: Command+Shift+T, or a hardware key such as volume up.
struct Chord: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        /// An ordinary key, by virtual key code, plus flags real hardware sets for it
        /// (arrow keys carry the function and numeric-pad flags).
        case code(CGKeyCode, extraFlags: CGEventFlags)
        /// A top-row hardware key, by its NX_KEYTYPE number. Posted as a system-defined event.
        case hardware(Int32)
    }

    var modifiers: [KeyModifier]  // in `KeyTable.modifierOrder`
    var key: Key
    /// Canonical name, e.g. "cmd+shift+t" or "volume_up".
    var label: String

    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if case .code(_, let extra) = key { flags.formUnion(extra) }
        for modifier in modifiers { flags.formUnion(KeyTable.flag(for: modifier)) }
        return flags
    }

    var isReturn: Bool {
        if case .code(let code, _) = key { return KeyTable.returnKeyCodes.contains(code) }
        return false
    }
}

extension CGEventFlags: @retroactive @unchecked Sendable {}

/// Which key code types a character on the keyboard layout in use right now.
public protocol KeyboardLayout: Sendable {
    /// For shortcuts: the key code and whether Shift is needed, falling back to the
    /// US position of a character the layout lacks. Nil if no key is known.
    func key(for character: Character) -> (code: CGKeyCode, needsShift: Bool)?
    /// For typing: the key that really produces this character on this layout,
    /// with no fallback. Nil means type it as text only (emoji, other scripts).
    func typingKey(for character: Character) -> (code: CGKeyCode, needsShift: Bool)?
}

enum KeyTable {
    static let modifierOrder: [KeyModifier] = [.control, .option, .shift, .command, .function]

    static let modifierKeyCodes: [KeyModifier: CGKeyCode] = [
        .command: 55, .shift: 56, .option: 58, .control: 59, .function: 63,
    ]

    static func flag(for modifier: KeyModifier) -> CGEventFlags {
        switch modifier {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .function: return .maskSecondaryFn
        }
    }

    static let modifierNames: [String: KeyModifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control,
        "fn": .function, "function": .function, "globe": .function,
    ]

    private static let arrowFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]

    /// Keys that are the same on every layout.
    static let namedKeys: [String: (CGKeyCode, CGEventFlags)] = [
        "return": (36, []), "enter": (36, []), "tab": (48, []), "space": (49, []),
        "delete": (51, []), "backspace": (51, []), "forward delete": (117, .maskSecondaryFn),
        "escape": (53, []), "esc": (53, []),
        "left": (123, arrowFlags), "right": (124, arrowFlags), "down": (125, arrowFlags), "up": (126, arrowFlags),
        "home": (115, .maskSecondaryFn), "end": (119, .maskSecondaryFn),
        "page up": (116, .maskSecondaryFn), "page down": (121, .maskSecondaryFn),
        "f1": (122, .maskSecondaryFn), "f2": (120, .maskSecondaryFn), "f3": (99, .maskSecondaryFn),
        "f4": (118, .maskSecondaryFn), "f5": (96, .maskSecondaryFn), "f6": (97, .maskSecondaryFn),
        "f7": (98, .maskSecondaryFn), "f8": (100, .maskSecondaryFn), "f9": (101, .maskSecondaryFn),
        "f10": (109, .maskSecondaryFn), "f11": (103, .maskSecondaryFn), "f12": (111, .maskSecondaryFn),
    ]

    /// Other ways people say the named keys.
    static let keyAliases: [String: String] = [
        "spacebar": "space", "space bar": "space", "back space": "backspace", "del": "delete",
        "up arrow": "up", "arrow up": "up", "down arrow": "down", "arrow down": "down",
        "left arrow": "left", "arrow left": "left", "right arrow": "right", "arrow right": "right",
        "pageup": "page up", "pagedown": "page down", "pgup": "page up", "pgdn": "page down",
        "forward del": "forward delete", "return key": "return", "enter key": "enter",
    ]

    /// Top-row keys, by NX_KEYTYPE number (IOKit's ev_keymap.h).
    static let hardwareKeys: [String: Int32] = [
        "volume up": 0, "volume down": 1, "brightness up": 2, "brightness down": 3, "mute": 7,
        "play pause": 16, "next track": 17, "previous track": 18,
    ]

    static let hardwareAliases: [String: String] = [
        "sound up": "volume up", "sound down": "volume down", "volume mute": "mute",
        "play": "play pause", "pause": "play pause", "playpause": "play pause",
        "next": "next track", "previous": "previous track", "prev track": "previous track",
    ]

    /// Spoken punctuation, mapped to the character on the key.
    static let symbolNames: [String: Character] = [
        "plus": "=", "equals": "=", "equal": "=", "minus": "-", "dash": "-", "hyphen": "-",
        "comma": ",", "period": ".", "dot": ".", "full stop": ".", "slash": "/",
        "forward slash": "/", "backslash": "\\", "back slash": "\\", "semicolon": ";",
        "quote": "'", "apostrophe": "'", "backtick": "`", "back tick": "`", "grave": "`",
        "left bracket": "[", "open bracket": "[", "right bracket": "]", "close bracket": "]",
        "question mark": "?",
    ]

    /// Return and keypad Enter: both send in chat apps.
    static let returnKeyCodes: Set<CGKeyCode> = [36, 76]

    /// Words that carry no meaning in "press command and s".
    static let fillerWords: Set<String> = ["press", "then", "and", "key", "keys", "hit", "the", "tap"]

    // MARK: Parsing

    /// Splits a combo or spoken sequence into lowercase words.
    static func words(_ text: String) -> [String] {
        var text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var trailingPlus = false
        if text.hasSuffix("++") {  // "cmd++" means Command and the plus key
            trailingPlus = true
            text.removeLast(2)
        }
        var separated = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : " "
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            switch character {
            case "," where previous == "+", "_" where previous == "+":
                separated.append(" \(character)")  // "cmd+," is Command and the comma key
            case "+", ",", "_":
                separated.append(characters.count == 1 ? character : " ")
            case "-" where previous.isLetter && (next.isLetter || next.isNumber):
                separated.append(" ")  // "cmd-shift-t", but "cmd -" keeps the minus key
            default:
                separated.append(character)
            }
        }
        var result = separated.split(whereSeparator: \.isWhitespace).map(String.init)
        if trailingPlus { result.append("=") }
        return result
    }

    private enum Token { case modifier(KeyModifier), named(String), hardware(String), character(Character) }

    private static func token(in words: [String], at index: Int) -> (Token, Int)? {
        for length in [3, 2, 1] where index + length <= words.count {
            let phrase = words[index..<(index + length)].joined(separator: " ")
            if let modifier = modifierNames[phrase] { return (.modifier(modifier), length) }
            let named = keyAliases[phrase] ?? phrase
            if namedKeys[named] != nil { return (.named(named), length) }
            let hardware = hardwareAliases[phrase] ?? phrase
            if hardwareKeys[hardware] != nil { return (.hardware(hardware), length) }
            if let symbol = symbolNames[phrase] { return (.character(symbol), length) }
        }
        let word = words[index]
        if word.count == 1, let character = word.first { return (.character(character), 1) }
        return nil
    }

    /// Parses keys into chords. Modifiers collect until a key arrives, which
    /// completes one chord, so "command shift t" is one chord and
    /// "down down enter" is three. Throws a SpeakableError naming what was wrong.
    static func parse(_ text: String, layout: KeyboardLayout) throws -> [Chord] {
        let words = words(text).filter { !fillerWords.contains($0) }
        guard !words.isEmpty else { throw SpeakableError("Tell me which keys to press.") }
        var chords: [Chord] = []
        var held: [KeyModifier] = []
        var index = 0
        while index < words.count {
            guard let (token, used) = token(in: words, at: index) else {
                throw SpeakableError("I don't know the key \"\(words[index])\".")
            }
            index += used
            let key: Chord.Key
            let name: String
            switch token {
            case .modifier(let modifier):
                if !held.contains(modifier) { held.append(modifier) }
                continue
            case .named(let named):
                let (code, extra) = namedKeys[named]!
                key = .code(code, extraFlags: extra)
                name = named.replacingOccurrences(of: " ", with: "_")
            case .hardware(let hardware):
                key = .hardware(hardwareKeys[hardware]!)
                name = hardware.replacingOccurrences(of: " ", with: "_")
            case .character(let character):
                guard let found = layout.key(for: character) else {
                    throw SpeakableError("There's no \"\(character)\" key on this keyboard.")
                }
                key = .code(found.code, extraFlags: [])
                name = String(character).lowercased()
                if found.needsShift, !held.contains(.shift) { held.append(.shift) }
            }
            let ordered = modifierOrder.filter(held.contains)
            let label = (ordered.map(shortName) + [name]).joined(separator: "+")
            chords.append(Chord(modifiers: ordered, key: key, label: label))
            held = []
        }
        if !held.isEmpty {
            let names = held.map(\.rawValue).joined(separator: " and ")
            throw SpeakableError("Tell me which key to press with \(names).")
        }
        return chords
    }

    static func shortName(_ modifier: KeyModifier) -> String {
        switch modifier {
        case .command: return "cmd"
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "ctrl"
        case .function: return "fn"
        }
    }
}

// MARK: - Keyboard layouts

/// US ANSI key positions: the fallback when the layout cannot be read, and for
/// shortcut characters the layout lacks (such as "[" on a German keyboard),
/// because app shortcuts like Command+[ are bound to that physical key.
public struct USKeyboardLayout: KeyboardLayout {
    public init() {}

    static let codes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
    ]
    static let shifted: [Character: Character] = [
        "?": "/", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "~": "`",
    ]

    public func key(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        let lower = Character(character.lowercased())
        if let code = Self.codes[lower] { return (code, false) }
        if let base = Self.shifted[character], let code = Self.codes[base] { return (code, true) }
        return nil
    }

    public func typingKey(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        if let code = Self.codes[character] { return (code, false) }
        if character.isUppercase, let code = Self.codes[Character(character.lowercased())] { return (code, true) }
        if let base = Self.shifted[character], let code = Self.codes[base] { return (code, true) }
        return nil
    }
}

/// Reads the layout the user has selected, through UCKeyTranslate, and falls
/// back to US positions for characters it lacks. Refreshed every 10 seconds so
/// a layout switch is picked up.
public final class LiveKeyboardLayout: KeyboardLayout, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: (built: Date, map: [Character: (CGKeyCode, Bool)])?

    public init() {}

    public func typingKey(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        currentMap()[character]
    }

    public func key(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        let map = currentMap()
        if let found = map[character] ?? map[Character(character.lowercased())] { return found }
        return USKeyboardLayout().key(for: character)
    }

    private func currentMap() -> [Character: (CGKeyCode, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.built) < 10 { return cache.map }
        let map = Self.readLayout()
        cache = (Date(), map)
        return map
    }

    static func readLayout() -> [Character: (CGKeyCode, Bool)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var map: [Character: (CGKeyCode, Bool)] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {  // unshifted first, so it wins
                for code in 0..<128 {
                    // Skip Return, Tab, Space, Delete, Escape and the keypad.
                    if [36, 48, 49, 51, 53, 76].contains(code) || (65...92).contains(code) { continue }
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) : 0,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length,
                        &characters)
                    guard status == noErr, length == 1,
                        let scalar = Unicode.Scalar(characters[0]), scalar.properties.isPrintable() else { continue }
                    let character = Character(scalar)
                    if map[character] == nil { map[character] = (CGKeyCode(code), shift) }
                }
            }
        }
        return map
    }
}

private extension Unicode.Scalar.Properties {
    func isPrintable() -> Bool { !(generalCategory == .control || generalCategory == .format) && !isWhitespace }
}
