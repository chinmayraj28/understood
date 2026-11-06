import CoreGraphics
import Foundation
import HFCore
@testable import HFHands

/// Records what a quick tool asks the hands to do. Lets the fake Mac react.
final class FakeHands: Hands, @unchecked Sendable {
    enum Action: Equatable {
        case key(String)
        case type(String)
        case click(CGPoint, MouseButton, Int)
        case move(CGPoint)
        case scroll(dx: Int, dy: Int, at: CGPoint?)
    }

    private let lock = NSLock()
    private var recorded: [Action] = []
    private var pointer = CGPoint(x: 700, y: 500)
    private var halted = false
    var onKey: (@Sendable (String) -> Void)?

    var actions: [Action] { lock.withLock { recorded } }
    var keys: [String] { actions.compactMap { if case .key(let name) = $0 { return name } else { return nil } } }
    var typed: [String] { actions.compactMap { if case .type(let text) = $0 { return text } else { return nil } } }
    func setPointer(_ point: CGPoint) { lock.withLock { pointer = point } }

    private func record(_ action: Action) throws {
        if isHalted { throw Halted() }
        lock.withLock { recorded.append(action) }
    }

    func halt() { lock.withLock { halted = true } }
    func resume() { lock.withLock { halted = false } }
    var isHalted: Bool { lock.withLock { halted } }
    var pointerPosition: CGPoint { lock.withLock { pointer } }

    func move(to point: CGPoint, duration: TimeInterval?) async throws {
        try record(.move(point))
        setPointer(point)
    }

    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {
        try record(.click(point, button, count))
        setPointer(point)
    }

    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws {}

    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws { try record(.scroll(dx: dx, dy: dy, at: point)) }

    func key(_ combo: String) async throws {
        // Like the real hands, refuse names that don't parse.
        _ = try KeyTable.parse(combo, layout: USKeyboardLayout())
        try record(.key(combo))
        onKey?(combo)
    }

    func typeText(_ text: String, allowReturn: Bool) async throws {
        if !allowReturn, text.contains(where: \.isNewline) { throw SpeakableError("no newline") }
        try record(.type(text))
    }
}

/// A Mac whose state the tests set, and which reacts to keys like the real one.
final class FakeSystem: SystemReading, @unchecked Sendable {
    private let lock = NSLock()
    var volume: Double? = 19
    var muted = false
    var brightness: Double? = 63.82
    var front: FrontApp? = FrontApp(name: "Orca", bundleID: "com.stablyai.orca", pid: 1)
    var windows: [pid_t: CGRect] = [1: CGRect(x: 0, y: 30, width: 800, height: 600)]
    var titles: [pid_t: String] = [1: "Terminal"]
    var visible = ["Orca", "Google Chrome", "Spotify"]
    var apps: [InstalledApp] = [
        "Google Chrome:com.google.Chrome", "Visual Studio Code:com.microsoft.VSCode", "WhatsApp:net.whatsapp.WhatsApp",
        "Spotify:com.spotify.client", "Safari:com.apple.Safari", "Steam:com.valvesoftware.steam",
        "Microsoft Word:com.microsoft.Word", "Microsoft Excel:com.microsoft.Excel", "Microsoft Teams:com.microsoft.teams2",
        "System Settings:com.apple.systempreferences", "TextEdit:com.apple.TextEdit", "Calculator:com.apple.calculator",
        "Arc:company.thebrowser.Browser",
    ].map { entry in
        let parts = entry.split(separator: ":").map(String.init)
        return InstalledApp(name: parts[0], path: "/Applications/\(parts[0]).app", bundleID: parts[1])
    }
    var browser: InstalledApp? { apps.first { $0.name == "Arc" } }
    var spotlight = false
    var spotlightText = ""
    /// What Return in Spotlight opens; nil means nothing comes forward.
    var spotlightOpens: ((String) -> FrontApp?)? = { text in FrontApp(name: text, bundleID: "", pid: 42) }
    var selection: String?
    var clipboard: String? = "old clip"
    var clipboardCount = 1
    /// What Command+C copies.
    var copies: String?
    var screenshotFile: URL?
    var hostNames: Set<String> = ["Orca"]
    /// How volume and brightness keys behave (true: the measured 1/16 and 1/64 grids).
    var keysWork = true

    func with<T>(_ body: () -> T) -> T { lock.withLock(body) }

    /// Wire this Mac to react to the fake hands' keys and typing.
    func react(to hands: FakeHands) {
        hands.onKey = { [weak self] combo in self?.pressed(combo) }
    }

    func pressed(_ combo: String) {
        lock.withLock {
            switch combo {
            case "cmd+space": spotlight = true; spotlightText = ""
            case "escape": spotlight = false
            case "return" where spotlight:
                spotlight = false
                if let opened = spotlightOpens?(spotlightText) {
                    let installed = apps.first { $0.name == opened.name }
                    front = FrontApp(name: opened.name, bundleID: installed?.bundleID ?? opened.bundleID, pid: opened.pid)
                    windows[opened.pid] = CGRect(x: 100, y: 100, width: 900, height: 700)
                }
            case "mute": muted.toggle()
            case "cmd+c": if let copies { clipboard = copies; clipboardCount += 1 }
            case "cmd+shift+3", "cmd+shift+4": screenshotFile = URL(fileURLWithPath: "/Users/x/Desktop/Screenshot 1.png")
            case "ctrl+cmd+shift+3", "ctrl+cmd+shift+4": clipboardCount += 1
            default: break
            }
            guard keysWork else { return }
            let steps: [String: (Bool, Double)] = [
                "volume_up": (true, 6.25), "volume_down": (false, 6.25),
                "option+shift+volume_up": (true, 1.5625), "option+shift+volume_down": (false, 1.5625),
                "shift+option+volume_up": (true, 1.5625), "shift+option+volume_down": (false, 1.5625),
            ]
            if let (up, step) = steps[combo], let level = volume {
                volume = LevelSteps.next(level, step: step, up: up)
                if up { muted = false }
            }
            let brightnessSteps: [String: (Bool, Double)] = [
                "brightness_up": (true, 6.25), "brightness_down": (false, 6.25),
                "shift+option+brightness_up": (true, 1.5625), "shift+option+brightness_down": (false, 1.5625),
            ]
            if let (up, step) = brightnessSteps[combo], let level = brightness {
                brightness = LevelSteps.next(level, step: step, up: up)
            }
        }
    }

    func typedIntoSpotlight(_ text: String) { lock.withLock { if spotlight { spotlightText += text } } }

    // SystemReading
    func outputVolume() -> (percent: Double, muted: Bool)? { lock.withLock { volume.map { ($0, muted) } } }
    func displayBrightness() -> Double? { lock.withLock { brightness } }
    func frontApp() -> FrontApp? { lock.withLock { front } }
    func frontWindowFrame(pid: pid_t) -> CGRect? { lock.withLock { windows[pid] } }
    func windowTitle(pid: pid_t) -> String { lock.withLock { titles[pid] ?? "" } }
    func appsWithWindows() -> [String] { lock.withLock { visible } }
    func installedApps() -> [InstalledApp] { lock.withLock { apps } }
    func defaultBrowser() -> InstalledApp? { lock.withLock { browser } }
    func spotlightIsOpen() -> Bool { lock.withLock { spotlight } }
    func spotlightShowsResults() -> Bool { lock.withLock { spotlight && !spotlightText.isEmpty } }
    /// A window that grabs the keyboard (an updater, a password prompt). Applied at
    /// once, or only after something is typed into Spotlight when `popupAfterTyping`.
    var popup: KeyboardFocus?
    var popupAfterTyping = false
    /// Pretend the accessibility system can't say where the keyboard is.
    var focusUnknown = false
    /// The role of the focused control in the front app.
    var focusedRole = "AXTextArea"

    func keyboardFocus() -> KeyboardFocus? {
        lock.withLock {
            if focusUnknown { return nil }
            if let popup, !popupAfterTyping || !spotlightText.isEmpty { return popup }
            if spotlight {
                return KeyboardFocus(appName: "Spotlight", bundleID: "com.apple.Spotlight", pid: 77,
                                     role: "AXTextField", identifier: "SpotlightSearchField")
            }
            guard let front else { return nil }
            return KeyboardFocus(appName: front.name, bundleID: front.bundleID, pid: front.pid, role: focusedRole)
        }
    }
    func selectedText(pid: pid_t) -> String? { lock.withLock { selection } }
    func clipboardText() -> String? { lock.withLock { clipboard } }
    func clipboardChangeCount() -> Int { lock.withLock { clipboardCount } }
    func screenshotFolder() -> URL { URL(fileURLWithPath: "/Users/x/Desktop") }
    func newestScreenshot(since date: Date) -> URL? { lock.withLock { screenshotFile } }
    func isHostApp(_ app: FrontApp) -> Bool { lock.withLock { hostNames.contains(app.name) } }
    func mainDisplayBounds() -> CGRect { CGRect(x: 0, y: 0, width: 1470, height: 956) }
}

/// Typing into Spotlight goes to the fake Spotlight field. Records the pace asked for.
final class SpotlightAwareHands: Hands, PacedTyping, @unchecked Sendable {
    let inner = FakeHands()
    let system: FakeSystem
    private let paceLock = NSLock()
    private var paces: [TimeInterval] = []
    /// The pace of every paced typeText call, in order.
    var pacedIntervals: [TimeInterval] { paceLock.withLock { paces } }

    func typeText(_ text: String, allowReturn: Bool, characterInterval: TimeInterval) async throws {
        paceLock.withLock { paces.append(characterInterval) }
        try await typeText(text, allowReturn: allowReturn)
    }
    init(system: FakeSystem) {
        self.system = system
        system.react(to: inner)
    }
    func halt() { inner.halt() }
    func resume() { inner.resume() }
    var isHalted: Bool { inner.isHalted }
    var pointerPosition: CGPoint { inner.pointerPosition }
    func move(to point: CGPoint, duration: TimeInterval?) async throws { try await inner.move(to: point, duration: duration) }
    func click(at point: CGPoint, button: MouseButton, count: Int, modifiers: [KeyModifier]) async throws {
        try await inner.click(at: point, button: button, count: count, modifiers: modifiers)
    }
    func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval?) async throws {}
    func scroll(dx: Int, dy: Int, at point: CGPoint?) async throws { try await inner.scroll(dx: dx, dy: dy, at: point) }
    func key(_ combo: String) async throws { try await inner.key(combo) }
    func typeText(_ text: String, allowReturn: Bool) async throws {
        try await inner.typeText(text, allowReturn: allowReturn)
        system.typedIntoSpotlight(text)
    }
}

extension QuickTiming {
    static let fast: QuickTiming = {
        var timing = QuickTiming()
        timing.spotlightAppears = 0.05
        timing.spotlightResults = 0
        timing.appComesForward = 0.05
        timing.browserWindowAppears = 0.05
        timing.newTabReady = 0
        timing.clipboardUpdates = 0.05
        timing.screenshotSaved = 0.05
        timing.screenshotStep = 0
        timing.poll = 0.005
        return timing
    }()
}

/// Plays the app's safety guard: records every question, and answers as told.
final class RecordingGuard: QuickActionGuarding, @unchecked Sendable {
    struct Question: Equatable {
        let kind: ScreenAction.Kind
        let key: KeyChord?
        let point: CGPoint?
    }

    private let lock = NSLock()
    private var asked: [Question] = []
    /// How to answer; allows everything unless a test says otherwise.
    var answer: @Sendable (Question) -> QuickActionVerdict = { _ in .allow }
    /// Pretend the gate is slow.
    var delay: TimeInterval = 0

    var questions: [Question] { lock.withLock { asked } }

    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict {
        let question = Question(kind: kind, key: key, point: point)
        lock.withLock { asked.append(question) }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return answer(question)
    }
}

struct ToolHarness {
    let system = FakeSystem()
    let hands: SpotlightAwareHands
    let tools: [String: ToolSpec]
    /// Nil when the harness was built without a guard.
    let safety: RecordingGuard?

    /// With a guard that allows everything (and records what it was asked).
    init(guarded: Bool = true, timing: QuickTiming = .fast) {
        let recorder = guarded ? RecordingGuard() : nil
        safety = recorder
        hands = SpotlightAwareHands(system: system)
        tools = Dictionary(uniqueKeysWithValues: QuickTools.make(
            hands: hands, guard: recorder, system: system, timing: timing, layout: USKeyboardLayout()).map { ($0.name, $0) })
    }

    var recorded: FakeHands { hands.inner }

    func call(_ name: String, _ params: JSONObject = [:]) async -> JSONObject {
        await tools[name]!.handler(params)
    }
}

/// One short sentence that can be read aloud.
func isSpeakable(_ message: String?) -> Bool {
    guard let message, let last = message.last, ".?!".contains(last), message.count <= 230 else { return false }
    let inner = message.dropLast()
    return inner.range(of: #"[.?!]\s+[A-Z]"#, options: .regularExpression) == nil
        && !message.contains("Error") && !message.contains("error:")
}
