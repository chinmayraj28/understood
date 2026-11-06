import AppKit
import ApplicationServices
import Foundation
import HFCore
import HFEyes

// Throwaway (5 Nov 2026). Read-only apart from Command+Space, five typed letters and Escape.

func say(_ text: String) { print(text); fflush(stdout) }
func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
let source = CGEventSource(stateID: .hidSystemState)

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
func type(_ text: String) async {
    for character in text {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
        await sleep(0.03)
    }
}
func show(_ name: String, _ info: UIElementInfo?) {
    guard let info else { say("\(name): nil"); return }
    say("\(name): role \(info.role) (\"\(info.role.rawValue)\"), label \"\(info.label)\", identifier \"\(info.identifier)\", app \"\(info.app)\", window \"\(info.window)\", enabled \(info.isEnabled), frame \(info.frame)")
}
func raw() {
    // The focused element's raw attributes, for the record.
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
        let element = focused else { say("raw: no system-wide focused element"); return }
    func text(_ name: String) -> String {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement, name as CFString, &value)
        return (value as? String) ?? ""
    }
    var pid: pid_t = 0
    AXUIElementGetPid(element as! AXUIElement, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    say("raw: role \(text(kAXRoleAttribute)) subrole \(text(kAXSubroleAttribute)) description \"\(text(kAXDescriptionAttribute))\" placeholder \"\(text(kAXPlaceholderValueAttribute))\" identifier \"\(text(kAXIdentifierAttribute))\" process \(app?.localizedName ?? "?") (\(app?.bundleIdentifier ?? "?"))")
    say("NSWorkspace front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
}

guard AXIsProcessTrusted() else { say("STOPPED: no Accessibility permission"); exit(2) }
let labels = AccessibilityLabels()
say("before: front \(await labels.frontmost())")

key(49, flags: .maskCommand)  // Command+Space
await sleep(0.8)
let front1 = await labels.frontmost()
say("Spotlight open, empty: front app \"\(front1.app)\", window \"\(front1.window)\"")
show("focused (empty)", await labels.focusedElement())
raw()

await type("Notes")
await sleep(0.8)
let front2 = await labels.frontmost()
say("after typing Notes: front app \"\(front2.app)\", window \"\(front2.window)\"")
show("focused (Notes typed)", await labels.focusedElement())
raw()
let action = await labels.keyAction(KeyChord(key: "return"))
say("ScreenAction: frontApp \"\(action.frontApp)\", frontWindow \"\(action.frontWindow)\", targetUnknown \(action.isTargetUnknown)")
say("description: \(action.description)")

key(53)  // Escape: close Spotlight without launching anything
await sleep(0.6)
say("after Escape: front \(await labels.frontmost())")
