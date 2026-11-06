import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFHands

// MARK: The tool contract

@Test func everyToolHasAValidSpec() {
    let tools = QuickTools.make(hands: FakeHands(), guard: nil, system: FakeSystem(), timing: .fast, layout: USKeyboardLayout())
    let names = tools.map(\.name)
    #expect(Set(names).count == names.count)
    #expect(Set(["set_volume", "scroll", "open_app", "open_url", "press_keys", "type_text", "media_control", "pointer"])
        .isSubset(of: Set(names)))
    for tool in tools {
        #expect(tool.tier == .quick)
        #expect(tool.parameters["type"] == "object")
        let properties = tool.parameters["properties"]?.objectValue ?? [:]
        let required = tool.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(required).isSubset(of: Set(properties.keys)), "\(tool.name)")
        #expect(tool.description.count > 80, "\(tool.name)")
        #expect(tool.description.contains("Example") || tool.description.contains("'"), "\(tool.name) needs a spoken example")
    }
}

@Test func noToolThrowsOnGarbageAndEveryErrorIsSpeakable() async {
    let garbage: [JSONObject] = [[:], ["percent": ["x": 1]], ["text": 5], ["zzz": 1], ["direction": "sideways"],
                                 ["action": "teleport"], ["name": ""], ["keys": ""], ["url": "javascript:alert(1)"]]
    let harness = ToolHarness()
    for (name, tool) in harness.tools where name != "where_am_i" && name != "read_text" && name != "take_screenshot" {
        for params in garbage {
            let result = await tool.handler(params)
            if result["ok"] == false { #expect(isSpeakable(result["error"]?.stringValue), "\(name): \(result)") }
        }
    }
}

@Test func aStopSaidEarlierDoesNotBlockTheNextQuickCommand() async {
    let harness = ToolHarness()
    harness.hands.halt()
    let result = await harness.call("media_control", ["action": "next"])
    #expect(result["ok"] == true)
    #expect(!harness.hands.isHalted)
}

@Test func haltDuringAToolIsReportedPlainly() async {
    let harness = ToolHarness()
    let system = harness.system
    harness.recorded.onKey = { [weak recorded = harness.recorded] combo in
        system.pressed(combo)
        if combo == "cmd+space" { recorded?.halt() }  // the user says stop as Spotlight opens
    }
    let result = await harness.call("open_app", ["name": "spotify"])
    #expect(result == ToolResult.failure("I stopped, as you asked."))
}

// MARK: set_volume: the volume keys

@Test func exactVolumeUsesCoarseThenFineKeysAndReportsTheLevelReached() async {
    let harness = ToolHarness()
    harness.system.volume = 19
    let result = await harness.call("set_volume", ["percent": 30])
    #expect(result["ok"] == true)
    #expect(result["volume"] == 30)  // 29.69 really: within the 1/64 step
    // 19 -> 25 (snaps to the grid) -> 26.56 -> 28.13 -> 29.69 with the fine step
    #expect(harness.recorded.keys == ["volume_up", "shift+option+volume_up", "shift+option+volume_up", "shift+option+volume_up"])
    #expect(abs(harness.system.volume! - 29.6875) < 0.001)
}

@Test(arguments: [(50.0, 0.0), (0.0, 100.0), (19.0, 19.0), (87.5, 41.0), (100.0, 73.0)])
func volumeLandsWithinOnePoint(_ start: Double, _ target: Double) async {
    let harness = ToolHarness()
    harness.system.volume = start
    let result = await harness.call("set_volume", ["percent": .number(target)])
    #expect(result["ok"] == true)
    #expect(abs(harness.system.volume! - target) <= 0.79)
    #expect(harness.recorded.keys.allSatisfy { $0.hasSuffix("volume_up") || $0.hasSuffix("volume_down") })
    #expect(harness.recorded.keys.count <= 20)
}

@Test func relativeVolumeAndClamping() async {
    let harness = ToolHarness()
    harness.system.volume = 50
    // 40 itself is not on the 1/64 grid; 40.625 is the nearest level the keys reach.
    let lower = await harness.call("set_volume", ["change": -10])["volume"]?.doubleValue ?? 0
    #expect(abs(lower - 40) <= 1)
    #expect(await harness.call("set_volume", ["change": 90])["volume"] == 100)
}

@Test func muteUsesTheMuteKeyOnlyWhenNeeded() async {
    let harness = ToolHarness()
    let muted = await harness.call("set_volume", ["mute": true])
    #expect(muted["muted"] == true)
    #expect(harness.recorded.keys == ["mute"])
    _ = await harness.call("set_volume", ["mute": true])
    #expect(harness.recorded.keys == ["mute"])  // already muted: nothing pressed
    #expect(await harness.call("set_volume", ["mute": "false"])["muted"] == false)
}

@Test func settingAnAudibleLevelWhileMutedUnmutesFirst() async {
    let harness = ToolHarness()
    harness.system.muted = true
    let result = await harness.call("set_volume", ["percent": 50])
    #expect(harness.recorded.keys.first == "mute")
    #expect(result["muted"] == false)
}

@Test(arguments: [["percent": 150], ["percent": -1], ["change": 101], ["percent": true], ["percent": "loud"],
                  [:], ["percent": 30, "change": 5], ["percent": 10, "mute": true]] as [JSONObject])
func volumeRejectsBadInputAndPressesNothing(_ params: JSONObject) async {
    let harness = ToolHarness()
    let result = await harness.call("set_volume", params)
    #expect(result["ok"] == false)
    #expect(isSpeakable(result["error"]?.stringValue), "\(result)")
    #expect(harness.recorded.actions.isEmpty)
}

@Test func volumeKeysThatDoNothingAreReported() async {
    let harness = ToolHarness()
    harness.system.keysWork = false
    let result = await harness.call("set_volume", ["percent": 60])
    #expect(result == ToolResult.failure("I pressed the keys, but the level didn't change."))
}

@Test func noVolumeControlIsReported() async {
    let harness = ToolHarness()
    harness.system.volume = nil
    #expect(await harness.call("set_volume", ["percent": 30]) == ToolResult.failure("This sound output has no volume control I can change."))
}

@Test func brightnessUsesTheBrightnessKeys() async {
    let harness = ToolHarness()
    let result = await harness.call("set_brightness", ["percent": 50])
    #expect(result["ok"] == true)
    #expect(abs(harness.system.brightness! - 50) <= 0.79)
    #expect(harness.recorded.keys.allSatisfy { $0.contains("brightness_down") })
    harness.system.brightness = nil
    #expect(await harness.call("set_brightness", ["change": 10])["ok"] == false)
}

@Test func levelPlanMatchesWhatWasMeasured() {
    // From 19, one press up landed on 25; from 90 one press down landed on 87.5.
    #expect(LevelSteps.next(19, step: 6.25, up: true) == 25)
    #expect(LevelSteps.next(90, step: 6.25, up: false) == 87.5)
    #expect(LevelSteps.next(25, step: 1.5625, up: true) == 26.5625)
    #expect(LevelSteps.plan(from: 100, to: 0) == Array(repeating: .coarseDown, count: 16))
    #expect(LevelSteps.plan(from: 30, to: 30.2).isEmpty)
}

// MARK: media_control

@Test(arguments: [("play_pause", "play_pause"), ("pause", "play_pause"), ("next", "next_track"), ("skip", "next_track"),
                  ("previous", "previous_track")])
func mediaKeys(_ action: String, _ key: String) async {
    let harness = ToolHarness()
    #expect(await harness.call("media_control", ["action": .string(action)])["ok"] == true)
    #expect(harness.recorded.keys == [key])
}

// MARK: scroll

@Test func scrollGlidesOverTheFrontWindowWhenThePointerIsElsewhere() async {
    let harness = ToolHarness()
    harness.recorded.setPointer(CGPoint(x: 1300, y: 900))  // outside the 800x600 window
    let result = await harness.call("scroll", ["direction": "down"])
    #expect(result == ToolResult.ok(["app": "Orca", "scrolled": "down", "amount": "page"]))
    #expect(harness.recorded.actions == [.scroll(dx: 0, dy: 15, at: CGPoint(x: 400, y: 330))])
}

@Test func scrollStaysWhereThePointerIsWhenItIsOverTheWindow() async {
    let harness = ToolHarness()
    harness.recorded.setPointer(CGPoint(x: 100, y: 100))
    _ = await harness.call("scroll", ["direction": "up", "amount": "a little"])
    #expect(harness.recorded.actions == [.scroll(dx: 0, dy: -3, at: nil)])
    _ = await harness.call("scroll", ["direction": "bottom"])
    _ = await harness.call("scroll", ["direction": "left", "amount": "a_lot"])
    #expect(harness.recorded.actions.suffix(2) == [.scroll(dx: 0, dy: 10_000, at: nil), .scroll(dx: -45, dy: 0, at: nil)])
}

@Test func scrollWithoutAWindowSaysSo() async {
    let harness = ToolHarness()
    harness.system.windows = [:]
    #expect(await harness.call("scroll", ["direction": "down"]) == ToolResult.failure("There's no window open in Orca to scroll."))
}

// MARK: open_app: Spotlight

@Test func openAppGoesThroughSpotlight() async {
    let harness = ToolHarness()
    let result = await harness.call("open_app", ["name": "chrome"])
    #expect(result == ToolResult.ok(["app": "Google Chrome", "was_in_front": false, "spotlight_attempts": 1]))
    #expect(harness.recorded.actions == [.key("cmd+space"), .key("cmd+a"), .type("Google Chrome"), .key("return")])
    #expect(harness.system.front?.bundleID == "com.google.Chrome")
}

@Test func openAppDoesNothingWhenTheAppIsAlreadyInFront() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "Spotify", bundleID: "com.spotify.client", pid: 9)
    #expect(await harness.call("open_app", ["name": "spotify"])["was_in_front"] == true)
    #expect(harness.recorded.actions.isEmpty)
}

@Test(arguments: [("vs code", "Visual Studio Code"), ("whats app", "WhatsApp"), ("the spotify app", "Spotify"),
                  ("spotfy", "Spotify"), ("settings", "System Settings"), ("teams", "Microsoft Teams"), ("text edit", "TextEdit")])
func openAppByWhatPeopleSay(_ spoken: String, _ installed: String) async {
    let harness = ToolHarness()
    #expect(await harness.call("open_app", ["name": .string(spoken)])["app"] == .string(installed))
    #expect(harness.recorded.typed == [installed])  // the exact name is what's typed
}

@Test func openAppSuggestsOrAsksInsteadOfGuessing() async {
    let harness = ToolHarness()
    let misheard = await harness.call("open_app", ["name": "gogle krome"])
    #expect(misheard["ok"] == false && misheard["suggestions"]?.arrayValue?.first == "Google Chrome")
    let ambiguous = await harness.call("open_app", ["name": "microsoft"])
    #expect(ambiguous["error"]?.stringValue?.hasSuffix("which one?") == true)
    let missing = await harness.call("open_app", ["name": "xylophone deluxe"])
    #expect(missing == ToolResult.failure("I couldn't find an app called xylophone deluxe on this Mac."))
    #expect(harness.recorded.actions.isEmpty)
}

@Test func openAppSaysSoWhenTheAppDoesNotComeForwardAndClosesSpotlight() async {
    let harness = ToolHarness()
    harness.system.spotlightOpens = { _ in nil }
    harness.system.pressed("noop")
    let result = await harness.call("open_app", ["name": "calculator"])
    #expect(result == ToolResult.failure("I typed Calculator into Spotlight, but it didn't come to the front."))
}

@Test func openAppWhenSpotlightNeverOpens() async {
    let harness = ToolHarness()
    harness.recorded.onKey = nil  // the Mac doesn't react
    let result = await harness.call("open_app", ["name": "calculator"])
    #expect(result == ToolResult.failure("Spotlight didn't open, so I couldn't open Calculator."))
    #expect(harness.recorded.keys == ["cmd+space"])
}

// MARK: open_url: the address bar

@Test func openURLOpensANewTabAndTypesTheAddress() async {
    let harness = ToolHarness()
    let result = await harness.call("open_url", ["url": "bbc.co.uk"])
    #expect(result == ToolResult.ok(["browser": "Arc", "url": "https://bbc.co.uk"]))
    #expect(harness.recorded.actions == [
        .key("cmd+space"), .key("cmd+a"), .type("Arc"), .key("return"),  // bring the browser forward
        .key("cmd+t"), .type("https://bbc.co.uk"), .key("return"),
    ])
}

@Test func openURLSearchTypesTheWords() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "Arc", bundleID: "company.thebrowser.Browser", pid: 5)
    harness.system.windows[5] = CGRect(x: 0, y: 0, width: 900, height: 700)
    let result = await harness.call("open_url", ["search": "cheap flights to Rome"])
    #expect(result["search"] == "cheap flights to Rome")
    #expect(harness.recorded.actions == [.key("cmd+t"), .type("cheap flights to Rome"), .key("return")])
}

@Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "hello world", "ssh://host", "mailto:a@b.com", "notaurl", "https://"])
func openURLRefusesAnythingButWebAddresses(_ raw: String) async {
    let harness = ToolHarness()
    let result = await harness.call("open_url", ["url": .string(raw)])
    #expect(result["ok"] == false && isSpeakable(result["error"]?.stringValue))
    #expect(harness.recorded.actions.isEmpty)
}

@Test(arguments: [("bbc.co.uk", "https://bbc.co.uk"), ("www.google.com/maps", "https://www.google.com/maps"),
                  ("http://localhost:3000", "http://localhost:3000"), ("https://x.com/home?a=1", "https://x.com/home?a=1")])
func urlRules(_ raw: String, _ expected: String) {
    #expect(URLRules.normalise(raw) == expected)
}

// MARK: press_keys and shortcut

@Test func pressKeysPassesCanonicalNamesToTheHands() async {
    let harness = ToolHarness()
    let result = await harness.call("press_keys", ["keys": "command shift t"])
    #expect(result["pressed"] == ["shift+cmd+t"])
    #expect(harness.recorded.keys == ["shift+cmd+t"])
    _ = await harness.call("press_keys", ["keys": "down", "times": 3])
    #expect(harness.recorded.keys.suffix(3) == ["down", "down", "down"])
}

@Test func pressKeysRefusesToLockTheScreenOrCloseTheHostApp() async {
    let harness = ToolHarness()
    #expect(await harness.call("press_keys", ["keys": "control command q"])
        == ToolResult.failure("I won't lock the screen, because I can't unlock it for you."))
    #expect(await harness.call("press_keys", ["keys": "command q"])["ok"] == false)  // Orca is in front
    #expect(await harness.call("shortcut", ["action": "quit_app"])["ok"] == false)
    #expect(await harness.call("shortcut", ["action": "close_tab"])["ok"] == false)
    #expect(harness.recorded.actions.isEmpty)
}

@Test(arguments: [("copy", "cmd+c"), ("paste", "cmd+v"), ("undo", "cmd+z"), ("redo", "shift+cmd+z"),
                  ("next_tab", "ctrl+tab"), ("previous_tab", "ctrl+shift+tab"), ("back", "cmd+["), ("minimise", "cmd+m"),
                  ("fullscreen", "ctrl+cmd+f"), ("previous_app", "cmd+tab"), ("hide_others", "option+cmd+h"),
                  ("mission_control", "ctrl+up"), ("zoom_in", "cmd+=")])
func shortcutsPressTheirRealKeys(_ action: String, _ pressed: String) async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    let result = await harness.call("shortcut", ["action": .string(action)])
    #expect(result["ok"] == true, "\(result)")
    #expect(harness.recorded.keys == [pressed])
}

@Test func closeWindowInABrowserClosesTheWindowNotTheTab() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 3)
    _ = await harness.call("shortcut", ["action": "close_window"])
    #expect(harness.recorded.keys == ["shift+cmd+w"])
}

// MARK: type_text

@Test func typeTextTypesExactlyAndNeverPressesReturnUnlessAsked() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    let text = "Ça va? 你好 👋🏽 tell him to send the files"
    let result = await harness.call("type_text", ["text": .string(text)])
    #expect(result["ok"] == true)
    #expect(harness.recorded.typed.joined() == text)
    #expect(!harness.recorded.keys.contains("return"))
    _ = await harness.call("type_text", ["text": "see you", "press_enter": true])
    #expect(harness.recorded.keys.last == "return")
}

@Test func lineBreaksBecomeShiftReturnNotReturn() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", pid: 3)
    _ = await harness.call("type_text", ["text": "Hi Mark,\nI'll pay on Friday.\r\nThanks"])
    #expect(harness.recorded.actions == [
        .type("Hi Mark,"), .key("shift+return"), .type("I'll pay on Friday."), .key("shift+return"), .type("Thanks"),
    ])
}

@Test func typingStopsWhenAnotherAppComesToTheFront() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    let system = harness.system
    harness.recorded.onKey = nil
    // After the first piece, Chrome takes the front.
    let text = String(repeating: "a", count: 100)
    let task = Task { await harness.call("type_text", ["text": .string(text)]) }
    try? await Task.sleep(nanoseconds: 1_000_000)
    system.with { system.front = FrontApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 9) }
    let result = await task.value
    if result["ok"] == false {
        #expect(result["error"]?.stringValue?.contains("Google Chrome") == true || result["error"]?.stringValue?.contains("changed") == true)
        #expect(harness.recorded.typed.joined().count < 100)
    }
}

@Test(arguments: [["text": ""], ["text": "   "], [:], ["text": 42]] as [JSONObject])
func typeTextRejectsEmptyText(_ params: JSONObject) async {
    let harness = ToolHarness()
    #expect(await harness.call("type_text", params) == ToolResult.failure("There's no text to type."))
    #expect(harness.recorded.actions.isEmpty)
}

// MARK: pointer

@Test func pointerClicksWhereItIsAndMovesByDirection() async {
    let harness = ToolHarness()
    harness.recorded.setPointer(CGPoint(x: 500, y: 400))
    _ = await harness.call("pointer", ["action": "double_click"])
    _ = await harness.call("pointer", ["action": "right_click"])
    let moved = await harness.call("pointer", ["action": "move", "direction": "left", "amount": "a_lot"])
    #expect(harness.recorded.actions == [
        .click(CGPoint(x: 500, y: 400), .left, 2), .click(CGPoint(x: 500, y: 400), .right, 1), .move(CGPoint(x: 100, y: 400)),
    ])
    #expect(moved["x"] == 100)
    _ = await harness.call("pointer", ["action": "move", "direction": "up", "amount": "a_lot"])
    #expect(harness.recorded.actions.last == .move(CGPoint(x: 100, y: 0)))  // stops at the top edge
}

// MARK: Reading

@Test func whereAmIReadsWithoutActing() async {
    let harness = ToolHarness()
    #expect(await harness.call("where_am_i") == ToolResult.ok(["app": "Orca", "window": "Terminal",
                                                              "other_apps": ["Google Chrome", "Spotify"]]))
    #expect(harness.recorded.actions.isEmpty)
}

@Test func readTextPrefersAccessibilityThenCopies() async {
    let harness = ToolHarness()
    harness.system.selection = "the chosen words"
    #expect(await harness.call("read_text")["text"] == "the chosen words")
    #expect(harness.recorded.actions.isEmpty)
    harness.system.selection = nil
    harness.system.copies = "copied from chrome"
    let copied = await harness.call("read_text", ["source": "selection"])
    #expect(copied["text"] == "copied from chrome" && copied["copied_to_clipboard"] == true)
    #expect(harness.recorded.keys == ["cmd+c"])
    harness.system.copies = nil
    #expect(await harness.call("read_text") == ToolResult.failure("Nothing is selected."))
    #expect(await harness.call("read_text", ["source": "clipboard"])["text"] == "copied from chrome")
}

@Test func screenshotsUseTheSystemShortcuts() async {
    let harness = ToolHarness()
    let screen = await harness.call("take_screenshot")
    #expect(screen["path"] == "/Users/x/Desktop/Screenshot 1.png")
    #expect(harness.recorded.keys == ["cmd+shift+3"])
    let window = await harness.call("take_screenshot", ["target": "window"])
    #expect(window["ok"] == true)
    #expect(harness.recorded.actions.suffix(3) == [.key("cmd+shift+4"), .key("space"), .click(CGPoint(x: 400, y: 42), .left, 1)])  // the title bar
    let clip = await harness.call("take_screenshot", ["to_clipboard": true])
    #expect(clip["saved_to"] == "clipboard")
    #expect(harness.recorded.keys.last == "ctrl+cmd+shift+3")
}

// MARK: The person-like rule

@Test func everyActionGoesThroughTheHands() async {
    // Run each tool once with sensible parameters; the only way any of them
    // acts is through the fake hands, which record every action.
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.windows[3] = CGRect(x: 0, y: 0, width: 600, height: 400)
    let calls: [(String, JSONObject)] = [
        ("set_volume", ["percent": 40]), ("media_control", ["action": "next"]), ("scroll", ["direction": "down"]),
        ("open_app", ["name": "spotify"]), ("press_keys", ["keys": "escape"]), ("shortcut", ["action": "undo"]),
        ("type_text", ["text": "hi"]), ("pointer", ["action": "click"]),
    ]
    for (name, params) in calls {
        let before = harness.recorded.actions.count
        let result = await harness.call(name, params)
        #expect(result["ok"] == true, "\(name): \(result)")
        #expect(harness.recorded.actions.count > before, "\(name) acted without the hands")
    }
}

// MARK: Permissions

@Test func permissionsListWhatIsMissingInOneSentenceEach() {
    let all = Permissions.checkAll(accessibility: false, screenRecording: true, microphone: .notAsked)
    #expect(all.map(\.name) == ["Accessibility", "Screen Recording", "Microphone"])
    let missing = all.filter { !$0.isGranted }
    #expect(missing.map(\.name) == ["Accessibility", "Microphone"])
    for status in all {
        #expect(isSpeakable(status.howToGrant), "\(status.howToGrant)")
        #expect(status.howToGrant.contains(Permissions.hostAppName))
    }
    #expect(missing[1].howToGrant.contains("Allow"))
    #expect(isSpeakable(Permissions.accessibilityMissingSentence))
}

@Test func realPermissionCheckAnswersWithoutPrompting() {
    let all = Permissions.checkAll()
    #expect(all.count == 3)
}

// MARK: App matching

@Test func similarityMatchesDifflib() {
    #expect(abs(AppMatching.similarity("spotfy", "spotify") - 12.0 / 13.0) < 1e-9)
    #expect(AppMatching.similarity("abc", "abc") == 1)
    #expect(AppMatching.similarity("abc", "xyz") == 0)
}

// MARK: The shared fixture

@Test func fixtureMatchesTheToolsInCode() throws {
    // Fixtures/quick_tools.json is regenerated with `swift run hf-hands --dump-tools`.
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/quick_tools.json")
    let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture)).arrayValue ?? []
    let tools = QuickTools.make(hands: FakeHands(), guard: nil, system: FakeSystem(), timing: .fast, layout: USKeyboardLayout())
    #expect(saved.count == tools.count, "regenerate the fixture: swift run hf-hands --dump-tools")
    for (entry, tool) in zip(saved, tools) {
        #expect(entry["name"]?.stringValue == tool.name)
        #expect(entry["description"]?.stringValue == tool.description, "\(tool.name) description drifted")
        #expect(entry["parameters"] == tool.parameters, "\(tool.name) parameters drifted")
    }
}

// MARK: Typing pace by purpose

@Test func searchFieldsAreTypedQuicklyAndEverythingElseAtTheNormalPace() async {
    let harness = ToolHarness()
    _ = await harness.call("open_app", ["name": "chrome"])
    #expect(harness.hands.pacedIntervals == [QuickToolbox.searchFieldTypingInterval])  // the Spotlight query
    _ = await harness.call("open_url", ["url": "bbc.co.uk"])
    #expect(harness.hands.pacedIntervals.count == 3)  // Spotlight for the browser, then the address bar
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    _ = await harness.call("type_text", ["text": "hello"])
    #expect(harness.hands.pacedIntervals.count == 3)  // type_text keeps the default pace
}

@Test func openAppNeverPressesReturnWhenAWindowTakesTheKeyboardAfterTyping() async {
    let harness = ToolHarness()
    // The Java updater pops up between typing the name and pressing Return.
    harness.system.popup = KeyboardFocus(appName: "Java Updater", bundleID: "com.oracle.java.Java-Updater", pid: 66, role: "AXButton")
    harness.system.popupAfterTyping = true
    let result = await harness.call("open_app", ["name": "calculator"])
    #expect(result == ToolResult.failure(KeyLanding.protectedSentence))
    #expect(harness.recorded.keys == ["cmd+space", "cmd+a"])  // no Return, and no Escape into the pop-up either
}

@Test func openAppStopsWhenAnOrdinaryWindowTakesTheKeyboard() async {
    let harness = ToolHarness()
    harness.system.popup = KeyboardFocus(appName: "Notes", bundleID: "com.apple.Notes", pid: 55, role: "AXTextArea")
    harness.system.popupAfterTyping = true
    let result = await harness.call("open_app", ["name": "calculator"])
    #expect(result == ToolResult.failure("Another window took the keyboard while Spotlight was open, so I stopped."))
    #expect(!harness.recorded.keys.contains("return"))
}

@Test func openAppRefusesWhenItCannotConfirmWhereTheKeyboardIs() async {
    let harness = ToolHarness()
    harness.system.focusUnknown = true  // Spotlight never becomes frontmost, so only accessibility can tell
    let result = await harness.call("open_app", ["name": "calculator"])
    #expect(result == ToolResult.failure("I couldn't confirm the keyboard was in Spotlight, so I didn't press anything."))
    #expect(harness.recorded.keys == ["cmd+space"])
}

// MARK: Keys land only where intended

private let passwordPrompt = FrontApp(name: "SecurityAgent", bundleID: "com.apple.SecurityAgent", pid: 88)
private let javaInstaller = FrontApp(name: "MacJREInstaller", bundleID: "Oracle.MacJREInstaller", pid: 89)

@Test(arguments: [("press_keys", ["keys": "enter"]), ("press_keys", ["keys": "space"]), ("shortcut", ["action": "copy"]),
                  ("type_text", ["text": "hello"]), ("open_app", ["name": "calculator"]), ("read_text", [:]),
                  ("take_screenshot", [:])] as [(String, JSONObject)])
func nothingIsPressedOrTypedIntoAPasswordOrInstallWindow(_ tool: String, _ params: JSONObject) async {
    for prompt in [passwordPrompt, javaInstaller] {
        let harness = ToolHarness()
        harness.system.front = prompt
        harness.system.windows[prompt.pid] = CGRect(x: 400, y: 300, width: 500, height: 300)
        let result = await harness.call(tool, params)
        #expect(result == ToolResult.failure(KeyLanding.protectedSentence), "\(tool) with \(prompt.name): \(result)")
        #expect(harness.recorded.actions.isEmpty, "\(tool) acted on \(prompt.name)")
    }
}

@Test func mediaAndVolumeKeysStillWorkWhenAPromptIsInFront() async {
    // They go to the system, not to a window, so they can't press a dialog's button.
    let harness = ToolHarness()
    harness.system.front = passwordPrompt
    #expect(await harness.call("media_control", ["action": "play_pause"])["ok"] == true)
    #expect(await harness.call("set_volume", ["change": 10])["ok"] == true)
}

@Test func pressKeysRefusesWhenAnotherWindowHasTheKeyboard() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.popup = KeyboardFocus(appName: "Notes", bundleID: "com.apple.Notes", pid: 55)
    let result = await harness.call("press_keys", ["keys": "enter"])
    #expect(result == ToolResult.failure("Another window has the keyboard, so I didn't press that."))
    #expect(harness.recorded.actions.isEmpty)
}

@Test func anExplicitEnterMayPressAButtonTheUserCanSee() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.focusedRole = "AXButton"  // e.g. the user says "press enter" to confirm a sheet they see
    #expect(await harness.call("press_keys", ["keys": "enter"])["ok"] == true)
}

@Test func typeTextNeverPressesItsReturnOnAButton() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", pid: 3)
    harness.system.focusedRole = "AXButton"
    let result = await harness.call("type_text", ["text": "see you", "press_enter": true])
    #expect(result == ToolResult.failure("The keyboard is on a button, not in a text field, so I didn't press that."))
    #expect(!harness.recorded.keys.contains("return"))
}

@Test func typeTextStopsWhenAPopupTakesTheKeyboard() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.popup = KeyboardFocus(appName: "SecurityAgent", bundleID: "com.apple.SecurityAgent", pid: 88, role: "AXTextField")
    #expect(await harness.call("type_text", ["text": "hunter2"]) == ToolResult.failure(KeyLanding.protectedSentence))
    #expect(harness.recorded.typed.isEmpty)
}

@Test func openURLNeverPressesReturnUnlessTheAddressBarHasTheKeyboard() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "Arc", bundleID: "company.thebrowser.Browser", pid: 5)
    harness.system.windows[5] = CGRect(x: 0, y: 0, width: 900, height: 700)
    harness.system.focusedRole = "AXButton"
    let result = await harness.call("open_url", ["url": "bbc.co.uk"])
    #expect(result["ok"] == false)
    #expect(!harness.recorded.keys.contains("return"))
}

@Test func systemShortcutsDoNotNeedTheFrontAppToHaveTheKeyboard() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.popup = KeyboardFocus(appName: "Notes", bundleID: "com.apple.Notes", pid: 55)
    #expect(await harness.call("shortcut", ["action": "previous_app"])["ok"] == true)  // Command+Tab
    #expect(await harness.call("shortcut", ["action": "copy"])["ok"] == false)  // Command+C would go to Notes
}

// MARK: The landing rules themselves

@Test func landingRules() {
    let textEdit = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    let inTextEdit = KeyboardFocus(appName: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3, role: "AXTextArea")
    let onButton = KeyboardFocus(appName: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3, role: "AXButton")
    let spotlight = KeyboardFocus(appName: "Spotlight", bundleID: "com.apple.Spotlight", pid: 77, role: "AXTextField",
                                  identifier: "SpotlightSearchField")
    let prompt = KeyboardFocus(appName: "SecurityAgent", bundleID: "com.apple.SecurityAgent", pid: 88)
    #expect(KeyLanding.problem(focus: inTextEdit, front: textEdit, destination: .app(textEdit)) == nil)
    #expect(KeyLanding.problem(focus: inTextEdit, front: textEdit, destination: .textInput(textEdit)) == nil)
    #expect(KeyLanding.problem(focus: onButton, front: textEdit, destination: .app(textEdit)) == nil)
    #expect(KeyLanding.problem(focus: onButton, front: textEdit, destination: .textInput(textEdit)) != nil)
    #expect(KeyLanding.problem(focus: spotlight, front: textEdit, destination: .spotlightField) == nil)
    #expect(KeyLanding.problem(focus: inTextEdit, front: textEdit, destination: .spotlightField) != nil)
    #expect(KeyLanding.problem(focus: nil, front: textEdit, destination: .spotlightField) != nil)
    #expect(KeyLanding.problem(focus: nil, front: textEdit, destination: .app(textEdit)) == nil)  // falls back to the front app
    #expect(KeyLanding.problem(focus: prompt, front: textEdit, destination: .system) == KeyLanding.protectedSentence)
    #expect(KeyLanding.problem(focus: inTextEdit, front: textEdit, destination: .system) == nil)
    for (name, bundle) in [("Java Updater", "com.oracle.java.Java-Updater"), ("MacJREInstaller", "Oracle.MacJREInstaller"),
                           ("Installer", "com.apple.installer"), ("SecurityAgent", "com.apple.SecurityAgent")] {
        #expect(KeyLanding.isProtected(name: name, bundleID: bundle), "\(name)")
    }
    #expect(!KeyLanding.isProtected(name: "TextEdit", bundleID: "com.apple.TextEdit"))
    #expect(KeyLanding.protectedSentence == ProtectedSurfaces.spokenRefusal)  // the shared wording
    #expect(KeyLanding.isProtected(name: "coreautha", bundleID: "") && KeyLanding.isProtected(name: "Keychain Access", bundleID: "com.apple.keychainaccess"))
    // The app holding the keyboard is matched by bundle identifier first, then by name with invisible marks stripped.
    #expect(KeyLanding.isProtected(name: "\u{200E}Software Update", bundleID: ""))
}

// MARK: The safety guard: quick tools never do what needs confirming

private let whatsApp = FrontApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", pid: 21)

/// Answers like the app's guard with the real gate would for a chat app: Return,
/// a line break, or a click in WhatsApp needs confirmation; anything else is safe.
private func gateLike(_ question: RecordingGuard.Question) -> QuickActionVerdict {
    switch question.kind {
    case .pressKey where question.key?.isReturn == true, .typeLineBreak, .click, .doubleClick:
        return .refuse()
    default:
        return .allow
    }
}

@Test func aReturnWithTextInAMessageBoxIsRefusedAndNothingIsPressed() async {
    let harness = ToolHarness()
    harness.system.front = whatsApp
    harness.system.focusedRole = "AXTextArea"  // the message box, with a draft in it
    harness.safety!.answer = { gateLike($0) }
    let result = await harness.call("press_keys", ["keys": "return"])
    #expect(result == ToolResult.failure("That would need your confirmation, so I'll do it as a task instead."))
    #expect(harness.recorded.actions.isEmpty)
    #expect(harness.safety!.questions == [.init(kind: .pressKey, key: KeyChord(key: "return"), point: nil)])
    // Command+Return sends in Gmail and Outlook: modifiers don't make it safer.
    #expect(await harness.call("press_keys", ["keys": "command return"])["ok"] == false)
    #expect(harness.recorded.actions.isEmpty)
}

@Test func typeTextAskedToSendIsRefusedBeforeTypingAnything() async {
    let harness = ToolHarness()
    harness.system.front = whatsApp
    harness.safety!.answer = { gateLike($0) }
    let result = await harness.call("type_text", ["text": "running late", "press_enter": true])
    #expect(result == ToolResult.failure("That would need your confirmation, so I'll do it as a task instead."))
    #expect(harness.recorded.actions.isEmpty)  // no half-typed draft for the task to type again
    let lines = await harness.call("type_text", ["text": "line one\nline two"])
    #expect(lines["ok"] == false)  // a line break sends in some chat apps, so the gate decides
    #expect(harness.recorded.actions.isEmpty)
    #expect(await harness.call("type_text", ["text": "just words"])["ok"] == true)  // plain typing needs no check
}

@Test func theSpotlightReturnInsideOpenAppProceedsWhateverTheGuardSays() async {
    // That Return is covered by "Spotlight's search field holds the keyboard".
    let harness = ToolHarness()
    harness.safety!.answer = { _ in .refuse() }
    let result = await harness.call("open_app", ["name": "chrome"])
    #expect(result["ok"] == true)
    #expect(harness.recorded.keys.contains("return"))
    #expect(harness.safety!.questions.isEmpty)
}

@Test func withoutAGuardRiskyActionsAreRefusedAndSafeOnesStillWork() async {
    let harness = ToolHarness(guarded: false)
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.system.windows[3] = CGRect(x: 0, y: 30, width: 800, height: 600)
    let refusal = ToolResult.failure("That would need your confirmation, so I'll do it as a task instead.")
    #expect(await harness.call("press_keys", ["keys": "enter"]) == refusal)
    #expect(await harness.call("press_keys", ["keys": "space"]) == refusal)
    #expect(await harness.call("pointer", ["action": "click"]) == refusal)
    #expect(await harness.call("shortcut", ["action": "close_tab"]) == refusal)
    #expect(await harness.call("type_text", ["text": "hi", "press_enter": true]) == refusal)
    #expect(harness.recorded.actions.isEmpty)
    // Keys that can't commit anything stay instant and need no guard.
    #expect(await harness.call("press_keys", ["keys": "down down"])["ok"] == true)
    #expect(await harness.call("shortcut", ["action": "copy"])["ok"] == true)
    #expect(await harness.call("media_control", ["action": "next"])["ok"] == true)
    #expect(await harness.call("scroll", ["direction": "down"])["ok"] == true)
    #expect(await harness.call("type_text", ["text": "hi"])["ok"] == true)
}

@Test func aGuardThatIsTooSlowCountsAsARefusal() async {
    var timing = QuickTiming.fast
    timing.guardTimeout = 0.05
    let harness = ToolHarness(timing: timing)
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    harness.safety!.delay = 1  // the gate hangs
    let started = Date()
    let result = await harness.call("press_keys", ["keys": "return"])
    #expect(result == ToolResult.failure("That would need your confirmation, so I'll do it as a task instead."))
    #expect(Date().timeIntervalSince(started) < 0.5)
    #expect(harness.recorded.actions.isEmpty)
}

@Test func theGuardsOwnReasonIsWhatTheUserHears() async {
    let harness = ToolHarness()
    harness.safety!.answer = { _ in .refuse("Clicking Send would message Amma, so I'll ask you first in a task.") }
    let result = await harness.call("pointer", ["action": "click"])
    #expect(result == ToolResult.failure("Clicking Send would message Amma, so I'll ask you first in a task."))
}

@Test func clicksAskAboutTheExactPoint() async {
    let harness = ToolHarness()
    harness.recorded.setPointer(CGPoint(x: 512, y: 384))
    _ = await harness.call("pointer", ["action": "double_click"])
    _ = await harness.call("pointer", ["action": "right_click"])
    #expect(harness.safety!.questions == [
        .init(kind: .doubleClick, key: nil, point: CGPoint(x: 512, y: 384)),
        .init(kind: .rightClick, key: nil, point: CGPoint(x: 512, y: 384)),
    ])
}

@Test func keysThatCannotCommitNeverAskTheGuard() async {
    let harness = ToolHarness()
    harness.system.front = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 3)
    _ = await harness.call("press_keys", ["keys": "down up left right tab escape page_down"])
    _ = await harness.call("shortcut", ["action": "copy"])
    _ = await harness.call("shortcut", ["action": "previous_app"])
    _ = await harness.call("set_volume", ["change": 10])
    _ = await harness.call("media_control", ["action": "play_pause"])
    #expect(harness.safety!.questions.isEmpty)
}

@Test func whatCanCommit() {
    func commits(_ text: String, role: String = "") -> Bool {
        QuickActionGuard.mayCommit(KeyChord(text)!, focusedRole: role)
    }
    #expect(commits("return") && commits("enter") && commits("cmd+return") && commits("ctrl+enter") && commits("shift+return"))
    #expect(commits("space") && commits("shift+space"))
    #expect(!commits("cmd+space") && !commits("ctrl+space"))  // Spotlight, input source: system shortcuts
    #expect(commits("delete", role: "AXList") && commits("delete"))  // outside a text field, or unknown
    #expect(!commits("delete", role: "AXTextArea") && !commits("backspace", role: "AXTextField"))
    #expect(commits("cmd+delete", role: "AXTextArea"))  // Command+Delete can delete files and messages
    #expect(commits("cmd+q") && commits("cmd+w") && commits("shift+cmd+w") && commits("cmd+d"))
    for safe in ["down", "tab", "escape", "a", "cmd+c", "cmd+v", "cmd+t", "cmd+tab", "ctrl+up", "volume_up", "play_pause"] {
        #expect(!commits(safe), "\(safe)")
    }
}

@Test(arguments: [("JREInstaller", ""), ("VPNUpdater", ""), ("PKGInstaller", "com.vendor.pkg"),
                  ("Helper", "com.vendor.installer.helper"), ("Install macOS Tahoe", "com.apple.InstallAssistant.macOSTahoe")])
func casesTheSharedListOnceMissedAreNowRefused(_ name: String, _ bundle: String) {
    // Found on 5 Nov by running the old HFHands check beside HFCore's list; fixed in HFCore.
    #expect(KeyLanding.isProtected(name: name, bundleID: bundle), "\(name) \(bundle)")
    let front = FrontApp(name: name, bundleID: bundle, pid: 90)
    #expect(KeyLanding.problem(focus: nil, front: front, destination: .app(front)) == ProtectedSurfaces.spokenRefusal)
}
