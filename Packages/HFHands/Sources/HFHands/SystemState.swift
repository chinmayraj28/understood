import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

/// The app in front.
public struct FrontApp: Sendable, Equatable {
    public let name: String
    public let bundleID: String
    public let pid: pid_t

    public init(name: String, bundleID: String, pid: pid_t) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// Where the keyboard is right now, as the accessibility system reports it.
public struct KeyboardFocus: Sendable, Equatable {
    /// The app that receives key presses. While Spotlight is open this is
    /// Spotlight, even though it never becomes the frontmost app.
    public let appName: String
    public let bundleID: String
    public let pid: pid_t
    /// The focused control's role ("AXTextField", "AXButton"), or "" when unknown.
    public let role: String
    /// The focused control's identifier ("SpotlightSearchField"), or "" when unknown.
    public let identifier: String

    public init(appName: String, bundleID: String, pid: pid_t, role: String = "", identifier: String = "") {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.role = role
        self.identifier = identifier
    }
}

/// An app installed on this Mac.
public struct InstalledApp: Sendable, Equatable {
    /// As Finder shows it, without ".app": "Google Chrome".
    public let name: String
    public let path: String
    public let bundleID: String

    public init(name: String, path: String, bundleID: String) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }
}

/// Everything the quick tools READ about the Mac. Reading state is allowed;
/// acting always goes through the hands. Tests pass a fake that also plays the
/// part of the Mac reacting to key presses.
public protocol SystemReading: Sendable {
    /// Output volume 0...100 and whether it is muted, or nil when the device has no volume control.
    func outputVolume() -> (percent: Double, muted: Bool)?
    /// Built-in screen brightness 0...100, or nil when it can't be read.
    func displayBrightness() -> Double?
    func frontApp() -> FrontApp?
    /// The app's frontmost normal window, in screen points (top-left origin).
    func frontWindowFrame(pid: pid_t) -> CGRect?
    func windowTitle(pid: pid_t) -> String
    /// Names of apps with a window on screen, front to back.
    func appsWithWindows() -> [String]
    func installedApps() -> [InstalledApp]
    func defaultBrowser() -> InstalledApp?
    /// True while the Spotlight search panel is on screen.
    func spotlightIsOpen() -> Bool
    /// True once Spotlight shows a results list under its search field.
    func spotlightShowsResults() -> Bool
    /// Where key presses would land right now, or nil when the accessibility
    /// system can't say.
    func keyboardFocus() -> KeyboardFocus?
    /// The selection as the focused app reports it through accessibility.
    func selectedText(pid: pid_t) -> String?
    func clipboardText() -> String?
    func clipboardChangeCount() -> Int
    /// Where the user's screenshots are saved.
    func screenshotFolder() -> URL
    /// The newest screenshot file in that folder written after `date`.
    func newestScreenshot(since date: Date) -> URL?
    /// True for the app this assistant runs inside (closing it would turn us off).
    func isHostApp(_ app: FrontApp) -> Bool
    /// The main display in screen points.
    func mainDisplayBounds() -> CGRect
}

/// The real Mac.
public final class LiveSystem: SystemReading, @unchecked Sendable {
    public init() {}

    // MARK: Volume (CoreAudio's virtual main volume: same 0-100 scale as the menu bar)

    public func outputVolume() -> (percent: Double, muted: Bool)? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var level = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        // 'vmvc' is kAudioHardwareServiceDeviceProperty_VirtualMainVolume (declared in AudioToolbox).
        address = AudioObjectPropertyAddress(
            mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return nil }
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        let mutedRead = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        return (Double(level) * 100, mutedRead && muted != 0)
    }

    // MARK: Brightness (DisplayServices, a private framework: the only way to read the exact level)

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private lazy var getBrightness: GetBrightness? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
            let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    public func displayBrightness() -> Double? {
        guard let getBrightness else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &displays, &count)
        guard let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var level: Float = -1
        guard getBrightness(builtIn, &level) == 0, level >= 0 else { return nil }
        return Double(level) * 100
    }

    // MARK: Front app and windows

    private typealias GetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias GetProcessPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> OSStatus
    private lazy var frontProcessCalls: (GetFrontProcess, GetProcessPID)? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
            let front = dlsym(library, "GetFrontProcess"), let pid = dlsym(library, "GetProcessPID") else { return nil }
        return (unsafeBitCast(front, to: GetFrontProcess.self), unsafeBitCast(pid, to: GetProcessPID.self))
    }()

    public func frontApp() -> FrontApp? {
        // NSWorkspace.frontmostApplication only updates while the main thread runs
        // its run loop; measured in a command-line process it stayed wrong for
        // seconds. GetFrontProcess (old, deprecated, still present) asks directly
        // and takes about 0.3 ms.
        var pid: pid_t = 0
        if let (front, toPID) = frontProcessCalls {
            var serial = ProcessSerialNumber()
            if front(&serial) == noErr { _ = toPID(&serial, &pid) }
        }
        if pid == 0, let app = NSWorkspace.shared.frontmostApplication { pid = app.processIdentifier }
        guard pid != 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return FrontApp(name: Self.clean(app.localizedName ?? ""), bundleID: app.bundleIdentifier ?? "", pid: pid)
    }

    private func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    public func frontWindowFrame(pid: pid_t) -> CGRect? {
        for window in windows() {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.width >= 80, frame.height >= 80  // skip tooltips and slivers
            else { continue }
            return frame
        }
        return nil
    }

    public func windowTitle(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        guard let window = Self.attribute(app, kAXFocusedWindowAttribute) else { return "" }
        return Self.clean(Self.attribute(window as! AXUIElement, kAXTitleAttribute) as? String ?? "")
    }

    public func appsWithWindows() -> [String] {
        var names: [String] = []
        for window in windows() where (window[kCGWindowLayer as String] as? Int) == 0 {
            let name = Self.clean(window[kCGWindowOwnerName as String] as? String ?? "")
            if !name.isEmpty, !names.contains(name), !["Window Server", "Dock"].contains(name) { names.append(name) }
        }
        return names
    }

    public func spotlightIsOpen() -> Bool {
        windows().contains { ($0[kCGWindowOwnerName as String] as? String) == "Spotlight" }
    }

    public func keyboardFocus() -> KeyboardFocus? {
        let systemWide = AXUIElementCreateSystemWide()
        // Bounded, so an app that has stopped responding cannot hang a tool.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard let focusedApp = Self.attribute(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        let appElement = focusedApp as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var role = "", identifier = ""
        if let element = Self.attribute(appElement, kAXFocusedUIElementAttribute) {
            role = Self.attribute(element as! AXUIElement, kAXRoleAttribute) as? String ?? ""
            identifier = Self.attribute(element as! AXUIElement, kAXIdentifierAttribute) as? String ?? ""
        }
        return KeyboardFocus(appName: Self.clean(app.localizedName ?? ""), bundleID: app.bundleIdentifier ?? "", pid: pid,
                             role: role, identifier: identifier)
    }

    public func spotlightShowsResults() -> Bool {
        // macOS 26: the bare search field is 56 pt tall; with results it grows (303 pt measured).
        windows().contains { window in
            guard (window[kCGWindowOwnerName as String] as? String) == "Spotlight",
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.height > 100
        }
    }

    // MARK: Apps

    private let appIndexLock = NSLock()
    private var appIndex: (built: Date, apps: [InstalledApp])?

    public func installedApps() -> [InstalledApp] {
        appIndexLock.lock()
        defer { appIndexLock.unlock() }
        if let appIndex, Date().timeIntervalSince(appIndex.built) < 120 { return appIndex.apps }
        let apps = AppIndex.scan()
        appIndex = (Date(), apps)
        return apps
    }

    public func defaultBrowser() -> InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return AppIndex.app(at: url)
    }

    // MARK: Text

    public func selectedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = Self.attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let text = Self.attribute(focused as! AXUIElement, kAXSelectedTextAttribute) as? String
        return (text?.isEmpty ?? true) ? nil : text
    }

    public func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

    public func clipboardChangeCount() -> Int { NSPasteboard.general.changeCount }

    // MARK: Screenshots

    public func screenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    public func newestScreenshot(since date: Date) -> URL? {
        let folder = screenshotFolder()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { ["png", "jpg", "heic"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created >= date
                else { return nil }
                return (url, created)
            }
            .max { $0.1 < $1.1 }?.0
    }

    public func mainDisplayBounds() -> CGRect { CGDisplayBounds(CGMainDisplayID()) }

    // MARK: Host

    public func isHostApp(_ app: FrontApp) -> Bool {
        if app.pid == getpid() || app.pid == Permissions.responsiblePID() { return true }
        if let ours = Bundle.main.bundleIdentifier, ours == app.bundleID { return true }
        return app.name == Permissions.hostAppName
    }

    // MARK: Helpers

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Drops invisible formatting marks: WhatsApp's name starts with U+200E.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespaces)
    }
}
