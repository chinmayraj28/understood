import AppKit
import QuartzCore
import CoreGraphics
import Foundation
import HFCore
import HFEyes
import ImageIO

// hf-eyes: try the eyes and labels by hand. Read-only unless --web is given (see below).
//
//   swift run hf-eyes info                          screen size, scale, permissions
//   swift run hf-eyes shot [out.png] [--max 1280] [--region x,y,w,h] [--repeat 5]
//   swift run hf-eyes pointer                       describe the control under the pointer now
//   swift run hf-eyes at X Y                        describe the control at a screen point
//   swift run hf-eyes focus                         describe the control with keyboard focus
//   swift run hf-eyes front                         the app and window in front
//   swift run hf-eyes controls [--limit 60] [--app NAME] [--menus] [--find TEXT] [--mask]
//
// --mask replaces letters in labels with "x", to look at structure without reading private names.
// --web first asks browsers and Electron apps to expose web pages (a write to those apps),
//       waits two seconds for the page tree, and switches them back off before exiting.
//
// Descriptions are printed the way HFCore's ScreenAction builds them, plus the raw fields.

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }
func milliseconds(since start: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(start) * 1000) }
func masked(_ text: String) -> String {
    flag("--mask") ? String(text.map { $0.isLetter || $0.isNumber ? "x" : $0 }) : text
}
/// The pointer's position in screen points, origin top left (Quartz's own convention).
func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

let source = SystemAccessibilitySource()  // creating it changes nothing in any app
let labels = AccessibilityLabels(source: source)

/// One line for a control: HFCore's wording, then role, label and identifier as fields.
func describe(_ info: UIElementInfo?, frontApp: String = "") -> String {
    let phrase = masked(ScreenAction.phrase(for: info, frontApp: frontApp))
    guard let info else { return phrase }
    return "\(phrase)   {role: \(info.role.rawValue), label: \"\(masked(info.label))\", identifier: \"\(info.identifier)\"}"
}

if flag("--web") {
    print("web content switched on in: \(await labels.enableWebContent())")
    try? await Task.sleep(for: .seconds(2))
}

switch arguments.first ?? "info" {
case "info":
    let eyes = ScreenEyes()
    print("main display: \(eyes.screenSize.width) x \(eyes.screenSize.height) points, scale \(ScreenEyes.mainDisplayScale)")
    if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
        print("backing pixels: \(mode.pixelWidth) x \(mode.pixelHeight); mode \(mode.width) x \(mode.height)")
    }
    print("screen recording permission: \(ScreenEyes.hasScreenRecordingPermission)")
    print("accessibility permission: \(SystemAccessibilitySource.isTrusted)")

case "shot":
    let eyes = ScreenEyes()
    let maxLongEdge = Int(option("--max") ?? "") ?? 1280
    let repeats = Int(option("--repeat") ?? "") ?? 1
    var region = CGRect(origin: .zero, size: eyes.screenSize)
    if let text = option("--region") {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        if parts.count == 4 { region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
    }
    do {
        var shot: Shot?
        for run in 1...max(1, repeats) {
            let start = Date()
            shot = try await eyes.grab(region: region, maxLongEdge: maxLongEdge)
            let parts = eyes.lastGrabTimings
            print("grab \(run): \(milliseconds(since: start))  (list windows \(Int(parts.listWindows)) ms, capture \(Int(parts.capture)) ms, PNG \(Int(parts.encode)) ms)")
        }
        guard let shot else { break }
        print("image \(shot.pixelWidth) x \(shot.pixelHeight) px, \(shot.png.count / 1024) KB, shows \(shot.screenRect)")
        let centre = shot.screenPoint(imageX: Double(shot.pixelWidth) / 2, imageY: Double(shot.pixelHeight) / 2)
        print("image centre maps to screen point \(centre)")
        // The output path is the first word after "shot" that is neither an option nor its value.
        let outIndex = arguments.indices.dropFirst().first { index in
            !arguments[index].hasPrefix("--") && !arguments[index - 1].hasPrefix("--")
        }
        if let outIndex {
            try shot.png.write(to: URL(fileURLWithPath: arguments[outIndex]))
            print("saved \(arguments[outIndex])")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }

case "pointer", "at":
    var point = pointerLocation()
    if arguments.first == "at", arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) {
        point = CGPoint(x: x, y: y)
    }
    let front = await labels.frontmost()
    let start = Date()
    let info = await labels.element(at: point)
    let took = milliseconds(since: start)
    print("at \(point): \(describe(info, frontApp: front.app))  [\(took)]")
    print("  as the gate sees it: \(masked(await labels.clickAction(at: point).description))")
    if let info { print("  frame \(info.frame), enabled \(info.isEnabled)") }
    if let hit = source.hit(at: point) {
        let node = hit.node
        print("  raw: role \(node.role) subrole \(node.subrole) id \"\(node.identifier)\" help \"\(masked(node.help))\"")
        print("  ancestors: \(hit.ancestors.map { "\($0.role)\($0.identifier.isEmpty ? "" : "#" + $0.identifier)" })")
    }

case "focus":
    let front = await labels.frontmost()
    let start = Date()
    let info = await labels.focusedElement()
    print("focus: \(describe(info, frontApp: front.app))  [\(milliseconds(since: start))]")
    print("  as the gate sees Return: \(masked(await labels.keyAction(KeyChord(key: "return")).description))")

case "front":
    let start = Date()
    let front = await labels.frontmost()
    print("front: \(front.app), window \"\(masked(front.window))\"  [\(milliseconds(since: start))]")

case "controls":
    let limit = Int(option("--limit") ?? "") ?? 60
    let start = Date()
    var hits: [AccessibilityHit]
    if let name = option("--app") {
        // Match after removing invisible marks: WhatsApp's own name is "\u{200E}WhatsApp".
        let wanted = ControlNamer.clean(name).lowercased()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ControlNamer.clean($0.localizedName ?? "").lowercased() == wanted || $0.bundleIdentifier == name
        }) else {
            print("no running app called \(name)")
            exit(1)
        }
        hits = source.controls(processID: app.processIdentifier, limit: 100_000, includeMenuBar: flag("--menus"))
    } else {
        hits = source.controls(limit: 100_000)
    }
    let took = milliseconds(since: start)
    if let text = option("--find") {
        hits = hits.filter {
            describe(ControlNamer.info($0.node, app: $0.app, window: $0.window)).localizedCaseInsensitiveContains(text)
        }
    }
    if flag("--roles") {
        var counts: [String: Int] = [:]
        for hit in hits { counts[hit.node.role, default: 0] += 1 }
        print("roles: \(counts.sorted { $0.value > $1.value })")
    }
    let total = hits.count
    for hit in hits.prefix(limit) {
        let node = hit.node
        let raw = "\(node.role)\(node.identifier.isEmpty ? "" : " #" + node.identifier)"
        print("\(describe(ControlNamer.info(node, app: hit.app, window: hit.window)))   [\(raw)] at \(node.frame.origin)")
    }
    print("\(total) controls (showing \(min(total, limit))) in \(took)")

case "webcheck", "exclusion-check", "restore-check", "overlay-check", "hittest-check":
    break  // handled below
default:
    print("usage: hf-eyes info | shot [out.png] [--max N] [--region x,y,w,h] [--repeat N] | pointer | at X Y | focus | front | controls [--limit N] [--app NAME] [--menus] [--find TEXT] [--mask] [--roles] [--web] | webcheck [--app NAME] [--set manual|enhanced]")
}

// MARK: webcheck (diagnostic): does a Chromium app expose its web page to accessibility?

/// Prints the app's accessibility switches and how many elements sit under each web area.
/// With `--set manual` or `--set enhanced` it first sets that switch to true (the only write).
func webCheck(appName: String, set switchName: String?) {
    let wanted = ControlNamer.clean(appName).lowercased()
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        ControlNamer.clean($0.localizedName ?? "").lowercased() == wanted
    }) else { print("no running app called \(appName)"); return }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    func read(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    if let switchName {
        // "enhanced" or "manual" switch on; "off" switches both off again.
        let names = switchName == "off" ? ["AXEnhancedUserInterface", "AXManualAccessibility"]
            : [switchName == "enhanced" ? "AXEnhancedUserInterface" : "AXManualAccessibility"]
        let value = switchName == "off" ? kCFBooleanFalse : kCFBooleanTrue
        for attribute in names {
            let status = AXUIElementSetAttributeValue(appElement, attribute as CFString, value!)
            print("set \(attribute) = \(switchName != "off"): status \(status.rawValue)")
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
    print("AXManualAccessibility = \(String(describing: read(appElement, "AXManualAccessibility")))")
    print("AXEnhancedUserInterface = \(String(describing: read(appElement, "AXEnhancedUserInterface")))")
    let windows = (read(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    print("windows: \(windows.count)")
    for (number, window) in windows.enumerated() {
        var queue: [AXUIElement] = [window]
        var webAreas = 0, underWeb = 0, links = 0, visited = 0
        var inWeb = Set<Int>()  // indexes in `order` that are inside a web area
        var order: [AXUIElement] = []
        while !queue.isEmpty, visited < 20000 {
            let element = queue.removeFirst()
            let index = order.count
            order.append(element)
            visited += 1
            let role = (read(element, kAXRoleAttribute) as? String) ?? ""
            let isWeb = inWeb.contains(index) || role == "AXWebArea"
            if role == "AXWebArea" { webAreas += 1 }
            if isWeb { underWeb += 1 }
            if role == "AXLink" { links += 1 }
            for child in (read(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if isWeb { inWeb.insert(order.count + queue.count) }
                queue.append(child)
            }
        }
        print("window \(number): \(visited) elements, \(webAreas) web areas, \(underWeb) inside them, \(links) links")
    }
}

if arguments.first == "webcheck" {
    webCheck(appName: option("--app") ?? "Google Chrome", set: option("--set"))
}

// MARK: exclusion-check: is our own window really left out of the screenshot?

/// Shows a small red square for about a second, grabs that spot twice (once including this
/// process's windows, once leaving them out) and reports the centre pixel's colour each time.
@MainActor
func exclusionCheck() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no Dock icon, does not take focus
    let squareInPoints = CGRect(x: 60, y: 300, width: 120, height: 120)  // top-left origin
    let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
    // AppKit puts the origin at the bottom left.
    let appKitFrame = CGRect(x: squareInPoints.minX, y: screenHeight - squareInPoints.maxY,
                             width: squareInPoints.width, height: squareInPoints.height)
    let window = NSWindow(contentRect: appKitFrame, styleMask: .borderless, backing: .buffered, defer: false)
    window.backgroundColor = .red
    window.level = .screenSaver
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    window.display()
    CATransaction.flush()  // push the drawing to the window server without spinning the run loop
    try? await Task.sleep(for: .milliseconds(600))
    defer { window.orderOut(nil) }

    for exclude in [false, true] {
        do {
            let shot = try await ScreenEyes(excludeOwnProcess: exclude).grab(region: squareInPoints, maxLongEdge: 64)
            guard let source = CGImageSourceCreateWithData(shot.png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
            else { print("could not read the image"); continue }
            let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * (image.bitsPerPixel / 8)
            let alphaFirst = image.bitmapInfo.contains(.byteOrder32Little)  // BGRA in memory
            let (red, green, blue) = alphaFirst
                ? (bytes[offset + 2], bytes[offset + 1], bytes[offset])
                : (bytes[offset], bytes[offset + 1], bytes[offset + 2])
            let looksRed = red > 200 && green < 60 && blue < 60
            print("exclude own windows = \(exclude): centre pixel rgb(\(red), \(green), \(blue)) -> \(looksRed ? "RED square visible" : "square not visible")")
        } catch {
            print("grab failed: \(error)")
        }
    }
}

if arguments.first == "exclusion-check" {
    await exclusionCheck()
}

// MARK: restore-check: switch web accessibility on for running browsers, then restore it.
if arguments.first == "restore-check" {
    let checker = SystemAccessibilitySource()
    print("switched on: \(checker.enableWebContent())")
    try? await Task.sleep(for: .seconds(1))
    print("restored: \(checker.restoreWebContentSwitches())")
}

// Leave the user's apps as they were.
if flag("--web") { print("switched back off: \(labels.restoreWebContentSwitches())") }

// MARK: overlay-check: do lookups look through Handsfree's own windows? (read-only)

/// Lists Handsfree's on-screen windows, then at the pointer and at each such window's centre
/// compares the raw system-wide hit test with what the labels return. Prints roles and owners
/// (labels masked with --mask).
func overlayCheck() async {
    let ignored = IgnoredOwners.default
    let windows = ScreenWindow.onScreen()
    let ours = windows.filter { ignored.contains($0.processID) }
    print("Handsfree windows on screen: \(ours.count)")
    for window in ours {
        print("  \(window.ownerName) pid \(window.processID) layer \(window.layer) alpha \(window.alpha) frame \(window.frame)")
    }
    let systemWide = AXUIElementCreateSystemWide()
    var points = [("pointer", pointerLocation())]
    points += ours.prefix(4).map { ("centre of a \($0.ownerName) window", CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    for (name, point) in points {
        var raw: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw)
        var pid: pid_t = 0
        if let raw { AXUIElementGetPid(raw, &pid) }
        let rawOwner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "none (status \(status.rawValue))"
        let info = await labels.element(at: point)
        print("\(name) \(point):")
        print("  raw system-wide hit belongs to: \(ControlNamer.clean(rawOwner))\(ignored.contains(pid) ? "  <- OURS" : "")")
        print("  labels return: \(describe(info))")
    }
    var focusedApp: AnyObject?
    AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
    var focusedPID: pid_t = 0
    if let focusedApp { AXUIElementGetPid(focusedApp as! AXUIElement, &focusedPID) }
    print("raw focused app: \(NSRunningApplication(processIdentifier: focusedPID)?.localizedName ?? "none")\(ignored.contains(focusedPID) ? "  <- OURS" : "")")
    print("labels frontmost: \(await labels.frontmost())")
}

if arguments.first == "overlay-check" {
    await overlayCheck()
}

// MARK: hittest-check: does an accessibility hit test see a window that ignores mouse events?

/// Shows a small red window of this process (like the overlay), then hit-tests its centre
/// system-wide, once with ignoresMouseEvents = true and once false. Removes the window after.
@MainActor
func hitTestCheck() async {
    NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon, does not take focus
    let square = CGRect(x: 60, y: 300, width: 120, height: 120)  // points, top-left origin
    let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
    let window = NSWindow(
        contentRect: CGRect(x: square.minX, y: screenHeight - square.maxY, width: square.width, height: square.height),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.backgroundColor = .red
    window.level = .screenSaver
    window.isReleasedWhenClosed = false
    let centre = CGPoint(x: square.midX, y: square.midY)
    for ignoresMouse in [true, false] {
        window.ignoresMouseEvents = ignoresMouse
        window.orderFrontRegardless()
        window.display()
        CATransaction.flush()
        try? await Task.sleep(for: .milliseconds(400))
        var raw: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(centre.x), Float(centre.y), &raw)
        var pid: pid_t = 0
        if let raw { AXUIElementGetPid(raw, &pid) }
        let owner = pid == getpid() ? "THIS PROCESS (the red window)" : (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "none, status \(status.rawValue)")
        let resolved = await labels.element(at: centre)
        print("ignoresMouseEvents = \(ignoresMouse): raw system-wide hit -> \(ControlNamer.clean(owner)); labels -> \(resolved.map { "\($0.role.rawValue) in \($0.app)" } ?? "nil")")
    }
    window.orderOut(nil)
}

if arguments.first == "hittest-check" {
    await hitTestCheck()
}
