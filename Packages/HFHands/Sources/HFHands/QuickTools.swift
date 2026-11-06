import CoreGraphics
import Foundation
import HFCore

/// The quick voice tools: one spoken command, one visible action, done the way a
/// person at the keyboard would do it. Every action goes through `Hands`, so the
/// pointer moves and the keys land where the user can see them; the Mac's state
/// is only ever READ (the volume level, the app in front). docs/TOOLS.md lists
/// each tool with the exact keys it presses and the time it takes.
public enum QuickTools {
    /// - Parameters:
    ///   - hands: the real pointer and keyboard (or a fake in tests).
    ///   - actionGuard: asked immediately before any quick action that could commit
    ///     something (Return, Space, Delete outside a text field, Command+Q/W/D, every
    ///     pointer click). Without one, those actions are refused, never performed.
    ///   - system: reads the Mac's state; the real Mac by default.
    ///   - timing: how long to wait for the Mac to react; measured defaults.
    public static func make(
        hands: Hands, guard actionGuard: QuickActionGuarding? = nil, system: SystemReading = LiveSystem(),
        timing: QuickTiming = .standard
    ) -> [ToolSpec] {
        QuickToolbox(hands: hands, system: system, timing: timing, layout: LiveKeyboardLayout(), actionGuard: actionGuard).tools()
    }

    static func make(
        hands: Hands, guard actionGuard: QuickActionGuarding?, system: SystemReading, timing: QuickTiming,
        layout: KeyboardLayout
    ) -> [ToolSpec] {
        QuickToolbox(hands: hands, system: system, timing: timing, layout: layout, actionGuard: actionGuard).tools()
    }
}

/// The tools' shared state and their handlers.
struct QuickToolbox: Sendable {
    let hands: Hands
    let system: SystemReading
    let timing: QuickTiming
    let layout: KeyboardLayout
    let actionGuard: QuickActionGuarding?

    typealias Support = QuickToolSupport

    /// Refuses with the guard's spoken reason unless the guard allows this action now.
    func askGuard(_ kind: ScreenAction.Kind, key: KeyChord? = nil, at point: CGPoint? = nil) async throws {
        if let refusal = await QuickActionGuard.refusal(
            from: actionGuard, kind, key: key, at: point, timeout: timing.guardTimeout)
        {
            throw Refusal(refusal)
        }
    }

    /// Asks the guard about a key only when it can commit something; other keys stay instant.
    func askGuardIfCommitting(_ chord: Chord) async throws {
        guard let keyChord = KeyChord(chord.label),
            QuickActionGuard.mayCommit(keyChord, focusedRole: system.keyboardFocus()?.role ?? "")
        else { return }
        try await askGuard(.pressKey, key: keyChord)
    }

    /// Spotlight and address bars only filter as you type, so they take text quickly:
    /// measured, Calculator opened in 0.9 to 1.2 s at this pace against 1.3 to 1.9 s at
    /// the 40 ms default, 10 of 10 first time either way.
    static let searchFieldTypingInterval: TimeInterval = 0.008

    /// Refuses, with a spoken sentence, unless the next key will land where intended.
    func confirmLanding(_ destination: KeyDestination) throws {
        if let problem = KeyLanding.problem(focus: system.keyboardFocus(), front: system.frontApp(), destination: destination) {
            throw Refusal(problem)
        }
    }

    /// The browser, which must be the app in front by now.
    func browserInFront(_ browser: InstalledApp) throws -> FrontApp {
        guard let front = system.frontApp(), isFront(browser) else {
            throw Refusal("\(browser.name) isn't in front, so I didn't type the address.")
        }
        return front
    }

    /// Types into a search-like field at the quick pace when the hands support it.
    func typeQuickly(_ text: String) async throws {
        if let paced = hands as? PacedTyping {
            try await paced.typeText(text, allowReturn: false, characterInterval: Self.searchFieldTypingInterval)
        } else {
            try await hands.typeText(text, allowReturn: false)
        }
    }

    func tools() -> [ToolSpec] {
        [
            setVolumeTool(), setBrightnessTool(), mediaControlTool(), scrollTool(), openAppTool(), openURLTool(),
            pressKeysTool(), shortcutTool(), typeTextTool(), pointerTool(), whereAmITool(), readTextTool(),
            takeScreenshotTool(),
        ]
    }

    private func spec(
        _ name: String, _ description: String, properties: JSONObject, required: [String] = [], timeout: Int = 15,
        doing: String, _ body: @escaping @Sendable (JSONObject) async throws -> JSONObject
    ) -> ToolSpec {
        Support.spec(name, description, properties: properties, required: required, timeout: timeout, doing: doing,
                     hands: hands, body)
    }

    // MARK: - Volume and brightness, with the keyboard's own keys

    func setVolumeTool() -> ToolSpec {
        spec(
            "set_volume",
            "Change the Mac's sound volume with the keyboard's volume keys, or mute or unmute it. Use percent for an exact level ('volume to 30 percent' -> percent 30), change for relative requests ('turn it up' -> change 10, 'much quieter' -> change -25), or mute true or false. Send exactly one of the three. It reports the level actually reached, which can differ from the request by under one percent. Not for pausing music: use media_control.",
            properties: [
                "percent": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Exact level, 0 to 100."],
                "change": ["type": "integer", "minimum": -100, "maximum": 100, "description": "Relative change in percentage points, e.g. 10 or -10."],
                "mute": ["type": "boolean", "description": "true to mute, false to unmute."],
            ],
            timeout: 20, doing: "change the volume"
        ) { params in
            let percent = try Support.number(params, "percent", 0...100, "The volume")
            let change = try Support.number(params, "change", -100...100, "The volume change")
            let mute = try Support.flag(params, "mute")
            let given = [percent != nil, change != nil, mute != nil].filter { $0 }.count
            guard given > 0 else { throw Refusal("Tell me a volume level, how much to change it, or whether to mute.") }
            guard given == 1 else { throw Refusal("Give me just one of a volume level, a change, or mute.") }
            guard let current = system.outputVolume() else {
                throw Refusal("This sound output has no volume control I can change.")
            }
            if let mute {
                if current.muted != mute { try await hands.key("mute") }
                guard let after = system.outputVolume(), after.muted == mute else {
                    throw Refusal("I pressed the mute key, but the sound didn't \(mute ? "mute" : "unmute").")
                }
                return ToolResult.ok(["volume": .number(after.percent.rounded()), "muted": .bool(after.muted)])
            }
            let target = (percent ?? (current.percent + (change ?? 0))).clamped(to: 0...100)
            // Asking for a level you can hear means you want to hear it.
            if current.muted, target > 0 { try await hands.key("mute") }
            let result = try await adjust(
                to: target, read: { system.outputVolume()?.percent }, upKey: "volume_up", downKey: "volume_down")
            let muted = system.outputVolume()?.muted ?? false
            return ToolResult.ok([
                "volume": .number(result.level.rounded()), "requested": .number(target.rounded()),
                "muted": .bool(muted), "key_presses": .number(Double(result.presses)),
            ])
        }
    }

    func setBrightnessTool() -> ToolSpec {
        spec(
            "set_brightness",
            "Change the brightness of the Mac's built-in screen with the keyboard's brightness keys. Use percent for an exact level ('brightness to 50' -> percent 50) or change for relative requests ('brighter' -> change 15, 'dim the screen' -> change -20). Send exactly one.",
            properties: [
                "percent": ["type": "integer", "minimum": 0, "maximum": 100, "description": "Exact level, 0 to 100."],
                "change": ["type": "integer", "minimum": -100, "maximum": 100, "description": "Relative change, e.g. 15 or -20."],
            ],
            timeout: 20, doing: "change the brightness"
        ) { params in
            let percent = try Support.number(params, "percent", 0...100, "The brightness")
            let change = try Support.number(params, "change", -100...100, "The brightness change")
            guard (percent == nil) != (change == nil) else {
                throw Refusal("Tell me either a brightness level or how much to change it.")
            }
            guard let current = system.displayBrightness() else {
                throw Refusal("I can only change the brightness of the built-in screen.")
            }
            let target = (percent ?? (current + (change ?? 0))).clamped(to: 0...100)
            let result = try await adjust(
                to: target, read: { system.displayBrightness() }, upKey: "brightness_up", downKey: "brightness_down")
            return ToolResult.ok(["brightness": .number(result.level.rounded()), "requested": .number(target.rounded())])
        }
    }

    /// Presses the up or down key until the level is as close as the steps allow,
    /// reading the real level back after each round. At most three rounds.
    func adjust(to target: Double, read: () -> Double?, upKey: String, downKey: String) async throws -> (level: Double, presses: Int) {
        guard var level = read() else { throw Refusal("I couldn't read the current level.") }
        var presses = 0
        for _ in 0..<3 {
            let plan = LevelSteps.plan(from: level, to: target)
            if plan.isEmpty { break }
            for name in LevelSteps.keyNames(plan, up: upKey, down: downKey) {
                try await hands.key(name)
            }
            presses += plan.count
            guard let after = read() else { break }
            if abs(after - level) < 0.01 {
                throw Refusal("I pressed the keys, but the level didn't change.")
            }
            level = after
        }
        return (level, presses)
    }

    // MARK: - Media keys

    func mediaControlTool() -> ToolSpec {
        spec(
            "media_control",
            "Control whatever music or video is playing, with the keyboard's media keys: play_pause (one key for both play and pause, so it toggles), next or previous track. Example: 'pause the music' -> play_pause; 'skip this song' -> next. For loudness use set_volume.",
            properties: ["action": ["type": "string", "enum": ["play_pause", "next", "previous"],
                                   "description": "play_pause to play or pause what is playing; next or previous to skip a track."]],
            required: ["action"], doing: "control the music"
        ) { params in
            let action = try Support.choice(
                params, "action", ["play_pause", "next", "previous"], default: nil, "media action",
                synonyms: ["play": "play_pause", "pause": "play_pause", "resume": "play_pause", "stop": "play_pause",
                           "toggle": "play_pause", "skip": "next", "next_track": "next", "forward": "next",
                           "back": "previous", "prev": "previous", "previous_track": "previous", "rewind": "previous"])
            let key = ["play_pause": "play_pause", "next": "next_track", "previous": "previous_track"][action]!
            try await hands.key(key)
            return ToolResult.ok(["pressed": .string(key)])
        }
    }

    // MARK: - Scrolling

    static let scrollLines = ["a_little": 3, "page": 15, "a_lot": 45]
    /// Enough lines to reach the end of anything: the flick of a mouse wheel.
    static let scrollToEndLines = 10_000

    func scrollTool() -> ToolSpec {
        spec(
            "scroll",
            "Scroll the window in front with the mouse wheel: up, down, left or right by a_little, a page (default) or a_lot, or all the way to the top or bottom. If the pointer isn't over that window it first glides there. Example: 'scroll down' -> direction down; 'scroll up a bit' -> direction up, amount a_little; 'go to the bottom' -> direction bottom.",
            properties: [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"],
                              "description": "Which way to scroll; top or bottom jumps to the start or end of the page."],
                "amount": ["type": "string", "enum": ["a_little", "page", "a_lot"], "description": "Default page."],
            ],
            required: ["direction"], doing: "scroll"
        ) { params in
            let direction = try Support.choice(
                params, "direction", ["up", "down", "left", "right", "top", "bottom"], default: nil, "direction",
                synonyms: ["to_top": "top", "start": "top", "beginning": "top", "to_bottom": "bottom", "end": "bottom"])
            let amount = try Support.choice(
                params, "amount", ["a_little", "page", "a_lot"], default: "page", "amount",
                synonyms: ["little": "a_little", "a_bit": "a_little", "bit": "a_little", "small": "a_little",
                           "screen": "page", "one_page": "page", "normal": "page", "lot": "a_lot", "far": "a_lot",
                           "lots": "a_lot", "much": "a_lot"])
            guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
            guard let window = system.frontWindowFrame(pid: front.pid) else {
                throw Refusal("There's no window open in \(front.name) to scroll.")
            }
            // A scroll goes to the window under the pointer, so put the pointer over the
            // front window first, unless it already is (it may be over a particular pane).
            let target: CGPoint? = window.contains(hands.pointerPosition) ? nil : CGPoint(x: window.midX, y: window.midY)
            let lines = direction == "top" || direction == "bottom" ? Self.scrollToEndLines : Self.scrollLines[amount]!
            let dy = ["down": lines, "bottom": lines, "up": -lines, "top": -lines][direction] ?? 0
            let dx = ["right": lines, "left": -lines][direction] ?? 0
            try await hands.scroll(dx: dx, dy: dy, at: target)
            var result: JSONObject = ["app": .string(front.name), "scrolled": .string(direction)]
            if direction != "top", direction != "bottom" { result["amount"] = .string(amount) }
            return ToolResult.ok(result)
        }
    }

    // MARK: - Opening apps, through Spotlight

    func openAppTool() -> ToolSpec {
        spec(
            "open_app",
            "Open an app, or switch to it if it's already open, the way a person does: Command+Space, type the name into Spotlight, Return. Use for 'open Spotify', 'switch to Chrome', 'go to WhatsApp'. Say the name as the user said it ('vs code', 'chrome', 'settings'); the tool finds the installed app. If it answers with options or suggestions, ask the user which one. To open a website use open_url.",
            properties: ["name": ["type": "string", "description": "App name as spoken, e.g. 'chrome' or 'whatsapp'."]],
            required: ["name"], timeout: 25, doing: "open that app"
        ) { params in
            let spoken = try Support.text(params, "name", "app name", maxLength: 100).trimmingCharacters(in: .whitespaces)
            switch AppMatching.find(spoken, in: system.installedApps()) {
            case .found(let app):
                let attempts = try await openWithSpotlight(app)
                return ToolResult.ok([
                    "app": .string(app.name), "was_in_front": .bool(attempts == 0),
                    "spotlight_attempts": .number(Double(attempts)),
                ])
            case .ambiguous(let options):
                let spokenList = Array(options.prefix(3))
                let listed = spokenList.dropLast().joined(separator: ", ") + " or " + spokenList.last!
                let more = options.count > 3 ? " and others" : ""
                return ToolResult.failure("I found several, like \(listed)\(more); which one?",
                                          ["options": .array(options.map { .string($0) })])
            case .notFound(let suggestions) where !suggestions.isEmpty:
                return ToolResult.failure(
                    "I couldn't find an app called \(spoken). Did you mean \(suggestions.prefix(2).joined(separator: " or "))?",
                    ["suggestions": .array(suggestions.map { .string($0) })])
            case .notFound:
                return ToolResult.failure("I couldn't find an app called \(spoken) on this Mac.")
            }
        }
    }

    func isFront(_ app: InstalledApp) -> Bool {
        guard let front = system.frontApp() else { return false }
        if !app.bundleID.isEmpty, !front.bundleID.isEmpty { return front.bundleID == app.bundleID }
        return front.name == app.name
    }

    /// Command+Space, clear the field, type the app's exact name, wait for the
    /// top hit, Return, then check the app really came to the front.
    /// Returns how many Spotlight attempts it took: 0 when the app was already in front.
    @discardableResult
    func openWithSpotlight(_ app: InstalledApp) async throws -> Int {
        if isFront(app) { return 0 }
        // One retry: on the live Mac an occasional first attempt misses (a cold
        // Spotlight answers slowly), and a person would simply try again.
        for attempt in 1...2 {
            try confirmLanding(.system)  // never open Spotlight over a password or install prompt
            try await hands.key("cmd+space")
            guard try await Support.waitUntil(hands, timing.spotlightAppears, poll: timing.poll, { system.spotlightIsOpen() }) else {
                throw Refusal("Spotlight didn't open, so I couldn't open \(app.name).")
            }
            // Spotlight keeps the last search; select it so typing replaces it.
            try confirmLanding(.spotlightField)
            try await hands.key("cmd+a")
            // The exact installed name ranks the app as Spotlight's top hit, ahead of
            // files and web suggestions that merely mention it.
            try confirmLanding(.spotlightField)
            try await typeQuickly(app.name)
            // Wait for the results list to appear, then a moment for the top hit to settle.
            _ = try await Support.waitUntil(hands, timing.spotlightAppears, poll: timing.poll, { system.spotlightShowsResults() })
            try await Support.sleep(hands, timing.spotlightResults)
            // Right before Return, make sure it will go to Spotlight's field: a window
            // that pops up meanwhile (an updater, a password prompt) must never get it.
            guard system.spotlightIsOpen() else { throw Refusal("Spotlight closed before I could open \(app.name).") }
            try confirmLanding(.spotlightField)
            try await hands.key("return")
            if try await Support.waitUntil(hands, timing.appComesForward, poll: timing.poll, { isFront(app) }) { return attempt }
            if system.spotlightIsOpen() {
                try confirmLanding(.spotlightField)  // an Escape elsewhere could cancel the user's own dialog
                try await hands.key("escape")
                try confirmLanding(.spotlightField)
                try await hands.key("escape")  // the first Escape only clears the field
            }
            Support.logger.info("Spotlight attempt \(attempt) did not bring \(app.name, privacy: .public) forward")
        }
        throw Refusal("I typed \(app.name) into Spotlight, but it didn't come to the front.")
    }

    // MARK: - Web pages, through the browser's address bar

    func openURLTool() -> ToolSpec {
        spec(
            "open_url",
            "Open a web page in a new tab of the default browser, the way a person does: bring the browser forward, Command+T, type the address, Return. Use url for an address or bare domain ('open bbc.co.uk' -> url 'bbc.co.uk'), or search for a quick web search ('google cheap flights to Rome' -> search 'cheap flights to Rome'). Send exactly one. The final Return is checked by the safety gate; if it refuses, use start_task. For tasks on a site (booking, filling forms, reading email) use the task tool.",
            properties: [
                "url": ["type": "string", "description": "A web address, e.g. 'youtube.com' or 'https://x.com/home'."],
                "search": ["type": "string", "description": "Words to search the web for."],
            ],
            timeout: 30, doing: "open that page"
        ) { params in
            let raw = params["url"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let query = params["search"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            guard (raw == nil) != (query == nil) else { throw Refusal("Tell me either a web address or what to search for.") }
            let typed: String
            if let query {
                guard query.count <= 300, !query.contains(where: \.isNewline) else { throw Refusal("That search is too long.") }
                typed = query  // the address bar searches with the browser's own search engine
            } else {
                guard let url = URLRules.normalise(raw!) else {
                    throw Refusal("That doesn't look like a web address; I can search the web for it instead.")
                }
                typed = url
            }
            guard let browser = system.defaultBrowser() else { throw Refusal("I couldn't find a web browser on this Mac.") }
            try await openWithSpotlight(browser)
            // A browser that was just launched may need a moment to show a window.
            if system.frontApp().map({ system.frontWindowFrame(pid: $0.pid) == nil }) ?? true {
                if !(try await Support.waitUntil(hands, timing.browserWindowAppears, poll: timing.poll, {
                    system.frontApp().map { system.frontWindowFrame(pid: $0.pid) != nil } ?? false
                })) {
                    try confirmLanding(.app(try browserInFront(browser)))
                    try await hands.key("cmd+n")
                }
            }
            // Every key goes to the browser, and the Return to its address bar.
            let browserApp = try browserInFront(browser)
            // A new tab keeps whatever page the user already had open.
            try confirmLanding(.app(browserApp))
            try await hands.key("cmd+t")
            try await Support.sleep(hands, timing.newTabReady)
            try confirmLanding(.textInput(browserApp))
            try await typeQuickly(typed)
            try confirmLanding(.textInput(browserApp))
            try await askGuard(.pressKey, key: KeyChord(key: "return"))  // the safety gate judges this Return
            try await hands.key("return")
            var result: JSONObject = ["browser": .string(browser.name)]
            result[query == nil ? "url" : "search"] = .string(typed)
            return ToolResult.ok(result)
        }
    }

    // MARK: - Keys and shortcuts

    /// Shortcuts that close or quit the app in front, refused when that app is the one we run in.
    static let closers: Set<String> = ["cmd+q", "cmd+w", "shift+cmd+w", "option+cmd+w"]

    func checkSafe(_ chords: [Chord], front: FrontApp?) throws {
        for chord in chords {
            if chord.label == "ctrl+cmd+q" {
                throw Refusal("I won't lock the screen, because I can't unlock it for you.")
            }
            if let front, system.isHostApp(front), Self.closers.contains(chord.label) {
                throw Refusal("That would close \(front.name), which is where I'm running.")
            }
        }
    }

    func pressKeysTool() -> ToolSpec {
        spec(
            "press_keys",
            "Press a key or keyboard shortcut in the app in front. Write keys as words: 'command s', 'command shift t', 'escape', 'enter', 'tab', 'down down enter', 'page down', 'f5'. Use times to repeat ('press down three times' -> keys 'down', times 3). Prefer the shortcut tool for common actions like copy, undo or next tab. Keys that can send, submit, delete or close (Return or Enter, Space, Delete outside a text field, Command+Q, Command+W) are checked by the safety gate first; if it refuses, the action needs the user's confirmation, so do it with start_task instead.",
            properties: [
                "keys": ["type": "string", "description": "Keys to press, e.g. 'command shift t' or 'down down enter'."],
                "times": ["type": "integer", "minimum": 1, "maximum": 20, "description": "Repeat count, default 1."],
            ],
            required: ["keys"], doing: "press those keys"
        ) { params in
            let spoken = try Support.text(params, "keys", "keys to press", maxLength: 200)
            let times = Int(try Support.number(params, "times", 1...20, "The number of times") ?? 1)
            let chords = try KeyTable.parse(spoken, layout: layout)
            guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
            try checkSafe(chords, front: front)
            for _ in 0..<times {
                for chord in chords {
                    try confirmLanding(destination(for: chord, front: front))
                    try await askGuardIfCommitting(chord)
                    try await hands.key(chord.label)
                }
            }
            return ToolResult.ok([
                "pressed": .array(chords.map { .string($0.label) }), "times": .number(Double(times)),
                "app": .string(front.name),
            ])
        }
    }

    /// Shortcuts handled by the system rather than the window in front.
    static let systemShortcuts: Set<String> = [
        "cmd+space", "cmd+tab", "shift+cmd+tab", "ctrl+up", "ctrl+down", "ctrl+left", "ctrl+right",
        "shift+cmd+3", "shift+cmd+4", "shift+cmd+5", "ctrl+shift+cmd+3", "ctrl+shift+cmd+4",
    ]

    /// Where a chord the user asked for should land: the app in front, or anywhere
    /// for a system shortcut (but never a password or install prompt). An explicit
    /// "press enter" may mean a button the user can see, so it is not limited to
    /// text fields; the Returns the tools add themselves (after typing, in an
    /// address bar) are.
    func destination(for chord: Chord, front: FrontApp) -> KeyDestination {
        Self.systemShortcuts.contains(chord.label) ? .system : .app(front)
    }

    /// Each action and the shortcut a person would press for it.
    static let shortcuts: [(action: String, keys: String)] = [
        ("copy", "cmd+c"), ("cut", "cmd+x"), ("paste", "cmd+v"), ("undo", "cmd+z"), ("redo", "cmd+shift+z"),
        ("select_all", "cmd+a"), ("save", "cmd+s"), ("find", "cmd+f"),
        ("new_tab", "cmd+t"), ("close_tab", "cmd+w"), ("reopen_tab", "cmd+shift+t"), ("next_tab", "ctrl+tab"),
        ("previous_tab", "ctrl+shift+tab"), ("back", "cmd+["), ("forward", "cmd+]"), ("reload", "cmd+r"),
        ("zoom_in", "cmd+="), ("zoom_out", "cmd+-"), ("actual_size", "cmd+0"),
        ("new_window", "cmd+n"), ("close_window", "cmd+w"), ("minimise", "cmd+m"), ("fullscreen", "ctrl+cmd+f"),
        ("next_window", "cmd+`"), ("previous_app", "cmd+tab"), ("hide_app", "cmd+h"), ("hide_others", "cmd+option+h"),
        ("quit_app", "cmd+q"), ("mission_control", "ctrl+up"), ("spotlight", "cmd+space"),
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    func shortcutTool() -> ToolSpec {
        let actions = Self.shortcuts.map(\.action)
        return spec(
            "shortcut",
            "Do a common action in the app in front by pressing its real keyboard shortcut. Editing: copy, cut, paste, undo, redo, select_all, save, find. Browser tabs and pages: new_tab, close_tab, reopen_tab, next_tab, previous_tab, back, forward, reload, zoom_in, zoom_out, actual_size. Windows and apps: new_window, close_window, minimise, fullscreen, next_window (same app), previous_app (the app you were just in), hide_app, hide_others, quit_app, mission_control, spotlight. Example: 'close this tab' -> close_tab; 'go back' -> back. close_tab, close_window and quit_app are checked by the safety gate first; if it refuses, use start_task. To open or switch to a named app use open_app.",
            properties: ["action": ["type": "string", "enum": .array(actions.map { .string($0) }),
                                   "description": "Which common action to do with its keyboard shortcut, from the list above."]],
            required: ["action"], doing: "do that"
        ) { params in
            let action = try Support.choice(
                params, "action", actions, default: nil, "action",
                synonyms: ["minimize": "minimise", "full_screen": "fullscreen", "maximise": "fullscreen",
                           "maximize": "fullscreen", "refresh": "reload", "go_back": "back", "go_forward": "forward",
                           "reopen_closed_tab": "reopen_tab", "switch_window": "next_window", "last_app": "previous_app",
                           "switch_app": "previous_app", "quit": "quit_app", "close": "close_tab", "search": "find",
                           "hide": "hide_app", "prev_tab": "previous_tab"])
            guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
            var keys = Self.shortcuts.first { $0.action == action }!.keys
            if action == "close_window", Self.browsers.contains(front.bundleID) {
                keys = "cmd+shift+w"  // in a browser Command+W closes only the tab
            }
            if action == "quit_app", system.isHostApp(front) {
                throw Refusal("I can't quit \(front.name), because that's where I'm running.")
            }
            let chords = try KeyTable.parse(keys, layout: layout)
            try checkSafe(chords, front: front)
            try confirmLanding(destination(for: chords[0], front: front))
            try await askGuardIfCommitting(chords[0])
            try await hands.key(chords[0].label)
            return ToolResult.ok(["action": .string(action), "pressed": .string(chords[0].label), "app": .string(front.name)])
        }
    }

    // MARK: - Typing

    func typeTextTool() -> ToolSpec {
        spec(
            "type_text",
            "Type text into whatever field has focus in the app in front, exactly as given: punctuation, capitals, emoji and any language. It never presses enter unless press_enter is true, so it never sends a chat message by itself; set press_enter only when the user says to send or submit. The Return and any line break are checked by the safety gate first; if it refuses, do the sending with start_task, which asks the user to confirm. A line break in the text is typed as Shift+Return, a new line that doesn't send. To write and send a message in an app, use the task tool. Example: 'type hello world' -> text 'hello world'.",
            properties: [
                "text": ["type": "string", "description": "Exactly what to type."],
                "press_enter": ["type": "boolean", "description": "Press enter after typing. Default false."],
            ],
            required: ["text"], timeout: 100, doing: "type that"
        ) { params in
            guard let raw = params["text"]?.stringValue,
                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Refusal("There's no text to type.") }
            guard raw.count <= 2000 else { throw Refusal("That's too much text to type at once; try a shorter piece.") }
            let pressEnter = try Support.flag(params, "press_enter") ?? false
            guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
            func stillFront() -> Bool { system.frontApp()?.pid == front.pid }

            let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(
                omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            // Ask before typing anything, so a refused send leaves no half-typed draft
            // for the task to type again; and ask again at the moment of each key.
            if pressEnter { try await askGuard(.pressKey, key: KeyChord(key: "return")) }
            if lines.count > 1 { try await askGuard(.typeLineBreak) }
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    try confirmLanding(.textInput(front))
                    try await askGuard(.typeLineBreak)
                    try await hands.key("shift+return")
                }
                // Type in short pieces and check between them that the same app is in
                // front, so the rest of a sentence never lands somewhere else.
                for piece in Self.pieces(of: String(line), size: 40) {
                    guard stillFront() else {
                        let now = system.frontApp()?.name ?? "another app"
                        throw Refusal("I stopped typing because \(now) came to the front.")
                    }
                    try confirmLanding(.app(front))  // never type into a prompt that took the keyboard
                    try await hands.typeText(piece, allowReturn: false)
                }
            }
            guard stillFront() else {
                throw Refusal("The app in front changed while I was typing, so please check where the text went.")
            }
            if pressEnter {
                // The Return must reach the field just typed into, never a dialog's default button,
                // and the safety gate must agree it doesn't send anything that needs confirming.
                try confirmLanding(.textInput(front))
                try await askGuard(.pressKey, key: KeyChord(key: "return"))
                try await hands.key("return")
            }
            return ToolResult.ok([
                "typed": .number(Double(raw.count)), "app": .string(front.name), "pressed_enter": .bool(pressEnter),
            ])
        }
    }

    static func pieces(of text: String, size: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= size { pieces.append(current); current = "" }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - The pointer

    static let pointerDistances: [String: CGFloat] = ["a_little": 40, "some": 150, "a_lot": 400]

    func pointerTool() -> ToolSpec {
        spec(
            "pointer",
            "Use the mouse pointer directly, for when the user knows exactly what they want: click, double_click or right_click where the pointer is now, or move it up, down, left or right by a_little, some (default) or a_lot. Example: 'click' -> action click; 'move the mouse left a bit' -> action move, direction left, amount a_little. Every click is checked by the safety gate first; if it refuses, do it with start_task instead. To click a named button or link, use the task tool.",
            properties: [
                "action": ["type": "string", "enum": ["click", "double_click", "right_click", "move"],
                           "description": "click, double_click or right_click where the pointer is now, or move it (with direction and amount)."],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "For move."],
                "amount": ["type": "string", "enum": ["a_little", "some", "a_lot"], "description": "For move. Default some."],
            ],
            required: ["action"], doing: "use the pointer"
        ) { params in
            let action = try Support.choice(
                params, "action", ["click", "double_click", "right_click", "move"], default: nil, "pointer action",
                synonyms: ["left_click": "click", "tap": "click", "double": "double_click", "doubleclick": "double_click",
                           "secondary_click": "right_click", "context_click": "right_click", "rightclick": "right_click"])
            let here = hands.pointerPosition
            switch action {
            case "move":
                let direction = try Support.choice(params, "direction", ["up", "down", "left", "right"], default: nil, "direction")
                let amount = try Support.choice(
                    params, "amount", ["a_little", "some", "a_lot"], default: "some", "amount",
                    synonyms: ["little": "a_little", "a_bit": "a_little", "bit": "a_little", "lot": "a_lot", "far": "a_lot"])
                let distance = Self.pointerDistances[amount]!
                let offset = ["up": CGPoint(x: 0, y: -distance), "down": CGPoint(x: 0, y: distance),
                              "left": CGPoint(x: -distance, y: 0), "right": CGPoint(x: distance, y: 0)][direction]!
                // Stop at the screen's edge rather than refusing a move that goes past it.
                let screen = system.mainDisplayBounds()
                let target = CGPoint(
                    x: min(max(here.x + offset.x, screen.minX), screen.maxX - 1),
                    y: min(max(here.y + offset.y, screen.minY), screen.maxY - 1))
                try await hands.move(to: target, duration: nil)
            // Every click asks the safety gate first: the pointer may be over a Send button.
            case "double_click":
                try await askGuard(.doubleClick, at: here)
                try await hands.click(at: here, button: .left, count: 2, modifiers: [])
            case "right_click":
                try await askGuard(.rightClick, at: here)
                try await hands.click(at: here, button: .right, count: 1, modifiers: [])
            default:
                try await askGuard(.click, at: here)
                try await hands.click(at: here, button: .left, count: 1, modifiers: [])
            }
            let now = hands.pointerPosition
            return ToolResult.ok(["action": .string(action), "x": .number(now.x.rounded()), "y": .number(now.y.rounded())])
        }
    }

    // MARK: - Reading the screen

    func whereAmITool() -> ToolSpec {
        spec(
            "where_am_i",
            "Say which app and window are in front and which other apps have windows open. Use when the user asks 'where am I' or 'what's open', or before typing if you are not sure where the text will go.",
            properties: [:], doing: "check what's on screen"
        ) { _ in
            guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
            let others = system.appsWithWindows().filter { $0 != front.name }.prefix(8)
            return ToolResult.ok([
                "app": .string(front.name), "window": .string(system.windowTitle(pid: front.pid)),
                "other_apps": .array(others.map { .string($0) }),
            ])
        }
    }

    func readTextTool() -> ToolSpec {
        spec(
            "read_text",
            "Get text so you can read it to the user: the selected text in the app in front (source selection, the default) or the clipboard (source clipboard). If the app doesn't report its selection, this presses Command+C, so the selection ends up on the clipboard, as when a person copies. Example: 'read this to me' -> selection; 'what did I copy' -> clipboard. To read a whole page or email use the task tool.",
            properties: ["source": ["type": "string", "enum": ["selection", "clipboard"], "description": "Default selection."]],
            doing: "read that text"
        ) { params in
            let source = try Support.choice(
                params, "source", ["selection", "clipboard"], default: "selection", "source",
                synonyms: ["selected": "selection", "highlighted": "selection", "copied": "clipboard"])
            var text: String?
            var copied = false
            if source == "clipboard" {
                text = system.clipboardText()
                if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    throw Refusal("There's no text on the clipboard.")
                }
            } else {
                guard let front = system.frontApp() else { throw Refusal("I can't tell which app is in front right now.") }
                text = system.selectedText(pid: front.pid)
                if text == nil {
                    // Many web and Electron apps don't report their selection: copy it, as a person would.
                    let before = system.clipboardChangeCount()
                    try confirmLanding(.app(front))
                    try await hands.key("cmd+c")
                    if try await Support.waitUntil(hands, timing.clipboardUpdates, poll: timing.poll, {
                        system.clipboardChangeCount() != before
                    }) {
                        text = system.clipboardText()
                        copied = true
                    }
                }
                if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    throw Refusal("Nothing is selected.")
                }
            }
            let full = text!
            return ToolResult.ok([
                "source": .string(source), "text": .string(String(full.prefix(4000))),
                "truncated": .bool(full.count > 4000), "copied_to_clipboard": .bool(copied),
            ])
        }
    }

    // MARK: - Screenshots, with the system's own shortcuts

    func takeScreenshotTool() -> ToolSpec {
        spec(
            "take_screenshot",
            "Take a screenshot with the Mac's own shortcuts: the whole screen (Command+Shift+3, the default) or just the window in front (Command+Shift+4, Space, click the window). It is saved where the user's screenshots usually go, or copied to the clipboard instead with to_clipboard true. Example: 'screenshot this window' -> target window.",
            properties: [
                "target": ["type": "string", "enum": ["screen", "window"], "description": "Default screen."],
                "to_clipboard": ["type": "boolean", "description": "Copy instead of saving a file. Default false."],
            ],
            timeout: 20, doing: "take a screenshot"
        ) { params in
            let target = try Support.choice(
                params, "target", ["screen", "window"], default: "screen", "target",
                synonyms: ["whole_screen": "screen", "everything": "screen", "front_window": "window", "app": "window"])
            let toClipboard = try Support.flag(params, "to_clipboard") ?? false
            let started = Date().addingTimeInterval(-1)
            let clipboardBefore = system.clipboardChangeCount()
            let modifiers = toClipboard ? "ctrl+cmd+shift" : "cmd+shift"
            if target == "window" {
                guard let front = system.frontApp(), let window = system.frontWindowFrame(pid: front.pid) else {
                    throw Refusal("There's no window in front to capture.")
                }
                try confirmLanding(.system)
                try await hands.key("\(modifiers)+4")
                try await Support.sleep(hands, timing.screenshotStep)
                try confirmLanding(.system)
                try await hands.key("space")  // switches the crosshair to picking a window
                try await Support.sleep(hands, timing.screenshotStep)
                // Click the window's title bar, not its middle: if the screenshot shortcut
                // didn't take, a title bar click does nothing, where the middle might be a
                // Send button. The safety gate is asked all the same.
                let titleBar = CGPoint(x: window.midX, y: window.minY + 12)
                try await askGuard(.click, at: titleBar)
                try await hands.click(at: titleBar)
            } else {
                try confirmLanding(.system)
                try await hands.key("\(modifiers)+3")
            }
            if toClipboard {
                guard try await Support.waitUntil(hands, timing.screenshotSaved, poll: timing.poll * 4, {
                    system.clipboardChangeCount() != clipboardBefore
                }) else { throw Refusal("I pressed the screenshot keys, but nothing reached the clipboard.") }
                return ToolResult.ok(["target": .string(target), "saved_to": "clipboard"])
            }
            var saved: URL?
            _ = try await Support.waitUntil(hands, timing.screenshotSaved, poll: timing.poll * 4) {
                saved = system.newestScreenshot(since: started)
                return saved != nil
            }
            guard let saved else { throw Refusal("I pressed the screenshot keys, but I can't find the picture yet.") }
            return ToolResult.ok([
                "target": .string(target), "path": .string(saved.path), "folder": .string(saved.deletingLastPathComponent().lastPathComponent),
            ])
        }
    }
}

/// Which web addresses open_url accepts.
enum URLRules {
    /// A safe http(s) URL from what the user said, or nil if it isn't one.
    /// Refuses other schemes (file:, javascript:, app links): a misheard or
    /// injected link must not run something on the Mac.
    static func normalise(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "<>\"'")))
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") {
            if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:(?!\d)"#, options: .regularExpression) != nil { return nil }
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty
        else { return nil }
        let hostPattern = #"^(localhost|(\d{1,3}\.){3}\d{1,3}|([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})$"#
        guard host.range(of: hostPattern, options: .regularExpression) != nil else { return nil }
        return text
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
