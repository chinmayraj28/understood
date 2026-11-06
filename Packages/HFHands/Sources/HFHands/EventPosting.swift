import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HFCore

/// The only place the hands touch the system. `SystemHands` speaks to this
/// protocol. `QuartzEventPoster` posts real events; `RecordingEventPoster`
/// records them, so any package can test against the real `SystemHands`
/// without moving the user's pointer.
public protocol EventPosting: AnyObject, Sendable {
    /// Mouse moved, dragged, down or up, at a point in screen points (top-left origin).
    func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, flags: CGEventFlags)
    /// A key press by key code, carrying no text (shortcuts, Return, arrows, modifiers).
    func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags)
    /// A key press by key code that also carries the text it types, for characters
    /// the keyboard layout can produce: key handlers see the real key, text fields
    /// get the exact text.
    func postTypedKey(code: CGKeyCode, text: String, down: Bool, flags: CGEventFlags)
    /// A key press that carries text but no real key (key code 0), for characters
    /// no key on the layout produces: emoji, other scripts.
    func postText(_ text: String, down: Bool)
    /// Line-based scroll in Quartz's own sign convention: positive `vertical` scrolls up.
    func postScroll(vertical: Int32, horizontal: Int32)
    /// A top-row hardware key (volume, media, brightness) by NX_KEYTYPE number.
    func postHardwareKey(_ key: Int32, down: Bool, flags: CGEventFlags)

    /// Where the real pointer is now.
    var pointerLocation: CGPoint { get }
    /// The main display in screen points.
    var mainDisplayBounds: CGRect { get }
    /// False when macOS would drop our events (Accessibility not granted).
    var canPostEvents: Bool { get }
    /// Mouse buttons the system believes are held down right now.
    var heldButtons: [CGMouseButton] { get }
    /// Modifier flags the system believes are held down right now.
    var heldModifierFlags: CGEventFlags { get }
}

/// Posts real events through Quartz at the HID event tap, where hardware events
/// enter, so they reach the focused app and trigger system shortcuts such as
/// Command+Space and Command+Tab.
public final class QuartzEventPoster: EventPosting, @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    public func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    public func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    public func postTypedKey(code: CGKeyCode, text: String, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        let units = Array(text.utf16)
        event.flags = flags
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.post(tap: .cghidEventTap)
    }

    public func postText(_ text: String, down: Bool) {
        // Key code 0 is a placeholder: text fields read the attached text.
        postTypedKey(code: 0, text: text, down: down, flags: [])
    }

    public func postScroll(vertical: Int32, horizontal: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    public func postHardwareKey(_ key: Int32, down: Bool, flags: CGEventFlags) {
        // Media, volume and brightness keys are "system defined" events (subtype 8)
        // with the key number and state packed into data1: 0xA is down, 0xB is up.
        let state: Int = down ? 0xA : 0xB
        let modifierBits = UInt(state << 8) | UInt(flags.rawValue & 0xFFFF_0000)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierBits),
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
            data1: (Int(key) << 16) | (state << 8), data2: -1)
        else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    public var pointerLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public var mainDisplayBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// The exact check for posting events; AXIsProcessTrusted is reported alongside in Permissions.
    public var canPostEvents: Bool { CGPreflightPostEventAccess() }

    public var heldButtons: [CGMouseButton] {
        [CGMouseButton.left, .right, .center].filter { CGEventSource.buttonState(.hidSystemState, button: $0) }
    }

    public var heldModifierFlags: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }
}

/// Records every event instead of posting it, and plays the part of the system
/// (it moves its pretend pointer and tracks what is held). For tests, in this
/// package and in others that need a real `SystemHands` without touching the Mac:
///
///     let poster = RecordingEventPoster()
///     let hands = SystemHands(poster: poster, layout: USKeyboardLayout(), activity: ActivityBus())
public final class RecordingEventPoster: EventPosting, @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case mouse(CGEventType, CGPoint, CGMouseButton, clickState: Int, flags: CGEventFlags)
        case key(CGKeyCode, down: Bool, flags: CGEventFlags)
        case typedKey(CGKeyCode, String, down: Bool, flags: CGEventFlags)
        case text(String, down: Bool)
        case scroll(vertical: Int32, horizontal: Int32)
        case hardware(Int32, down: Bool, flags: CGEventFlags)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var pointer: CGPoint
    private var buttonsDown: Set<UInt32> = []
    private var modifiersDown: CGEventFlags = []

    /// The pretend main display.
    public var bounds = CGRect(x: 0, y: 0, width: 1470, height: 956)
    /// Set false to pretend Accessibility is missing.
    public var trusted = true
    /// Set true to pretend the pointer is blocked (a revoked permission, or
    /// someone holding the mouse): moves are recorded but the pointer stays put.
    public var dropsPointerMoves = false
    /// Called after each event is recorded, so a test can halt mid-action.
    public var onEvent: (@Sendable (Event) -> Void)?

    public init(pointer: CGPoint = CGPoint(x: 100, y: 100)) { self.pointer = pointer }

    /// Everything posted so far, in order.
    public var events: [Event] { lock.withLock { recorded } }

    public func clear() { lock.withLock { recorded.removeAll() } }

    /// Pretend something outside the hands holds a button or modifier (a crashed run).
    public func simulateStuck(button: CGMouseButton? = nil, modifiers: CGEventFlags = []) {
        lock.withLock {
            if let button { buttonsDown.insert(button.rawValue) }
            modifiersDown.formUnion(modifiers)
        }
    }

    private func record(_ event: Event) {
        lock.withLock { recorded.append(event) }
        onEvent?(event)
    }

    public func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        lock.withLock {
            if !dropsPointerMoves { pointer = point }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { buttonsDown.insert(button.rawValue) }
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) { buttonsDown.remove(button.rawValue) }
        }
        record(.mouse(type, point, button, clickState: clickState, flags: flags))
    }

    public func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        if let modifier = Self.modifierFlag(forKeyCode: code) {
            lock.withLock { if down { modifiersDown.formUnion(modifier) } else { modifiersDown.subtract(modifier) } }
        }
        record(.key(code, down: down, flags: flags))
    }

    public func postTypedKey(code: CGKeyCode, text: String, down: Bool, flags: CGEventFlags) {
        record(.typedKey(code, text, down: down, flags: flags))
    }

    public func postText(_ text: String, down: Bool) { record(.text(text, down: down)) }
    public func postScroll(vertical: Int32, horizontal: Int32) { record(.scroll(vertical: vertical, horizontal: horizontal)) }
    public func postHardwareKey(_ key: Int32, down: Bool, flags: CGEventFlags) { record(.hardware(key, down: down, flags: flags)) }

    public var pointerLocation: CGPoint { lock.withLock { pointer } }
    public var mainDisplayBounds: CGRect { bounds }
    public var canPostEvents: Bool { trusted }

    public var heldButtons: [CGMouseButton] {
        lock.withLock { buttonsDown.sorted().compactMap { CGMouseButton(rawValue: $0) } }
    }

    public var heldModifierFlags: CGEventFlags { lock.withLock { modifiersDown } }

    static func modifierFlag(forKeyCode code: CGKeyCode) -> CGEventFlags? {
        switch code {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return nil
        }
    }

    // MARK: Views of what was recorded

    /// Every pointer position a glide or drag posted.
    public var moves: [CGPoint] {
        events.compactMap {
            if case .mouse(let type, let point, _, _, _) = $0, type == .mouseMoved || type == .leftMouseDragged { return point }
            return nil
        }
    }

    /// The text typed, from typed keys and text-only events alike.
    public var typed: String {
        events.compactMap {
            switch $0 {
            case .typedKey(_, let text, true, _), .text(let text, true): return text
            default: return nil
            }
        }.joined()
    }

    /// Key codes pressed without text (shortcuts, Return, Tab, modifiers excluded).
    public var keyDowns: [(code: CGKeyCode, flags: CGEventFlags)] {
        events.compactMap { if case .key(let code, true, let flags) = $0 { return (code, flags) } else { return nil } }
    }

    /// True when every key, typed key, text event and mouse button that went down also came up.
    public var nothingHeld: Bool {
        var keys: [CGKeyCode: Int] = [:]
        var buttons = 0
        var text = 0
        for event in events {
            switch event {
            case .key(let code, let down, _), .typedKey(let code, _, let down, _): keys[code, default: 0] += down ? 1 : -1
            case .text(_, let down): text += down ? 1 : -1
            case .mouse(let type, _, _, _, _):
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { buttons += 1 }
                if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) { buttons -= 1 }
            default: break
            }
        }
        return keys.values.allSatisfy { $0 <= 0 } && buttons <= 0 && text == 0 && heldButtons.isEmpty && heldModifierFlags.isEmpty
    }
}
