import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFHands

// Live tests: the real pointer, keys and apps of this Mac. Run with
//     HF_LIVE=1 swift test --filter Live
// Someone is using this Mac, so every test puts back what it changes: the
// volume, brightness and pointer position are restored exactly (by test-only
// cleanup code, not by the product), apps the tests open are quit, the app that
// was in front is brought back, and typing goes only into a scratch TextEdit
// document the test opens itself and checks is in front. Opt-in extras:
// HF_LIVE_MEDIA=1 (presses play/pause twice), HF_LIVE_BROWSER=1 (opens a tab),
// HF_LIVE_SCREENSHOT=1 (saves a screenshot, then deletes that file).

private let live = ProcessInfo.processInfo.environment["HF_LIVE"] == "1"
private func optIn(_ name: String) -> Bool { live && ProcessInfo.processInfo.environment[name] == "1" }

/// Timings measured in these tests, printed as they happen.
private func report(_ label: String, _ seconds: Double) {
    print(String(format: "LIVE TIMING %-32@ %8.1f ms", label as NSString, seconds * 1000))
}

private func timed<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let started = Date()
    let value = try await body()
    report(label, Date().timeIntervalSince(started))
    return value
}

// MARK: Test-only restore helpers (the product never sets these directly)

private enum Restore {
    static func setVolume(_ percent: Double, muted: Bool) {
        var device = AudioObjectID(0)
        var size = UInt32(4)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        var level = Float32(percent / 100)
        address = AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, 4, &level)
        var mute = UInt32(muted ? 1 : 0)
        address.mSelector = kAudioDevicePropertyMute
        AudioObjectSetPropertyData(device, &address, 0, nil, 4, &mute)
    }

    static func setBrightness(_ percent: Double) {
        typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
            let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(symbol, to: SetBrightness.self)(CGMainDisplayID(), Float(percent / 100))
    }

    static func pointer(_ point: CGPoint) { CGWarpMouseCursorPosition(point) }

    static func bringBack(_ app: NSRunningApplication?) {
        app?.activate()
    }

    static func quit(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }
}

private func frontRunningApp() -> NSRunningApplication? {
    LiveSystem().frontApp().flatMap { NSRunningApplication(processIdentifier: $0.pid) }
}

private func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

// MARK: Scratch TextEdit document

private final class ScratchDocument: @unchecked Sendable {
    let url: URL
    let wasRunning: Bool
    let previousFront: NSRunningApplication?
    var pid: pid_t = 0

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("handsfree-scratch-\(UUID().uuidString.prefix(6)).txt")
        let lines = (0..<150).map { "line \($0) scratch text for scrolling and typing tests" }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        wasRunning = isRunning("com.apple.TextEdit")
        previousFront = frontRunningApp()
    }

    /// Opens the document (test setup only) and waits until it is in front.
    /// A freshly launched TextEdit sometimes shows its Open panel instead of the
    /// document (seen on 5 Nov): cancel the panel and ask once more.
    func open() async -> Bool {
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "TextEdit", url.path]
            try? process.run()
            process.waitUntilExit()
            if await waitFor(4, { self.isFront }) { return true }
            cancelOpenPanels()
        }
        return false
    }

    /// Presses Cancel on any TextEdit Open panel (an app with one open ignores a quit request).
    func cancelOpenPanels() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit") {
            let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows where (attribute(window, kAXTitleAttribute) as? String) == "Open" {
                for button in buttons(in: window) where (attribute(button, kAXTitleAttribute) as? String) == "Cancel" {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            }
        }
    }

    private func buttons(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        var found: [AXUIElement] = []
        if (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole { found.append(element) }
        guard depth < 8 else { return found }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            found += buttons(in: child, depth: depth + 1)
        }
        return found
    }

    /// True only when this document's window is in front AND has the keyboard:
    /// checked immediately before every key press, so a test never types into a
    /// window that popped up (on 5 Nov a Java updater and a password prompt did).
    var isFront: Bool {
        let system = LiveSystem()
        guard let front = system.frontApp(), front.bundleID == "com.apple.TextEdit" else { return false }
        pid = front.pid
        guard system.windowTitle(pid: front.pid) == url.lastPathComponent else { return false }
        if let focus = system.keyboardFocus() {
            if focus.pid != front.pid || KeyLanding.isProtected(name: focus.appName, bundleID: focus.bundleID) { return false }
        }
        return true
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        LiveSystem.attribute(element, name)
    }

    private var window: AXUIElement? {
        let windows = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { (attribute($0, kAXTitleAttribute) as? String) == url.lastPathComponent }
    }

    private func find(_ element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        if (attribute(element, kAXRoleAttribute) as? String) == role { return element }
        guard depth < 6 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }

    var text: String {
        guard let window, let area = find(window, role: kAXTextAreaRole) else { return "" }
        return attribute(area, kAXValueAttribute) as? String ?? ""
    }

    var scrollPosition: Double {
        guard let window, let area = find(window, role: kAXScrollAreaRole),
            let bar = attribute(area, kAXVerticalScrollBarAttribute) else { return -1 }
        return (attribute(bar as! AXUIElement, kAXValueAttribute) as? NSNumber)?.doubleValue ?? -1
    }

    /// Closes the window without saving (test cleanup), quits TextEdit if the
    /// test started it, and brings back the app that was in front.
    func close() async {
        if let window, let button = attribute(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: 800_000_000)
            // If a "save changes?" sheet appeared, choose not to save.
            if let still = self.window {
                for sheet in attribute(still, kAXChildrenAttribute) as? [AXUIElement] ?? []
                where (attribute(sheet, kAXRoleAttribute) as? String) == kAXSheetRole {
                    for button in attribute(sheet, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                        let title = attribute(button, kAXTitleAttribute) as? String ?? ""
                        if ["Don't Save", "Don’t Save", "Delete", "Revert Changes"].contains(title) {
                            AXUIElementPerformAction(button, kAXPressAction as CFString)
                        }
                    }
                }
            }
        }
        cancelOpenPanels()
        if !wasRunning {
            Restore.quit(bundleID: "com.apple.TextEdit")
            if !(await waitFor(3, { !isRunning("com.apple.TextEdit") })) {
                // Seen on 5 Nov: TextEdit with no windows left ignored the quit request.
                // This test launched it and nothing is open, so nothing can be lost.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit") {
                    let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                    if windows.isEmpty { app.forceTerminate() } else { print("LIVE WARNING: TextEdit still has windows open; left running") }
                }
            }
        }
        try? FileManager.default.removeItem(at: url)
        Restore.bringBack(previousFront)
    }
}

/// The live tests' stand-in for the app's safety guard: allows an action only while the
/// scratch document is in front with the keyboard, so nothing risky can reach any other window.
private struct ScratchOnlyGuard: QuickActionGuarding {
    let document: ScratchDocument
    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict {
        document.isFront ? .allow : .refuse("The scratch document isn't in front, so the test won't do that.")
    }
}

// MARK: The live suite: serialized, so tests never fight over the real pointer

@Suite(.serialized, .enabled(if: live, "set HF_LIVE=1 to run on the real Mac"))
struct LiveHandsTests {
    let hands = SystemHands()
    let system = LiveSystem()

    @Test func permissionsReport() {
        print("LIVE host app: \(Permissions.hostAppName)")
        for status in Permissions.checkAll() { print("LIVE permission \(status.name): \(status.state.rawValue)") }
    }

    /// False (with the reason printed) when the hands could not act anyway: the test then skips.
    private func canAct() -> Bool {
        if !AXIsProcessTrusted() {
            print("LIVE SKIP: Accessibility is not granted to \(Permissions.hostAppName), so the hands can't act")
            return false
        }
        return true
    }

    @Test func glideLandsExactlyAndTakesTheExpectedTime() async throws {
        guard canAct() else { return }
        let start = hands.pointerPosition
        defer { Restore.pointer(start) }
        let screen = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: screen.midX + (start.x < screen.midX ? 200 : -200), y: screen.midY)
        let expected = Glide.duration(forDistance: Glide.distance(start, target))
        let started = Date()
        try await hands.move(to: target, duration: nil)
        let took = Date().timeIntervalSince(started)
        report("glide \(Int(Glide.distance(start, target))) pt (planned \(Int(expected * 1000)) ms)", took)
        #expect(abs(hands.pointerPosition.x - target.x) < 0.5 && abs(hands.pointerPosition.y - target.y) < 0.5)
        #expect(took >= expected * 0.9 && took < expected + 0.15)
        try await hands.move(to: start, duration: nil)
    }

    @Test func haltFreezesARealGlide() async throws {
        guard canAct() else { return }
        let start = hands.pointerPosition
        defer {
            hands.resume()
            Restore.pointer(start)
        }
        let screen = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: start.x < screen.midX ? screen.maxX - 50 : 50, y: start.y)
        let glide = Task { try await hands.move(to: target, duration: 1.0) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let haltedAt = Date()
        hands.halt()
        await #expect(throws: Halted.self) { try await glide.value }
        report("halt to Halted thrown", Date().timeIntervalSince(haltedAt))
        let frozen = hands.pointerPosition
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(hands.pointerPosition == frozen)  // it really stopped
        #expect(abs(frozen.x - target.x) > 50)  // and stopped part way
    }

    @Test func volumeByKeysAndRestore() async throws {
        guard canAct() else { return }
        guard let original = system.outputVolume() else {
            print("LIVE SKIP: This output device has no volume control; skipping")
            return
        }
        defer { Restore.setVolume(original.percent, muted: original.muted) }
        let tools = QuickTools.make(hands: hands, system: system)
        let setVolume = tools.first { $0.name == "set_volume" }!
        for target in [30.0, 47.0, 25.0] {
            let result = await timed("set_volume \(Int(target))") { await setVolume.handler(["percent": .number(target)]) }
            #expect(result["ok"] == true, "\(result)")
            let reached = system.outputVolume()!.percent
            print("LIVE volume asked \(target) reached \(reached) with \(result["key_presses"]?.intValue ?? -1) presses")
            #expect(abs(reached - target) <= 0.8)
        }
        let muted = await timed("set_volume mute") { await setVolume.handler(["mute": true]) }
        #expect(muted["muted"] == true && system.outputVolume()!.muted)
        let unmuted = await timed("set_volume unmute") { await setVolume.handler(["mute": false]) }
        #expect(unmuted["muted"] == false && !system.outputVolume()!.muted)
    }

    @Test func brightnessByKeysAndRestore() async throws {
        guard canAct() else { return }
        guard let original = system.displayBrightness() else {
            print("LIVE SKIP: No built-in screen brightness to read; skipping")
            return
        }
        defer {
            // Brightness keys animate for a moment; restore after that, then check.
            usleep(1_000_000)
            Restore.setBrightness(original)
            usleep(300_000)
            if let now = LiveSystem().displayBrightness(), abs(now - original) > 0.5 { Restore.setBrightness(original) }
        }
        let tool = QuickTools.make(hands: hands, system: system).first { $0.name == "set_brightness" }!
        let target = original > 40 ? original - 20 : original + 20
        let result = await timed("set_brightness ±20") { await tool.handler(["percent": .number(target)]) }
        #expect(result["ok"] == true, "\(result)")
        #expect(abs(system.displayBrightness()! - target) <= 0.8)
    }

    @Test func typingKeysAndScrollingInAScratchDocument() async throws {
        guard canAct() else { return }
        let document = ScratchDocument()
        guard await document.open() else {
            await document.close()
            print("LIVE SKIP: Couldn't bring the scratch TextEdit document to the front; skipped so nothing is typed elsewhere")
            return
        }
        let pointer = hands.pointerPosition
        defer { Restore.pointer(pointer) }
        let tools = Dictionary(uniqueKeysWithValues: QuickTools.make(
            hands: hands, guard: ScratchOnlyGuard(document: document), system: system).map { ($0.name, $0) })

        // where_am_i
        let whereAmI = await timed("where_am_i") { await tools["where_am_i"]!.handler([:]) }
        #expect(whereAmI["app"] == "TextEdit")

        // Scroll: to the top, a page down, to the bottom, back to the top.
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("scroll top (incl. glide)") { await tools["scroll"]!.handler(["direction": "top"]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(document.scrollPosition < 0.01)
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("scroll page down") { await tools["scroll"]!.handler(["direction": "down"]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let afterPage = document.scrollPosition
        print("LIVE scroll position after one page down: \(afterPage)")
        #expect(afterPage > 0.01)
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("scroll bottom") { await tools["scroll"]!.handler(["direction": "bottom"]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(document.scrollPosition > 0.99)
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await tools["scroll"]!.handler(["direction": "top"])

        // Typing: go to the end, type Unicode, check it arrived exactly and no Return was pressed.
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("press_keys cmd+down") { await tools["press_keys"]!.handler(["keys": "command down"]) }
        let before = document.text
        let sample = " Café crème — ça va? 你好 Привет 👋🏽 👨‍👩‍👧 “quotes” naïve 100€"
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        let typed = await timed("type_text \(sample.count) chars") { await tools["type_text"]!.handler(["text": .string(sample)]) }
        #expect(typed["ok"] == true, "\(typed)")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(document.text == before + sample)
        #expect(document.text.filter(\.isNewline).count == before.filter(\.isNewline).count)

        // A line break is Shift+Return: one new line, nothing else.
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        let twoLines = await timed("type_text with a line break") { await tools["type_text"]!.handler(["text": "\nnew line here"]) }
        #expect(twoLines["ok"] == true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterBreak = document.text
        // macOS may capitalise the first word of a new line ("Capitalize words
        // automatically"); the hands typed it exactly, so compare without case.
        #expect(afterBreak.lowercased().hasSuffix("new line here"))
        #expect(afterBreak.filter(\.isNewline).count == before.filter(\.isNewline).count + 1)

        // Backspace repeated removes exactly what was typed.
        let beforeXYZ = document.text
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await tools["type_text"]!.handler(["text": "xyz"])
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("press_keys backspace x3") { await tools["press_keys"]!.handler(["keys": "backspace", "times": 3]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(document.text == beforeXYZ)

        // Select all, then read the selection back through accessibility.
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await timed("shortcut select_all") { await tools["shortcut"]!.handler(["action": "select_all"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        let selection = await timed("read_text selection") { await tools["read_text"]!.handler([:]) }
        #expect(selection["text"]?.stringValue == String(document.text.prefix(4000)))
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        _ = await tools["press_keys"]!.handler(["keys": "right"])

        // The pointer tool: click in the document where the pointer is.
        let window = system.frontWindowFrame(pid: document.pid)!
        try await hands.move(to: CGPoint(x: window.midX, y: window.midY), duration: nil)
        guard document.isFront else { await document.close(); print("LIVE SKIP: lost focus"); return }
        let click = await timed("pointer click") { await tools["pointer"]!.handler(["action": "click"]) }
        #expect(click["ok"] == true)
        #expect(document.isFront)

        await document.close()
    }

    @Test func spotlightOpensAnAppReliably() async throws {
        guard canAct() else { return }
        let calculator = "com.apple.calculator"
        guard !isRunning(calculator) else {
            print("LIVE SKIP: Calculator is already open; skipped so the user's Calculator isn't quit")
            return
        }
        let previous = frontRunningApp()
        let tool = QuickTools.make(hands: hands, system: system).first { $0.name == "open_app" }!
        var successes = 0
        let runs = 5
        for run in 1...runs {
            // Immediately before the keys: the app we expect must be in front with
            // the keyboard, and no password or install window anywhere near it.
            let front = system.frontApp()
            let focus = system.keyboardFocus()
            let unexpected = front?.bundleID != previous?.bundleIdentifier
                || focus.map { $0.pid != front?.pid } == true
                || focus.map { KeyLanding.isProtected(name: $0.appName, bundleID: $0.bundleID) } == true
            if unexpected {
                print("LIVE SKIP: \(focus?.appName ?? front?.name ?? "an unexpected window") has the keyboard before run \(run); stopping so no key lands there")
                Restore.bringBack(previous)
                return
            }
            let result = await timed("open_app via Spotlight, run \(run)") { await tool.handler(["name": "calculator"]) }
            if result["ok"] == true, system.frontApp()?.bundleID == calculator { successes += 1 } else { print("LIVE run \(run) failed: \(result) front=\(system.frontApp()?.name ?? "?") spotlight=\(system.spotlightIsOpen())") }
            Restore.quit(bundleID: calculator)
            _ = await waitFor(3) { !isRunning(calculator) }
            Restore.bringBack(previous)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        print("LIVE Spotlight reliability: \(successes) of \(runs)")
        #expect(successes == runs)
        #expect(!system.spotlightIsOpen())
    }

    @Test(.enabled(if: optIn("HF_LIVE_MEDIA"), "HF_LIVE_MEDIA=1 presses play/pause twice"))
    func mediaKeyTwice() async throws {
        guard canAct() else { return }
        try await hands.key("play_pause")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await hands.key("play_pause")
    }

    @Test(.enabled(if: optIn("HF_LIVE_BROWSER"), "HF_LIVE_BROWSER=1 opens a tab in the default browser"))
    func openURLInTheBrowser() async throws {
        guard canAct() else { return }
        let tool = QuickTools.make(hands: hands, system: system).first { $0.name == "open_url" }!
        let result = await timed("open_url example.com") { await tool.handler(["url": "example.com"]) }
        #expect(result["ok"] == true, "\(result)")
    }

    @Test(.enabled(if: optIn("HF_LIVE_SCREENSHOT"), "HF_LIVE_SCREENSHOT=1 saves a screenshot, then deletes it"))
    func screenshotWithTheSystemShortcut() async throws {
        guard canAct() else { return }
        let tool = QuickTools.make(hands: hands, system: system).first { $0.name == "take_screenshot" }!
        let result = await timed("take_screenshot screen") { await tool.handler([:]) }
        #expect(result["ok"] == true, "\(result)")
        if let path = result["path"]?.stringValue, path.contains("Screenshot") {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
