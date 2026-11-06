# Spike: the agent's eyes and labels (5 Nov 2026)

Package: `Packages/HFEyes` (`ScreenEyes` conforms to `Eyes`, `AccessibilityLabels` conforms to `Labels`).
Measured on this Mac (MacBook, macOS 26.3.1, Apple Silicon) from 19:45 to 20:15 on 5 Nov 2026, with the
package's own tool `swift run hf-eyes` and its live tests. Everything here is a property of macOS
(ScreenCaptureKit, AXUIElement), not of a language.

"Verified" means run and seen on this Mac. "Inferred" means read in Apple's documentation or reasoned,
not tested.

## 1. Permissions (verified)

Both permissions are granted to **Orca**, the app that hosts the terminal; processes it starts inherit them:

| Check | Result |
|-------|--------|
| `CGPreflightScreenCaptureAccess()` (Screen Recording) | true |
| `AXIsProcessTrusted()` (Accessibility) | true |

Neither call prompts or changes anything. `ScreenEyes` checks the first before every grab and throws
`SpeakableError("I need the Screen Recording permission to see the screen. Please allow it in System
Settings, under Privacy and Security.")` when it is false; ScreenCaptureKit's own refusal
(`SCStreamError.userDeclined`, -3801) is mapped to the same sentence. Without Accessibility every
lookup returns nothing and every phrase reads "an unknown control ...", so the gate asks.
The app itself will be a separate bundle and needs both permissions granted to it (Clicky's onboarding
flow handles this).

## 2. The display (verified)

| | This Mac |
|-|----------|
| Main display in points (what the pointer, accessibility and HFCore use) | **1470 x 956** |
| Backing scale | **2.0** |
| Backing pixels (what a full-detail capture has) | **2940 x 1912** |
| Physical panel (`system_profiler`) | 2560 x 1664 |

The user runs the "more space" scaled mode: macOS draws 2940 x 1912 and the panel shows it at 2560 x
1664. Captures and accessibility never see the 2560 figure. So "Retina" means three different sizes
in play: 1470 x 956 points, 2940 x 1912 backing pixels, and whatever size the image sent to the model
has. Never derive the scale from the panel's physical size.

**The mapping rule.** A `Shot` carries `screenRect` (points, top-left origin) and its pixel size. A
model coordinate maps back by proportion on each axis:
`x = rect.minX + imageX / pixelWidth * rect.width` (same for y). This is exact because the capture is
asked for exactly that rectangle at exactly that pixel size: ScreenCaptureKit's `sourceRect` is in the
display's points with the origin at the top left, the same space as HFCore. Each axis keeps its own
ratio, so rounding the image to whole pixels (1470 x 956 at long edge 1000 gives 1000 x 650) loses
nothing. `ScreenEyes` also refuses an image that comes back a different size from the one asked for.

## 3. Screenshots (verified)

API: `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` to list
displays and windows, `SCContentFilter(display:excludingWindows:)`, `SCStreamConfiguration` with
`sourceRect`, `width`, `height`, `showsCursor = false`, `captureResolution = .best`, then
`SCScreenshotManager.captureImage`, then PNG encoding with ImageIO. (`CGWindowListCreateImage` is
obsolete from macOS 15.)

| Grab | Image | First (cold) | Warm, 5 or more runs | Breakdown (warm) |
|------|-------|--------------|----------------------|------------------|
| Full screen, long edge 1280 | 1280 x 832, 650 KB PNG | 190 to 363 ms | **73 to 107 ms** | list windows 12 to 17 ms, capture 41 to 50 ms, PNG 14 to 16 ms |
| Full screen, long edge 1568 | 1568 x 1020, 885 KB PNG | 157 ms | 89 to 92 ms | list 13 to 17, capture 44 to 46, PNG 20 to 23 |
| Region 300 x 100 points | 600 x 200 (full Retina detail) | 98 ms | 46 to 65 ms | |

Under the 150 ms target once warm, without caching. Listing windows every time keeps the exclusion
list correct when windows appear. If more speed is ever needed, the cheapest saving is the PNG step:
JPEG is smaller and faster, but `Shot` is defined as PNG.

**A region grab is never upscaled** beyond the display's real pixels: a 300 x 100 point region gives at
most 600 x 200 on this Mac, whatever long edge is asked for.

**Leaving the overlay out of the picture (verified).** `ScreenEyes` passes ScreenCaptureKit a filter that
excludes every window owned by this process (by default), plus any window numbers
(`setExcludedWindowIDs`) or bundle identifiers given. Proof with `hf-eyes exclusion-check`: it shows a
red 120 x 120 window for about a second and grabs that spot twice.

```
exclude own windows = false: centre pixel rgb(234, 51, 35) -> RED square visible
exclude own windows = true:  centre pixel rgb(42, 42, 42)  -> square not visible
```

The pixels under an excluded window are the real content behind it. This is the reliable approach.
Inferred, not tested: `NSWindow.sharingType = .none` is not a dependable way to hide a window from
another app's ScreenCaptureKit capture on recent macOS, so do not rely on it. Because exclusion is by
owning process, the overlay must be a window of the same process that calls `ScreenEyes`, which it
will be in the app.

## 4. Labels: what comes back (contract as of 5 Nov, 21:00)

HFEyes returns HFCore's `UIElementInfo` and builds no sentences. The one wording the gate and the user
see is `ScreenAction.description` in HFCore, built from these fields:

| Field | What HFEyes puts there |
|-------|------------------------|
| `role` | HFCore's shared `ScreenRole`, mapped from the Mac's accessibility role and subrole (table below). |
| `label` | The best human-readable name, or **empty**. Never an identifier, never a guess, never text the user typed. |
| `identifier` | The developer identifier when it says something (`ChatBar_SendButton`); empty for none or a generated one (`_NS:616`, a UUID, a bare number). |
| `app`, `window` | Cleaned of invisible direction marks (U+200E before "WhatsApp" is removed). |
| `frame`, `isEnabled` | Screen points, top-left origin; the accessibility enabled flag. |

A lookup that finds nothing, or times out, returns **nil**. HFCore renders that as "an unknown
control in <front app>", and the gate treats it as unknown, never as safe.

**Role mapping.** Subroles win over roles.

| Mac role or subrole | ScreenRole |
|---------------------|------------|
| AXButton, AXDisclosureTriangle, AXIncrementor, AXColorWell | button |
| subrole AXCloseButton, AXMinimizeButton, AXZoomButton, AXFullScreenButton | windowControl |
| AXLink | link |
| AXTextField, AXComboBox | textField |
| subrole AXSearchField | searchField (Finder's toolbar search is an AXButton with this subrole) |
| subrole AXSecureTextField | passwordField |
| AXTextArea | textArea |
| AXMenuItem / AXMenuBarItem / AXMenuButton / AXPopUpButton | menuItem / menuBarItem / menuButton / popUpButton |
| AXCheckBox | checkbox; with subrole AXSwitch or AXToggle: toggle |
| AXRadioButton | radioButton; with subrole AXTabButton: tab |
| AXSlider, AXValueIndicator | slider |
| AXDockItem | dockItem |
| AXImage | image |
| AXStaticText, AXHeading | text |
| AXRow / AXCell | row / cell |
| AXTextField carrying a file URL (Finder's file names) | listItem |
| AXGroup whose role description is "list item" (web lists) | listItem |
| AXGroup, AXSegmentedControl, AXToolbar, AXScrollArea, AXWebArea, AXTabGroup, AXSplitGroup, AXList, AXTable, AXOutline, AXSheet | group |
| anything else | other |

Roles met that have no exact home, mapped as above: disclosure triangles, steppers and colour
wells (to button); segmented controls and the table and list containers (to group); scroll bars and
splitters (to other).

**Label, in order:**

1. title;
2. description;
3. a linked label element (AXTitleUIElement);
4. the value, only where the value is a name (static text, a pop-up's choice, a heading), never for
   a text field, text area, combo box or search field;
5. the file name from the element's URL (Finder);
6. the placeholder;
7. a recognisable child (text or an image description up to two levels down);
8. the help text.

Otherwise empty.

**The element a click acts on.** When the point is over text or an image inside a button, link, menu
item or field (Gmail's Send is the word "Send" inside a button), `element(at:)` returns that control
(up to four levels up), not the text.

## 5. Real controls tested (verified)

All read live, re-run with the structured contract at about 21:00 on 5 Nov.

- **WhatsApp, Finder and Chrome:** read with `hf-eyes controls --app <name>`, which walks the app's
  window, and its menus with `--menus`.
- **Chrome's page:** read with `--web`, which switches web content on for the read and back off at the
  end.
- **Menu bar and Dock:** read by hit test with `hf-eyes at x y`.
- **WhatsApp Send:** from the live typing check described below the table. Its fields come from the
  same element data the current code reads.

"Description" is HFCore's `ScreenAction.description` for a click there (for the message box, for a
Return key press). Window titles that could be private are shown as "…" (WhatsApp's window title is
always "WhatsApp").

| App | Control | role | label | identifier | Description (HFCore) |
|-----|---------|------|-------|------------|----------------------|
| WhatsApp | **Send** (appears once text is typed) | button | Send | ChatBar_SendButton | **Click button "Send" in WhatsApp, window "WhatsApp"** |
| WhatsApp | Same spot, empty box | button | Voice message | ChatBar_VoiceMessageButton | Click button "Voice message" in WhatsApp, window "WhatsApp" |
| WhatsApp | Message box (focus) | text area | Compose message | ChatBar_ComposerTextView | Press Return in text area "Compose message" in WhatsApp, window "WhatsApp" |
| WhatsApp | Emoji | button | Emoji picker | ChatBar_EmojiButton | Click button "Emoji picker" in WhatsApp, window "WhatsApp" |
| WhatsApp | Attach | button | Share media | ChatBar_AttachMediaButton | Click button "Share media" in WhatsApp, window "WhatsApp" |
| WhatsApp | New chat | button | New Chat | NavigationBar_NewChatButton | Click button "New Chat" in WhatsApp, window "WhatsApp" |
| WhatsApp | Voice call (test contact) | button | Start voice call with <test number> | NavigationBar_CallButton | Click button "Start voice call with …" in WhatsApp, window "WhatsApp" |
| WhatsApp | Clear search | button | Clear text | TokenizedSearchBar_DeleteButton | Click button "Clear text" in WhatsApp, window "WhatsApp" |
| WhatsApp | Close, minimise | window control | (empty) | (empty) | Click an unlabelled window control in WhatsApp, window "WhatsApp" |
| Chrome (OpenRouter credits page) | Buy | button | Add credits | (empty) | Click button "Add credits" in Google Chrome, window "…" |
| Chrome | Sign out | button | Sign out | (empty) | Click button "Sign out" in Google Chrome, window "…" |
| Chrome | Toggle | switch | Use crypto | (empty) | Click switch "Use crypto" in Google Chrome, window "…" |
| Chrome | Page link | link | Dashboard | (empty) | Click link "Dashboard" in Google Chrome, window "…" |
| Chrome | Address bar | text field | Address and search bar | (empty) | Click text field "Address and search bar" in Google Chrome, window "…" |
| Finder | Move to Bin (menu, nothing selected) | menu item | Move to Bin | (empty; `_NS:616` dropped) | Click menu item "Move to Bin" in Finder, window "…" (disabled) |
| Finder | Empty Bin | menu item | Empty Bin… | (empty) | Click menu item "Empty Bin…" in Finder, window "…" |
| Finder | Delete Immediately | menu item | Delete Immediately… | (empty) | Click menu item "Delete Immediately…" in Finder, window "…" (disabled) |
| Finder | A file in list view | list item | hiya | (empty) | Click list item "hiya" in Finder, window "…" |
| Finder | Toolbar | button, menu button, radio button, search field | Share, Add Tags, Action, list view, Search | (empty) | Click button "Share" in Finder, window "…" |
| Menu bar (hit test at 18, 10) | Apple menu | menu bar item | Apple | (empty) | Click menu bar item "Apple" in Orca |
| Dock (hit test) | An app icon | Dock item | <app name> | (empty) | Click Dock item "<app name>" in Dock |
| Spotlight (focus, run live about 21:15: Command+Space, "Notes", Escape) | Search field | search field | Spotlight Search (its placeholder) | SpotlightSearchField | Press Return in search field "Spotlight Search" in Spotlight, window "Spotlight" |

**Spotlight and the front app.** While Spotlight is open, `NSWorkspace.frontmostApplication` still names
the previous app (Orca), because Spotlight never becomes the active app. HFEyes' `frontmost()` asks
the accessibility system for the focused application and correctly answers "Spotlight". For about
0.6 s after Escape it still answered Spotlight, so read the focus at the moment of the key press.

**WhatsApp's Send button, seen live (5 Nov 2026, about 20:45).** The throwaway check
`Packages/HFEyes/Checks/WhatsAppSendCheck` (`swift run whatsapp-send-check`) used the real hands
(HFHands `SystemHands`) on the test contact's chat only:

1. It clicked WhatsApp's Dock icon.
2. It checked the open chat was the test contact's (by digits) and that the message box was empty.
3. It clicked the message box and checked the focus with the labels' focused element and with WhatsApp's own
   focused element.
4. It typed "hello".
5. It read the Send button by hit test, without the pointer going near it.
6. It cleared the box with Cmd+A then Delete, confirmed it empty, and switched back with Cmd+Tab.

Return was never pressed and Send never clicked. Output:

```
before typing, button at the Send spot: button "Voice message" in WhatsApp, window "WhatsApp"
focus phrase: text area "Compose message" in WhatsApp, window "WhatsApp"
SEND PHRASE: button "Send" in WhatsApp, window "WhatsApp"   [5.3 ms]
  element: role button, label "Send", enabled true, frame (1424.0, 823.0, 36.0, 36.0)
cleared: message box is empty
Send button still there: false
```

**The same spot is "Voice message" while the box is empty and "Send" once text is in it**, so the
phrase must be read at the moment of the click, never cached from an earlier step.

**Gmail Send and Google Calendar Save were not tested.** The Chrome profile is signed out of Google on
the web: Gmail's compose page (opened in a new tab by Claude in Chrome) showed Google's sign-in page,
and the lead found Calendar redirects to sign-in too. Nobody signed in. Check both once the user has
signed in again. Web buttons with
visible text were named correctly on the OpenRouter page, and Gmail's Send is the same pattern (text
inside a button), covered by the unit test `textInsideAButtonNamesTheButton`. Inferred, not verified:
Gmail's icon buttons carry `aria-label`s (for example "Discard draft"), which Chrome exposes as the
description, so they should be named.

## 6. Making Chrome expose web pages (verified)

Chrome builds the accessibility tree of a page only when an assistive app asks for it. With nothing set,
Chrome's window had 83 elements, no web area and no links: only the browser frame.

| Switch set on the app element | Result in Chrome |
|-------------------------------|------------------|
| `AXManualAccessibility = true` (the Electron switch) | Refused: error -25205 (attribute unsupported). Nothing changed. |
| `AXEnhancedUserInterface = true` (the switch VoiceOver uses) | Returns error -25208, **but reads back as 1, and about 2 seconds later the page appears**: 243 elements, 1 web area, 159 elements inside it, 23 links. Listed controls went from 54 to 102. |

So `SystemAccessibilitySource` tries `AXManualAccessibility` first (Electron apps) and falls back to
`AXEnhancedUserInterface`, checking success by reading the value back. It does this once per process,
for every Chromium-family browser (by bundle identifier) and every Electron app (by the
`Electron Framework.framework` inside the bundle).

**It is opt-in and explicit (changed after review, 5 Nov 21:00).** Creating `SystemAccessibilitySource`
or `AccessibilityLabels` writes nothing to any app; it only sets our own process's messaging timeout.
The app calls `await labels.enableWebContent()` once at start-up. That runs on a background thread
(it can take up to about a second per app that does not answer). It switches on every browser and
Electron app running then, and from then on each one met for the first time in a lookup. At quit the
app calls `labels.restoreWebContentSwitches()`. Tests never call `enableWebContent()`. The live test
`creatingTheRealLabelsChangesNoBrowser` checks that creating the labels and looking something up
leaves Chrome's switch exactly as it was. This is the only write in the package.

Seen at 21:00: Chrome was already switched on by some other process before my run, so my restore
correctly left Chrome alone. It switched off only the seven Electron apps and Arc that it had turned on
itself.

**What happens after it is set, and whether it is undone (verified 5 Nov, 20:20 to 20:30):**

- **It persists after our process exits.** Chrome still read `AXEnhancedUserInterface = 1` well after
  the process that set it had quit. Nothing undoes it automatically: it stays on until something
  sets it to false or Chrome restarts.
- **Switching it off removes the page tree.** Setting it to false (Chrome again answers -25208 but
  reads back 0) brought Chrome's window back to 83 elements, no web area and no links, within a few
  seconds.
- **Restoring at quit.** `SystemAccessibilitySource.restoreWebContentSwitches()` switches off every app
  that this object switched on, and only those that were off before it touched them. Run on this Mac
  (`hf-eyes restore-check`), it restored Google Chrome (`AXEnhancedUserInterface`), plus Claude,
  Notion, Code, Arc, Granola, Orca and terminal-browser (`AXManualAccessibility`); Chrome then read 0
  and its page tree was gone. **The app should call it when it quits.** If the app crashes, the
  switches stay on until each app restarts, which is harmless (assistive apps such as VoiceOver leave
  them on all the time) but is a change we made to the user's apps.
- **It is shared between processes.** If another process (another of our packages, a test run)
  switched Chrome on first, a later object sees it already on and does not record it, so its restore
  leaves it alone. Seen once during this check.
- **Side effects observed:** none that I could see. Chrome was behind other windows during these
  checks, so this is not strong evidence. Inferred, not tested: VoiceOver's switch is known to make
  window moves and resizes animate slowly in some apps (window-manager apps complain about it), and
  Chrome may do slightly more work keeping its accessibility tree up to date. Our hands do not move
  windows.

**The cost of leaving it off:** Chrome shows accessibility only its own frame (tabs, toolbar, address
bar). Every click inside a web page then hits an element with no name, so the phrase is "an unlabelled
..." or "an unknown control in Google Chrome", and the safety gate has to ask before every click on
every web page, including harmless ones. It also cannot tell "Send" from "Cancel" by name. With the
switch on, web buttons are named like native ones. Recommendation: keep it on while the app runs, and
call `restoreWebContentSwitches()` at quit.

Other caveats:

- The first lookup in a browser launched after start-up may only see the browser frame, for about
  two seconds.
- Chrome exposes only the **active tab** of each window. A tab Claude in Chrome opened in the
  background was not readable until it became the active tab.

## 7. Where naming is weak (verified unless marked)

- **WhatsApp's window title is "WhatsApp", not the chat's name.** A Send phrase therefore does not name
  the recipient. The recipient is readable elsewhere: the call buttons ("Start voice call with ...") and
  the chat view's description ("Messages in chat with ...", from the harness spike). The screen agent
  should put the recipient in its own confirmation wording. A WhatsApp-specific context field could be
  added later; see section 10.
- **Window buttons** (close, minimise) are unlabelled in every app tested. That is harmless.
- **Terminal and Electron content.** Orca's terminal view gave `an unknown control in Orca` for focus
  and `an unlabelled scroll area in Orca` under the pointer.
- **Spotify.** It showed only four empty containers in the earlier spike: icon-only and unnamed
  throughout.
- **Finder.** Some unnamed toolbar buttons remain (a menu button with only a generated identifier).
- **Message text.** A message bubble's static text is a name (its value), so a click on a message
  bubble returns role `text` with up to 80 characters of the message as its label. HFCore's description
  leaves content labels longer than 30 characters out ("text containing text"), so the classifier does
  not see them. The label still reaches HFCore's local rules, and HFEyes never logs it.
- **Our own overlay under the pointer.** Inferred, not tested: a hit test returns whatever window is
  topmost at that point. If the overlay window ever sits exactly under a click point, the lookup could
  name the overlay. The overlay sits beside the pointer, not under its tip, and should ignore mouse
  events; worth one check when the app exists.

## 8. Lookup speed (verified)

Measured inside the process, release build. The first column was measured right after start-up, the
second on later runs.

| Lookup | Right after start-up | Warm |
|--------|----------------------|------|
| `element(at:)` (hit test, ancestors, app, window) | 20 to 64 ms | **2.5 to 7 ms** |
| `focusedElement()` | 13 to 15 ms | **1.6 to 2.8 ms** |
| `frontmost` (asks the accessibility system for the focused app; NSWorkspace goes stale without a run loop) | 15 to 29 ms (old NSWorkspace version) | **0.4 ms** |
| `visibleControls` of the front window (Orca, 57 controls) | | 39 to 52 ms |
| WhatsApp window (29 controls) | 435 ms | **82 to 100 ms** |
| Chrome window with web page (100 to 104 controls) | 282 ms | **47 to 68 ms** |
| Finder window (55 controls) | | 91 to 110 ms |
| Finder window plus its menus (397 controls) | 476 ms | 104 ms |

All lookups are under the 50 ms target once warm, and listing controls (under about 110 ms) is fast
enough to run every step.

**Bounded so a frozen app cannot hang a task (changed after review, 5 Nov 21:00):**

- The accessibility messaging timeout is set on the system-wide element to 0.25 s, which bounds every
  call into another app.
- **All lookups run on one dedicated worker thread.** Each caller waits at most its deadline (0.4 s;
  2 s for listing controls) and gets nil after that.
- **While a lookup is stuck past its deadline, every new lookup is refused at once with nil**,
  without queueing or starting a thread, until the stuck one comes back. A frozen app therefore holds
  at most one thread however often the agent retries. Lookups arriving together while nothing is
  stuck simply queue (at most 8).
- The controls walk also stops at 5,000 elements or 1.5 s.

Verified by unit tests:

- `aFrozenAppHoldsOneThreadAndLaterLookupsAreRefusedAtOnce`: against a fake tree that blocks for 1 s,
  the first lookup returns nil at 0.1 s; 40 retries return nil in under 0.3 s in total; the fake was
  called once, never by two threads at a time; lookups work again once it comes back.
- `lookupsArrivingTogetherQueueRatherThanFail`.

**Privacy.** A label can be private text (the words of a message bubble). Nothing in HFEyes logs a label:
its log lines carry only counts, process numbers and error codes. Only the `hf-eyes` tool prints labels,
to the terminal, and `--mask` hides them.

## 9. Trying it by hand

```
cd Packages/HFEyes
swift run hf-eyes info                          # display size, scale, permissions
swift run hf-eyes shot /tmp/s.png --max 1280 --repeat 5
swift run hf-eyes shot /tmp/r.png --region 100,100,300,100
swift run hf-eyes pointer                       # the control under the pointer right now
swift run hf-eyes at 18 10
swift run hf-eyes focus
swift run hf-eyes controls --app WhatsApp --find "Send"
swift run hf-eyes controls --app Finder --menus --find "Bin"
swift run hf-eyes controls --mask               # structure only: letters in labels become x
swift run hf-eyes controls --app "Google Chrome" --web   # switches web content on, reads, switches it off
swift run hf-eyes webcheck --app "Google Chrome"          # read the switches (writes only with --set)
swift run hf-eyes exclusion-check               # shows a red square for a second
```

## 10. Contract notes

HFEyes implements the contract as of 5 Nov, 21:00: `Labels` with `element(at:)`, `focusedElement()`,
`frontmost()` and `visibleControls(limit:)`, returning `UIElementInfo` with `ScreenRole` and
`identifier`. The sentence form is HFCore's alone.

Public additions on the concrete types, outside the protocols:

- `ScreenEyes(excludedWindowIDs:excludedBundleIdentifiers:excludeOwnProcess:showsCursor:)`, plus
  `setExcludedWindowIDs(_:)`, `lastGrabTimings`, `hasScreenRecordingPermission` and `mainDisplayScale`.
- `AccessibilityLabels(source:timeout:controlsTimeout:)`, `enableWebContent() async -> [String]` and
  `restoreWebContentSwitches() -> [String]`.
- `SystemAccessibilitySource(messagingTimeout:)`, `enableWebContent()`, `restoreWebContentSwitches()`,
  `controls(processID:limit:includeMenuBar:)` and `isTrusted`.
- `ControlNamer.info(_:app:window:)`, `role(of:)`, `label(of:)` and `identifier(of:)`.

A possible later addition, if the gate needs the recipient of a WhatsApp message: a field for the
conversation's name, read from the `ChatMessagesTableView` description. Not needed now.

## 11. Looking through Handsfree's own windows (5 Nov, 21:40 to 21:55)

**The bug.** With the Handsfree app on screen (demo mode, a backdrop window above WhatsApp), a click on
WhatsApp's chat list was described as `Click group "Chats" in Handsfree`. The model aimed at WhatsApp,
because screenshots leave our windows out, but the accessibility hit test found our own window.

**Reproduced on this Mac** (`hf-eyes overlay-check`, read-only, at about 21:40). The app was running with
two full-screen windows, at layers 1000 and 21. At the pointer, the raw system-wide hit test belonged
to Handsfree. With the fix, the labels returned the window beneath instead (an installer window that
happened to be in front). Once the app had quit, the raw hit test at the same point found that same
window, which confirms the fix picked the right one.

**The fix.** A lookup never returns Handsfree's own windows:

- **Who is ignored.** `IgnoredOwners` is by default this process plus `com.handsfree.Handsfree`, so a
  tool or test running as another process still looks through the app. The app can pass its own set
  with `SystemAccessibilitySource(ignoring:)`.
- **The hit test** (`PointResolver`):
  1. The ordinary system-wide hit test is kept when its owner is not ignored (no extra cost).
  2. Otherwise each app with a visible window under the point is asked, frontmost first, for the
     control at the point within that app only (`AXUIElementCopyElementAtPosition` on the
     application element).
  3. Then the front app that is not ignored (the menu bar strip is the window server's, its items the
     front app's).
  4. If only our own windows are there, it returns nil, never our control.
- **Focus and front app.** `focused()` and the front app (used by `frontmost()` and
  `visibleControls`) skip ignored owners and fall back to the front app that is not ours.
- **Tests.** Eight unit tests with a fake window list (`IgnoredOwnersTests.swift`); 37 tests in all.

**Does the real overlay catch hit tests? It depends on one window setting (verified under the live lock,
`hf-eyes hittest-check`).** I showed a window of my own process at the screen-saver level and
hit-tested its centre system-wide:

| Window setting | Raw system-wide hit test | Labels (with the fix) |
|----------------|--------------------------|-----------------------|
| `ignoresMouseEvents = true` | passes through to the app beneath (WhatsApp) | WhatsApp's control |
| `ignoresMouseEvents = false` | stops on our window (error -25208 here, because a process cannot answer itself) | WhatsApp's control |

So an overlay window that ignores mouse events is transparent to accessibility hit tests, and users
would only have been affected by a Handsfree window that accepts mouse events, such as the demo
backdrop. The fix covers both cases. Checking the real app in normal mode (`hf-eyes overlay-check` with
the companion on screen) has been asked of the app's engineer.

Re-run by hand (read-only): `swift run -c release hf-eyes overlay-check --mask` with the app running.

## 12. Bundle identifiers and protected surfaces (5 Nov, about 22:10; unit tests only, live runs frozen)

HFEyes fills HFCore's `UIElementInfo.appBundleIdentifier` for every element (a hit, a focused control,
each listed control) and implements `frontmostBundleIdentifier()` for the same app `frontmost()` names.
HFCore's `ProtectedSurfaces` matches on these first, because display names are translated and can
carry invisible marks.

**A password prompt that exposes nothing to accessibility is still identified:**

- **At a point.** Only Handsfree's own windows are looked through. If the topmost other window under
  the point does not answer (a SecurityAgent prompt), `element(at:)` returns an unnamed element of
  **that** app, with its bundle identifier and the window's frame. It never returns the app beneath:
  the click would land on the prompt. (This corrects section 11's first version, which fell through
  to the next window.)
- **The front app.** A visible window of a protected app above the ordinary window layer counts as
  the front app before anything accessibility reports. A prompt may never become the active app and
  may expose nothing, yet it takes the keyboard. An ordinary-layer window of a protected app (Keychain
  Access left open) is front only when accessibility says so, so it does not freeze the agent.
- Unit tests: `aTopWindowThatExposesNothingIsNamedAsItsOwnAppNeverTheWindowBeneath`,
  `aProtectedPromptAboveOrdinaryWindowsIsTheFrontApp` and
  `aPasswordPromptThatExposesNothingIsStillRecognisedAsProtected`.
- Inferred, to check live when the freeze lifts: that SecurityAgent and LocalAuthentication prompts
  sit above layer 0.

**HFCore bug found (reported):** `frontmostBundleIdentifier()` is declared only in the protocol's
extension, so HFCore's `clickAction` and `keyAction` call the default ("") instead of HFEyes'. The fix
is to declare it in `protocol Labels`. Fixed in HFCore the same evening; the test now asserts it directly.
