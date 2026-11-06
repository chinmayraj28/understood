import AppKit
import ApplicationServices
import Foundation
import HFCore
import HFEyes
import HFHands

// Throwaway live check (5 Nov 2026). See Package.swift. Every step that could touch the wrong
// place is checked first; on any doubt it stops and says why. Never Return, never Send.

func say(_ text: String) { print(text); fflush(stdout) }
func stop(_ why: String) -> Never { say("STOPPED: \(why)"); exit(2) }
func digits(_ text: String) -> String { text.filter(\.isNumber) }
func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

// MARK: read-only accessibility helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func frame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute)
    else { return .zero }
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(extent as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}
/// The first element below `root` whose AXIdentifier is `identifier` (breadth first, bounded).
func find(_ identifier: String, under root: AXUIElement) -> AXUIElement? {
    var queue = [root]
    var visited = 0
    while !queue.isEmpty, visited < 4000 {
        let element = queue.removeFirst()
        visited += 1
        if text(element, kAXIdentifierAttribute) == identifier { return element }
        queue.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
    }
    return nil
}
func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

// MARK: the check

let contact = Settings.load().testWhatsAppContact
guard !contact.isEmpty, digits(contact).count >= 7 else { stop("TEST_WHATSAPP_CONTACT is not set to a phone number") }
guard let whatsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp").first
else { stop("WhatsApp is not running") }
guard AXIsProcessTrusted() else { stop("no Accessibility permission") }

let hands = SystemHands()
let labels = AccessibilityLabels()
let appElement = AXUIElementCreateApplication(whatsApp.processIdentifier)
let previousApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
say("front app before: \(previousApp)")

// 1. Bring WhatsApp forward like a person: click its Dock icon.
if NSWorkspace.shared.frontmostApplication?.processIdentifier != whatsApp.processIdentifier {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { stop("no Dock") }
    let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
    let lists = (attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    let items = lists.flatMap { (attribute($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    guard let icon = items.first(where: { ControlNamer.clean(text($0, kAXTitleAttribute)) == "WhatsApp" })
    else { stop("WhatsApp is not in the Dock") }
    say("Dock icon: \(await labels.clickAction(at: centre(frame(icon))).description)")
    try await hands.click(at: centre(frame(icon)))
    for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != whatsApp.processIdentifier {
        await sleep(0.1)
    }
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == whatsApp.processIdentifier
else { stop("WhatsApp did not come to the front") }
await sleep(0.5)
guard let window = attribute(appElement, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { stop("no WhatsApp window") }

// 2. The open chat must be the test contact's, and its message box must be empty.
func checkChat() {
    guard let chat = find("ChatMessagesTableView", under: window) else { stop("no chat is open") }
    let description = ControlNamer.clean(text(chat, kAXDescriptionAttribute))
    guard description.hasPrefix("Messages in chat with"), digits(description).hasSuffix(digits(contact).suffix(10))
    else { stop("the open chat is not the test contact's") }
}
checkChat()
say("open chat: the test contact's (checked by digits)")
guard let composer = find("ChatBar_ComposerTextView", under: window) else { stop("no message box") }
guard text(composer, kAXValueAttribute).isEmpty else { stop("the message box already has text (could be the user's draft)") }
if let voice = find("ChatBar_VoiceMessageButton", under: window) {
    say("before typing, at the Send spot: \(await labels.clickAction(at: centre(frame(voice))).description)")
}

// 3. Click the message box and check the keyboard really is there.
try await hands.click(at: centre(frame(composer)))
await sleep(0.4)
let focusInfo = await labels.focusedElement()
say("focus: \(ScreenAction.phrase(for: focusInfo))")
guard focusInfo?.role == .textArea, focusInfo?.label == "Compose message", focusInfo?.app == "WhatsApp"
else { stop("focus is not the message box") }
guard let focused = attribute(appElement, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }),
    text(focused, kAXIdentifierAttribute) == "ChatBar_ComposerTextView"
else { stop("WhatsApp's own focused element is not the message box") }
checkChat()

// 4. Type one harmless word. No newline, so Return can never be pressed.
try await hands.typeText("hello", allowReturn: false)
await sleep(0.6)
guard text(composer, kAXValueAttribute) == "hello" else {
    stop("the word did not land in the message box (box holds \(text(composer, kAXValueAttribute).count) characters)")
}

// 5. Read the Send button's phrase by hit test, without moving the pointer near it.
guard let send = find("ChatBar_SendButton", under: window) else { stop("no Send button appeared") }
let sendPoint = centre(frame(send))
let started = Date()
let sendPhrase = await labels.clickAction(at: sendPoint).description
let took = Date().timeIntervalSince(started) * 1000
say("SEND PHRASE: \(sendPhrase)   [\(String(format: "%.1f", took)) ms]")
if let info = await labels.element(at: sendPoint) {
    say("  element: role \(info.role.rawValue), label \"\(info.label)\", identifier \"\(info.identifier)\", enabled \(info.isEnabled), frame \(info.frame)")
}
say("Return would be judged as: \(await labels.lineBreakAction().description)")

// 6. Clear the text, still in the message box, and confirm it is empty.
guard let stillFocused = attribute(appElement, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }),
    text(stillFocused, kAXIdentifierAttribute) == "ChatBar_ComposerTextView"
else { stop("focus left the message box: 'hello' is still in the box, clear it by hand") }
try await hands.key("cmd+a")
try await hands.key("delete")
await sleep(0.5)
let left = text(composer, kAXValueAttribute)
say(left.isEmpty ? "cleared: message box is empty" : "NOT CLEARED: box still holds \(left.count) characters")
say("Send button still there: \(find("ChatBar_SendButton", under: window) != nil)")

// 7. Back to where the user was.
try await hands.key("cmd+tab")
await sleep(0.8)
say("front app after: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
