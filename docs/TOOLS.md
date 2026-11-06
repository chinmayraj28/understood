# The hands and the quick tools (`Packages/HFHands`)

This package is the agent's hands. `SystemHands` moves the real pointer and presses real keys, visibly. `QuickTools` are the instant voice commands built on those hands, each done the way a person at the keyboard would do it. `Permissions` tells the first-run flow what macOS access is missing.

The exact tool definitions sent to ElevenLabs (name, description, JSON Schema) are in [`Fixtures/quick_tools.json`](../Fixtures/quick_tools.json). It is generated from the code with `swift run hf-hands --dump-tools`, and a unit test fails if the two drift apart. This document explains what each tool does on screen and how long it takes.

Every timing below was measured on the development Mac (MacBook, Apple Silicon, macOS 26.3, Arc as the default browser), on 5 Nov 2026, with `HF_LIVE=1 swift test --filter Live`.

## Trying it

```
cd Packages/HFHands
swift build && swift test                 # 127 unit tests, events faked, no permissions needed
scripts/live_lock.sh acquire quick       # FIRST: one pointer and keyboard are shared by everyone
HF_LIVE=1 swift test --filter Live        # the real Mac: pointer, keys, Spotlight, volume (restored after)
scripts/live_lock.sh release quick       # straight after, even if the run failed
swift run hf-hands --list
swift run hf-hands set_volume '{"percent": 30}'
swift run hf-hands --key "cmd+shift+t"    # press one key or shortcut
swift run hf-hands --state                # volume, brightness, front app, Spotlight, pointer
swift run hf-hands --permissions
```

Anything that moves the pointer, presses keys or brings an app forward (live tests, `hf-hands` with an acting tool) must hold `scripts/live_lock.sh` for its whole run: two runs at once fight over the front window. Read-only commands (`--state`, `--permissions`, `--list`, `--dump-tools`) need no lock and press nothing. Live extras, off by default because they touch the user's things: `HF_LIVE_MEDIA=1` (presses play/pause twice), `HF_LIVE_BROWSER=1` (opens a tab), `HF_LIVE_SCREENSHOT=1` (saves a screenshot, then deletes it).

## The tools

Thirteen tools. Each one acts only through the `Hands` protocol. Reading state is allowed (the volume level, the app in front, the selection); acting is always a key press, typing, a click or a scroll the user can see. No tool uses `open -a`, AppleScript or other behind-the-scenes calls.

Every handler validates its parameters, never throws, and fails with one short sentence that can be read aloud. A quick tool is a fresh spoken command, so if the user said "stop" earlier, the tool clears that stop flag before acting. By then, whatever was in flight has already frozen.

| Tool | Parameters | What a person would see | Measured time |
|------|-----------|-------------------------|---------------|
| `set_volume` | `percent` 0–100, or `change` −100–100, or `mute` true/false (exactly one) | The volume keys pressed: plain steps while far away, Shift+Option fine steps to land. Mute through the mute key, pressed only if the state needs to change. Reports the level actually reached. | 0.50–0.64 s for an exact level (4–5 presses); mute 0.13 s |
| `set_brightness` | `percent` or `change` | The same, with the brightness keys. Built-in screen only. | 0.50 s for a 20-point change |
| `media_control` | `action`: play_pause, next, previous | The play/pause, next or previous media key. Play and pause are one key, so it toggles. | about 0.12 s (the settle after the key) |
| `scroll` | `direction`: up, down, left, right, top, bottom; `amount`: a_little (3 lines), page (15), a_lot (45) | If the pointer isn't over the front window, it glides to the window's centre first, then the wheel turns. Top and bottom are one long wheel flick (10,000 lines in 12 events). | 0.16 s when the pointer is already there; about 1 s including a glide |
| `open_app` | `name` as spoken | Command+Space, Command+A (Spotlight keeps the last search), the app's exact installed name typed quickly (8 ms a character), a wait for the results list, then Return. Just before Return it checks that Spotlight still has the keyboard, and stops without pressing anything if another window took it. Then it checks the app really came forward, retrying once if not. Does nothing if the app is already in front. | 0.9–1.2 s (about 2 s for the first, cold run); 15 of 15 first time under the live lock |
| `open_url` | `url` or `search` (exactly one) | The default browser brought forward through Spotlight (if it isn't already in front), Command+T for a new tab (so the user's current page stays), the address or search words typed, Return. If the browser has no window, it waits for one, then Command+N. | not run live (it would leave a tab open); about 1.5 s by its parts |
| `press_keys` | `keys` as words ("command shift t", "down down enter"); `times` 1–20 | Exactly those keys. Refuses Control+Command+Q (lock screen) and any shortcut that would close or quit the app we run in. | 1–20 ms |
| `shortcut` | `action`, one of 30 (below) | The real shortcut for that action. | 1–20 ms |
| `type_text` | `text` up to 2000 characters; `press_enter` (default false) | The text typed one character at a time, in pieces of 40, checking between pieces that the same app is still in front. A line break is Shift+Return (a new line that doesn't send). Return only when `press_enter` is true. | 54 characters in 2.3 s (40 ms per character, a fast typist) |
| `pointer` | `action`: click, double_click, right_click, move; `direction`; `amount`: a_little (40 pt), some (150), a_lot (400) | A click where the pointer is, or a glide in that direction, stopping at the screen's edge. | click about 35 ms (30 ms hold); a move glides in 0.2–0.6 s |
| `where_am_i` | none | Nothing (reads only): the front app, its window title, other apps with windows. | 7–57 ms |
| `read_text` | `source`: selection (default) or clipboard | Reads the selection through accessibility. If the app doesn't report it (many web and Electron apps), it presses Command+C and reads the clipboard; the copy stays there, as when a person copies. | 4 ms through accessibility; up to 0.8 s via Command+C |
| `take_screenshot` | `target`: screen or window; `to_clipboard` | Command+Shift+3. For one window: Command+Shift+4, Space, then a click on the window. Control is added for the clipboard. Waits for the file to appear. | 6.1 s, because macOS writes the file only after its floating thumbnail goes |

`shortcut` actions and their keys:

| Editing | | Tabs and pages | | Windows and apps | |
|---|---|---|---|---|---|
| copy | cmd+c | new_tab | cmd+t | new_window | cmd+n |
| cut | cmd+x | close_tab | cmd+w | close_window | cmd+w (cmd+shift+w in a browser) |
| paste | cmd+v | reopen_tab | cmd+shift+t | minimise | cmd+m |
| undo | cmd+z | next_tab | ctrl+tab | fullscreen | ctrl+cmd+f |
| redo | cmd+shift+z | previous_tab | ctrl+shift+tab | next_window | cmd+\` |
| select_all | cmd+a | back | cmd+[ | previous_app | cmd+tab |
| save | cmd+s | forward | cmd+] | hide_app | cmd+h |
| find | cmd+f | reload | cmd+r | hide_others | cmd+option+h |
| | | zoom_in / zoom_out / actual_size | cmd+= / cmd+- / cmd+0 | quit_app | cmd+q (refused for our own app) |
| | | | | mission_control / spotlight | ctrl+up / cmd+space |

**Left out, and why:**
- **Lock screen.** The user can't type a password to get back in, and the agent can't unlock it. `press_keys` refuses Control+Command+Q for the same reason.
- **Show desktop.** Its shortcut (F11 by default) depends on a System Settings choice, and I didn't verify it. hide_others covers most of the need.
- **Click a named button.** That is the screen agent's job, because it needs eyes.

## Every key lands where intended

Immediately before every Return, Space, shortcut and piece of typing, a quick tool asks the accessibility system where the keyboard really is. It refuses with one spoken sentence when the key would land somewhere else (`KeyLanding.swift`):

| The key is meant for | It is pressed only if | Otherwise the user hears |
|---|---|---|
| Spotlight's search field (`open_app`: Command+A, the typed name, Return, Escape) | the focused app is Spotlight and the focused control is its search field. If the focus can't be read, nothing is pressed. | "Another window took the keyboard while Spotlight was open, so I stopped." |
| The app the command was meant for (`press_keys`, `shortcut`, `type_text`, `read_text`'s Command+C, the browser's Command+T) | the keyboard is in that app's process | "Another window has the keyboard, so I didn't press that." |
| A text field (the Return `type_text` adds, Shift+Return between lines, the address bar) | as above, and the focused control is not a button, checkbox, menu item or link | "The keyboard is on a button, not in a text field, so I didn't press that." |
| The system (Command+Space to open Spotlight, Command+Tab, Mission Control, the screenshot shortcuts) | always, except as in the last row | |
| Any of the above | never when a password prompt, Touch ID prompt, installer or updater is in front or has the keyboard, as recognised by HFCore's shared `ProtectedSurfaces` (checked for both the app in front and the app that holds the keyboard) | "A password or install window has appeared, so I've stopped. That step needs someone's hands." |

Notes:
- When `open_app` refuses part way, it presses nothing more, not even Escape: an Escape could cancel the user's own dialog.
- An explicit "press enter" or "press space" from the user may press a focused button in the app they are looking at, for example to confirm a sheet they can see. That is the one case where a Return may land on a button.
- Volume, media and brightness keys go to the system, not to a window, so they cannot press a dialog's button. They work even while a prompt is in front.
- 12 unit tests cover these rules, including a pop-up that appears between typing and Return, a password prompt and a Java installer in front for every key-pressing tool, and a focus that can't be read.

## Quick tools never do what needs confirming

The screen agent sends every click and every committing key press through the safety gate, so the quick tools must not be a way round it. Without this, the voice agent could call `press_keys` "return" while WhatsApp's message box holds a draft, and the message would go with no spoken confirmation. A key landing on an updater's Install button is the same hole.

**The rule.** Quick tools refuse any action that needs confirming. The voice agent then does it with `start_task`, which is the one place a confirmation is asked and answered. The refusal the user hears is: "That would need your confirmation, so I'll do it as a task instead." Every tool description that can hit this says so.

**The protocol** (in this package, `QuickActionGuard.swift`). The app implements it with the eyes' labels and the safety gate:

```swift
public protocol QuickActionGuarding: Sendable {
    /// kind: .pressKey, .typeLineBreak, .click, .doubleClick or .rightClick
    func check(_ kind: ScreenAction.Kind, key: KeyChord?, at point: CGPoint?) async -> QuickActionVerdict
}
public struct QuickActionVerdict { public let allowed: Bool; public let spokenReason: String }   // .allow, .refuse("...")
QuickTools.make(hands: hands, guard: appGuard)   // system: and timing: keep their defaults
```

The app builds the `ScreenAction` from what really has keyboard focus (for a key or a line break) or is under `point` (for a click) at that moment, asks the gate, and allows only when it says safe.

**What asks the guard**, immediately before acting:

| Action | Asked as |
|---|---|
| `press_keys` and `shortcut`: Return or Enter with any modifier, Space (but not Command+Space or Control+Space), Delete outside a text field (or when the focus is unknown), Command+Delete anywhere, Command+Q, Command+W, Command+Shift+W, Command+D ("Don't Save") | `.pressKey` with the `KeyChord` |
| `type_text` with `press_enter` | `.pressKey` Return, once before typing anything (so a refusal leaves no half-typed draft for the task to type again) and again at the moment of the Return |
| `type_text` text containing line breaks | `.typeLineBreak`, before typing and again at each Shift+Return |
| `open_url`'s final Return | `.pressKey` Return |
| `pointer` click, double click, right click | `.click`, `.doubleClick`, `.rightClick` at the pointer |
| `take_screenshot` of a window | `.click` on the window's title bar. It clicks the title bar rather than the middle, so if the screenshot shortcut didn't take, the click lands on nothing that commits. |

**What doesn't ask** (instant, as before):
- arrows, Tab, Escape, page keys, letters, Command+C/V/T and similar
- the system shortcuts (Command+Space, Command+Tab, Mission Control)
- scrolling, volume, brightness and media keys
- plain typing
- the Spotlight Return inside `open_app`, which is fully covered by "Spotlight's search field holds the keyboard"

**Failing safe:**
- With no guard supplied (`QuickTools.make(hands:)`, `hf-hands`), every action in the first table is refused, never performed.
- A guard that doesn't answer within 3 s (`QuickTiming.guardTimeout`) counts as a refusal.
- A refusal with no reason given uses the sentence above.

Tests cover:
- a Return with text in a message box is refused and nothing is pressed (including Command+Return)
- `type_text` asked to send is refused before typing anything
- the Spotlight Return proceeds whatever the guard says
- with no guard, risky actions are refused and safe ones still work
- a slow guard is a refusal
- the guard's own reason is what the user hears
- clicks ask about the exact point
- keys that can't commit never ask
- the commit rule itself

The live tests use a stand-in guard that allows actions only while their own scratch document is in front with the keyboard.

## Key names (`Hands.key`)

Names are case-insensitive. Join a shortcut with "+" ("cmd+shift+t") or spaces ("command shift t"). Underscores and spaces are interchangeable ("page_down" is the same as "page down"). A sequence such as "down down enter" presses three keys: modifiers collect until a key arrives, and that key completes one chord. Filler words ("press", "then", "and") are ignored.

| Kind | Names |
|------|-------|
| Modifiers | cmd, command, ⌘ · shift, ⇧ · option, opt, alt, ⌥ · ctrl, control, ⌃ · fn, function, globe |
| Named keys | return, enter, tab, space, delete / backspace, forward_delete, escape / esc, up, down, left, right (also "up arrow", "arrow up"), home, end, page_up, page_down, f1–f12 |
| Hardware keys | volume_up, volume_down, mute, play_pause (also play, pause), next_track (next), previous_track (previous), brightness_up, brightness_down |
| Characters | any single character on the current keyboard layout: a, 7, =, [, ?, ","  ("cmd+," works) |
| Spoken punctuation | plus / equals, minus / dash / hyphen, comma, period / dot / full stop, slash, backslash, semicolon, quote / apostrophe, backtick / grave, left_bracket, right_bracket, question_mark |

**Characters follow the current keyboard layout.** Key codes are physical positions. With a fixed US table, "cmd+a" on a French AZERTY keyboard would press the key that types "q" there, which is Command+Q, quit. So characters are looked up through `UCKeyTranslate` in the layout the user has selected, re-read every 10 seconds. A character the layout lacks (such as "[" on a German keyboard) falls back to its US position, because app shortcuts are bound to that physical key. This Mac's own layout already differs from US: the key left of 1 types "§", and the key US uses for backtick types "₹".

**Hardware keys** are posted as system-defined events (`NSEvent` type 14, subtype 8). The data1 field holds `key number << 16 | state << 8`, where the state is 0xA for down and 0xB for up. The key numbers come from IOKit's `ev_keymap.h`:

| Key | Number |
|-----|--------|
| volume up | 0 |
| volume down | 1 |
| brightness up | 2 |
| brightness down | 3 |
| mute | 7 |
| play/pause | 16 |
| next | 17 |
| previous | 18 |

Shift+Option held with a volume or brightness key gives quarter steps.

## How the hands behave

- **The pointer glides; it never teleports.**
  - It moves in a straight line with a minimum-jerk speed curve (10t³ − 15t⁴ + 6t⁵): a slow start, a quick middle and a gentle landing. This is how a person moves a mouse, and it is easy to follow by eye.
  - It posts about 120 positions a second and ends exactly on the target.
  - The duration grows with the logarithm of the distance, the way human pointing does: `0.15 + 0.12 × log2(1 + distance / 40)` seconds. That gives 10 pt in 0.2 s, 100 pt in 0.37 s, 500 pt in 0.6 s, and a full screen width in about 0.8 s.
  - Whatever duration a caller passes, every glide takes at least 0.12 s (`minimumGlideDuration`) and at most 3 s, so even `duration: 0` visibly travels. A drag never jumps with the button held.
  - Measured live: a 585-point glide planned at 626 ms took 769 ms (timer overhead) and landed exactly.
- **The companion is told first.**
  - `.pointerMoving(to:duration:)` is posted to the ActivityBus as the glide begins, with the real duration.
  - If the glide is halted part way, a second `.pointerMoving(to: <where it stopped>, duration: 0)` lets the companion snap back.
  - `.clicked(at:)` is posted after the button comes up. `.typing` and `.scrolled` are posted as those actions start.
  - The hands do not post `.halted`; the task runner owns that.
- **A click glides to the target, then presses and holds 30 ms** (`clickHoldInterval`), as a finger does. Some web pages, Electron apps and Catalyst controls ignore a click with no hold. A double click sends click counts 1 then 2, 60 ms apart. A modifier click holds the modifier key down around the click.
- **A drag:** glide to the start, button down, hold 80 ms (so apps see a drag rather than a click), glide to the end with drag events, button up.
- **Scrolling.** Positive `dy` means down. The wheel events are spread over at most 12 events, 12 ms apart, so even a flick to the bottom is quick. Quartz counts positive as up, so the sign is flipped inside. With `at`, the pointer glides there first.
- **Typing.**
  - Every character the current keyboard layout can produce is typed with its real key code and the right Shift flag, with the exact text attached. Key handlers in web pages, Electron apps and terminals then see the real key, and text fields get the exact text. For example, "H" is the H key with Shift.
  - Characters with no key on the layout (emoji, other scripts, accented letters not on this layout) go as text-only events.
  - Live in TextEdit, "Café crème — ça va? 你好 Привет 👋🏽 👨‍👩‍👧 “quotes” naïve 100€" arrived exactly, checked by reading the document back through accessibility.
  - The pace is 40 ms per character (`typingInterval`), a fast human typist, so autocomplete fields such as Gmail's To field keep up. 54 characters take 2.3 s.
  - Fields that only filter as you type take text faster: `typeText(_:allowReturn:characterInterval:)` (the `PacedTyping` protocol). The quick tools type into Spotlight and the address bar at 8 ms a character.
  - Measured, opening Calculator took 1.3–1.9 s at 40 ms against 0.9–1.2 s at 8 ms, first time in 10 of 10 either way.
  - A line break is refused (before anything is typed) unless `allowReturn` is true, because Return sends in chat apps. Tab is the Tab key.
- **Stop freezes the hands.**
  - `halt()` sets a flag that is checked before every pointer position, every typed character, every scroll event and every key.
  - Every wait inside an action is cut into 5 ms slices that also check it: the click hold, the drag hold, the pause between clicks, the settle after a media key, and the pauses between characters and between scroll events. Tests halt during each of them, with each pause set to 1 s, and require `Halted` within 50 ms.
  - Whatever is held when it fires is released before `Halted` is thrown: a mouse button during a drag is let go where the pointer froze, and modifiers come up in reverse order.
  - Then `releaseEverything()` clears anything the system still reports as held.
  - Measured live: halt to `Halted` took 1.8–10 ms during a real 1-second glide, and the pointer stayed exactly where it froze.
  - Cancelling the Swift task stops the hands the same way.
- **Halt is safe by construction.**
  - Each action remembers a halt count taken when it was requested, and `halt()` increments that count.
  - So every action requested before a halt, including actions still waiting their turn, throws `Halted`, even if `resume()` is called before they reach their next step.
  - `resume()` only lets actions requested after it run.
- **One action at a time.** Calls queue, in the order they arrive. A caller whose Swift task is cancelled while waiting leaves the queue at once with `CancellationError`.
- **Stuck keys are cleared.**
  - If the process is killed between a key or button going down and its release, macOS keeps it held until real input arrives, and this app's users can't press a key to clear a stuck Command.
  - `releaseEverything()` posts up events for every button (`CGEventSource.buttonState`) and modifier (`CGEventSource.flagsState`) the system reports held.
  - It runs when the hands are created and after every halt or cancel. It is public, so the app should also call it at launch and at quit.
- **Points** are screen points on the main display, with the origin at the top left. A point up to 40 pt off the screen is pulled in to the edge; further out is refused with "That spot is off the screen."
- **Dropped events are caught.**
  - Before acting: `CGPreflightPostEventAccess()`, the exact check for posting events. Without it, the action fails with a spoken sentence naming the app and the System Settings path.
  - After every glide: the real pointer must be within 2 pt of the target, checked again after 30 ms. Otherwise the action fails with "Something is blocking my pointer, so I've stopped." That catches a revoked permission, and a carer moving the mouse while the agent works: the agent stops rather than fighting them.
- **Testing against the real hands from any package:** `SystemHands(poster: RecordingEventPoster(), layout: USKeyboardLayout(), activity: ActivityBus())`.
  - Then read `.events`, `.moves`, `.typed` and `.nothingHeld`.
  - Set `dropsPointerMoves` to fake a blocked pointer, or `trusted = false` to fake missing Accessibility.
  - Use `onEvent` to halt mid-action, and `simulateStuck` to fake keys left held by a crash.

## Findings from the real Mac

These are things that would otherwise be learned the hard way.

1. **Volume and brightness move in 1/16 steps that snap to a grid. With Shift+Option they move in 1/64 steps.**
   - From 19%, one press up lands on 25%. From 90%, one press down lands on 87.5%. From 25%, a fine press up lands on 26.56%.
   - So `set_volume` plans plain presses while far away, then fine presses. It lands within 0.8 points of any target: asked 30, reached 29.69 in 4 presses; asked 47, reached 46.88 in 5; asked 25, reached 25.0 in 4. Each takes about 0.5–0.65 s.
   - Brightness behaves identically. The key animation lasts about a second, so read the level after it settles.
   - **My view on the person-like volume:** it is not meaningfully worse for the user. It is about 0.5 s slower than setting the level directly, and at most 0.8 points off. The real cost is only that a level such as 40% reads back as "41". Keep it.
2. **A hardware key is lost if the sender moves on or exits at once.**
   - A process that exits immediately after posting volume down lost the key 3 times out of 3. Staying alive 100 ms delivered it 3 of 3.
   - `key()` therefore waits 0.12 s after any hardware key, and `hf-hands` lingers before exiting.
3. **Spotlight on macOS 26:**
   - It has no window at all when closed.
   - Open, it is a window owned by "Spotlight" at layer 23: 640×56 pt for the bare field, 640×303 pt with results.
   - The first Escape only clears the field; a second closes it.
   - It keeps the last search, so `open_app` presses Command+A before typing.
   - Waiting for the results list, then 0.35 s for the top hit to settle, made it dependable.
4. **Spotlight reliability.**
   - First version (fixed 0.6 s wait, no retry): 4 of 5. The failed run took 7.2 s, and Calculator came up late.
   - After waiting for results and adding one retry: 5 of 5, twice in a row, 0.6–1.2 s each, opening Calculator from cold each time.
   - With the 40 ms typing pace, three of five runs needed the retry. Rerun under the live lock with nobody else driving the Mac, it was 10 of 10 first time at both 40 ms and 8 ms, so those retries were other engineers' runs colliding, not the pace.
   - With 8 ms typing in Spotlight it was 5 of 5 first time again, at 1.06–2.08 s (the 2 s run was the first, cold one).
   - Typing the exact installed name ("Google Chrome", not "chrome") keeps files and web suggestions from becoming the top hit.
5. **macOS can change typed text after it lands.**
   - After a Shift+Return, TextEdit turned "new line here" into "New line here": the system's "Capitalize words automatically" setting.
   - The hands type exactly. But dictated text may be capitalised or auto-corrected by the app, and the screen agent should not treat that as a typing failure.
6. **The front app must be read with `GetFrontProcess`.**
   - `NSWorkspace.frontmostApplication` only updates while the main thread runs a run loop. In a command-line process it reported the old app for 3 seconds after another came to the front.
   - `GetFrontProcess`, called through `dlsym`, is current and takes 0.3 ms.
7. **A scroll goes to the window under the pointer, not the focused window.** That is why `scroll` glides over the front window first.
8. **Names can carry invisible characters.** WhatsApp's app and window names start with an invisible left-to-right mark (U+200E), which is stripped before comparing.
9. **The default browser here is Arc.** Command+T in Arc opens its command bar for a new tab; typing an address and pressing Return works there as in Chrome and Safari.
10. **Secure Input does not block posted typing.**
    - With Secure Input switched on by another process, `IsSecureEventInputEnabled()` returned true and TextEdit was in front. Typed text still arrived.
    - So the hands no longer refuse to type while it is on: that refusal blamed a password field that often wasn't there.
    - Not typing into password fields is the screen agent's rule, judged from the focused control's role.
11. **Live tests share one pointer and one keyboard focus.**
    - When two engineers ran live tests at once, another app came to the front in the middle of typing. `type_text` correctly stopped with "another app came to the front", and its test failed.
    - Spotlight runs that collided took about 8.5 s, because the first attempt was lost and the retry succeeded.
    - Live runs need an exclusive slot on the Mac, which `scripts/live_lock.sh` now provides.
12. **A freshly launched TextEdit sometimes shows its Open panel instead of the document it was asked to open.**
    - An app with that panel up ignores a quit request. Once the panel was gone, TextEdit with no windows still ignored one.
    - The live tests cancel the panel, retry the open once, and force-quit a TextEdit they launched only when it has no windows left.
13. **Windows the user didn't ask for take the keyboard.**
    - During a locked live run, the Java updater, then its installer, then a macOS password prompt (SecurityAgent) came to the front.
    - A Return that reaches the default button of such a dialog is how an assistant installs or agrees to something the user never asked for.
    - That is why every key a quick tool presses is now checked at the moment of pressing (the section below). The live tests also check, before every key press, that their own window has the keyboard.
    - While Spotlight is open, the accessibility system names "Spotlight" as the focused application, while NSWorkspace still names the previous app as frontmost. Read on this Mac: with WhatsApp in front, the focused control was `AXTextArea` "ChatBar_ComposerTextView".

## Permissions

`Permissions.checkAll()` and `Permissions.missing()` read the state without changing any setting and without a prompt. Accessibility counts as granted only when both of its checks pass: `AXIsProcessTrusted()` (reading other apps' controls) and `CGPreflightPostEventAccess()` (posting pointer and key events). Both raw values are reported in `Status.detail`. Each item has one spoken sentence, for example: "To let me use the mouse and keyboard, open System Settings, go to Privacy and Security, then Accessibility, and switch on Orca."

macOS charges permissions to the *responsible* app. When run from a terminal on this Mac, that is Orca's terminal host, which System Settings shows as "Orca" (bundle `com.stablyai.orca`). Installed, it will be Handsfree.app itself.

State on this Mac, 5 Nov 2026, as seen from the terminal:

| Permission | State |
|------------|-------|
| Accessibility | granted |
| Screen Recording | granted |
| Microphone | granted (it was "not asked" earlier in the day) |

A microphone that has never been asked counts as missing, because this app's users can't click Allow on the prompt.

## Open risks

- **The Handsfree app must never be the active app while the agent acts.**
  - During testing, the app build (`build/Handsfree.app`) was active, with a 372×934 panel and full-screen overlays. Every key and typed character would then go to Handsfree, and "the front window" would be Handsfree's.
  - The panel needs to be a non-activating panel, and the overlay must ignore the mouse.
- **Shift+Return is a new line in WhatsApp, Slack, TextEdit and most editors, but not everywhere.** In some single-line web forms it submits. `type_text` only produces it when the text really contains a line break.
- **Private and deprecated calls:**
  - `GetFrontProcess` (deprecated), `responsibility_get_pid_responsible_for_pid` and DisplayServices (private) are reached through `dlsym`, and each has a fallback.
  - DisplayServices is used only to READ brightness.
- **Open_url and the media keys were not exercised live.** Opening a tab and toggling music would touch the user's things; they are opt-in.
- **Multiple displays:** only the main display is supported, as the plan states.
- **A pop-up can still arrive in the microseconds between the landing check and the key.** The check runs immediately before each key, so this window is tiny, but it is not zero.
- **Password and install windows are recognised by HFCore's shared `ProtectedSurfaces` list**, so the quick tools, the screen agent and the gate agree.
  - It matches bundle identifiers first (exact, or a family prefix such as `com.oracle.java.`), then display names with invisible marks stripped, then the whole words "installer", "updater", "autoupdate" or "uninstaller" in a name.
  - Three gaps found on 5 Nov by running the old HFHands check beside it are now fixed in HFCore, and HFHands tests each one: names where the word follows a run of capitals ("JREInstaller", "VPNUpdater", "PKGInstaller"), bundle identifiers that contain the word when the name doesn't (`com.vendor.installer.helper`), and Apple's "Install macOS …" installers (`com.apple.InstallAssistant.*`).
  - An installer the list doesn't know is still caught by the other rules: the keyboard must be in the app the command was meant for, and a tool's own Returns must land in a text field and pass the safety gate.
- **Not yet verified live** (live runs are frozen until the user has dealt with the Java installer):
  - the landing checks while Spotlight is open (that the accessibility system reports Spotlight's field as "SpotlightSearchField"). If it doesn't, `open_app` refuses rather than guessing, so a wrong assumption fails safe but would stop `open_app` working.
  - the 8 ms pace in the address bar.
