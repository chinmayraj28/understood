# The Handsfree app

Handsfree.app is the native macOS app that holds everything together. It lives in the menu bar (no Dock icon), draws a companion beside the pointer that shows what the agent is doing, and connects every package: the voice, the hands, the eyes, the decisions, memory, the task runner and the screen agent. It is built on the open-source Clicky app (MIT, by Farza); what was taken and why is in `docs/research/clicky.md`, and the file-by-file list is in `third_party/clicky/NOTICE.md`.

## Build and run

You need Xcode 26, XcodeGen (`brew install xcodegen`) and an Apple Development certificate in the keychain (Xcode > Settings > Accounts makes one for any Apple ID).

```bash
scripts/build_app.sh            # Release build, signed, at build/Handsfree.app
scripts/build_app.sh --test     # also run the unit tests
scripts/build_app.sh --debug    # Debug build
scripts/build_app.sh --generate-only   # only write Handsfree.xcodeproj, to open it in Xcode

scripts/run_app.sh                            # start it for real
scripts/run_app.sh --demo                     # the scripted demo: no network, no permissions
scripts/run_app.sh --demo --backdrop          # the demo over a plain practice screen, for recording
scripts/run_app.sh --demo --loop              # repeat the demo
scripts/run_app.sh --demo --freeze holding    # stop at one moment and hold it still
scripts/run_app.sh --quit-after 20            # quit by itself (keeps test runs short)
scripts/run_app.sh --show-panel               # open the menu bar panel at launch
scripts/run_app.sh --request-permissions      # show macOS's three permission dialogs
scripts/run_app.sh --capturable               # let screenshots include the overlay (design review only)
```

Moments for `--freeze`: listening, speaking, heard, thinking, progress, moving, clicked, typing, asking, holding, answering, done, stopped, disconnected, reconnected, failed.

Quit the app from its panel ("Quit Handsfree"), or with `pkill -x Handsfree`. It never adds itself as a login item.

**Measured on this Mac (5 Nov):** a clean Release build takes about 70 seconds; `--test` runs 44 unit tests in under a second once built.

## How it is put together

```
project.yml                  XcodeGen spec: the app target and the unit test target
Handsfree/
  LinkedPackages.txt         which packages under Packages/ to link (one per line)
  App/                       HandsfreeApp (entry point), AppCoordinator (composition root),
                             AppModel, LaunchOptions
  Companion/                 everything drawn beside the pointer
    CompanionState.swift       events -> what to show (pure logic, unit tested)
    CompanionModel.swift       listens to ActivityBus and feeds CompanionState
    OverlayWindow.swift        the transparent, click-through window per screen
    CompanionOverlayView.swift the glyph, caption and question/confirmation card
    CompanionGlyphs.swift      waveform, spinner, resting dot, symbols
    TargetMarkerView.swift     the ring where the agent is about to click, the halo when it does
    OverlayGeometry.swift      coordinate conversions and placement (unit tested)
    PointerTracker.swift       where the pointer is, 60 times a second
  Panel/                     menu bar icon and panel, session log (transcript and task)
  Setup/                     permission checks and the first-run wording for a carer
  Demo/                      demo script, player and practice backdrop
  Integration/               connecting the packages:
    Parts.swift                small app-side interfaces for voice, runner, stop watcher
    PartAssembly.swift         creates one of each part and connects them
    RealParts.swift            the adapters for each real package
    StandIns.swift             what is used while a package is missing
  Design/                    DS design tokens, menu bar icon
HandsfreeTests/              unit tests (Swift Testing)
scripts/build_app.sh, run_app.sh, render_app_icon.swift
```

**The flow of events.** Every package posts what it is doing to `ActivityBus.shared` (HFCore). `CompanionModel` listens and passes each event to `CompanionState.apply`, which decides what is on screen. Example: HFHands posts `.pointerMoving(to: Send button, duration: 0.9)` just before gliding the real pointer. The companion shows a "moving" symbol and a ring appears on the Send button, closing in as the pointer arrives. The safety gate holds the click and posts `.heldForConfirmation`, and the task runner posts `.waitingForAnswer("Send 'running late' to Amma?")`. The ring turns amber and pulses, and an amber card says "WAITING FOR YOUR YES" with the question in large type. When the user says yes, HFHands posts `.clicked`, the card goes, and a halo ripples out from the button.

**The composition root** (`AppCoordinator` with `PartAssembly`) is the one place that builds and connects everything:

1. Loads `Settings` (keys come from `.env`; the app also looks in the folders above itself, so a build in `<repo>/build/` finds the repo's `.env`).
2. Hands: `SystemHands`, plus `QuickTools.make(hands:)`.
3. Eyes and labels: `ScreenEyes()` (leaves our own windows out of every screenshot) and `AccessibilityLabels(source: SystemAccessibilitySource())`.
4. Decisions: `Classifiers(settings:)` and `SafetyGate(classifier:)`.
5. One `ClaudeClient(settings:)`, shared by the screen agent and memory's learning.
6. Memory: `Memory.openDefault(settings:model:)` and `MemoryTools.make(memory:)`.
7. Screen agent: `ScreenAgent(hands:eyes:labels:client:configuration:)`.
8. Task runner: `TaskRunner(executor: screenAgent, gate:, answerClassifier:, memory:, sink: speak via voice, onCancel: hands.halt, onTaskEnd: hands.resume)` and `TaskTools.make(runner:)`.
9. Stop watcher: `StopWatcher(classifier:, isTaskRunning:, isAwaitingAnswer:, currentTaskID:, cancel: runner.cancel)`.
10. Voice: started with every tool (quick, memory, task) and memory's summary. Every sentence the user says goes to the stop watcher.

On quit, the runner shuts down (its cancel halts the hands), the hands are halted, and `restoreWebContentSwitches()` undoes the web-accessibility switch AccessibilityLabels turned on in Chrome and Electron apps.

## Linking a package, and why a broken package cannot break the app

Each package under `Packages/` is linked when its name is in `Handsfree/LinkedPackages.txt` (all seven are listed). For each listed package, `build_app.sh`:

1. skips it if `Packages/<Name>/Package.swift` does not exist;
2. runs `swift build` on it in our own folder (`build/package-check/<Name>`), so we never touch the owner's `.build`; if that fails, it retries once from an empty folder, because SwiftPM's cached plan can miss a file just added to HFCore and report a false failure (this happened);
3. links it only if it compiles, by writing `build/generated/linked-packages.yml`, which `project.yml` includes.

The app's code for a package is behind `#if canImport(<Name>)` in `RealParts.swift`, so a package that is not linked is simply not compiled, and `PartAssembly` uses the stand-in from `StandIns.swift`. Stand-ins never act on the Mac, fail with a sentence that can be read aloud, and never say yes to a risky action (the stand-in safety gate asks about everything).

One more trap the script handles: when the set of linked packages changes, it deletes the previous build products. Otherwise a package linked last time leaves its compiled module behind, `canImport` still finds it, and the Swift compiler crashes loading a stale module. That happened on 5 Nov when the HFCore contract changed.

To unlink a package by hand, comment out its line in `LinkedPackages.txt`.

## Integration checklist (5 Nov 2026, 21:42)

7 of 8 parts are real. Checked by launching the app and reading `~/Library/Application Support/Handsfree/app-status.json`, which the app writes at launch (it never contains a key).

| Part | Package | Status |
|---|---|---|
| Hands and quick tools | HFHands | **Real**: `SystemHands`, `QuickTools` (13 tools). Its build failed on and off while its owner was editing it; the script then fell back to the stand-in, as designed. |
| Eyes and labels | HFEyes | **Real**: `ScreenEyes`, `AccessibilityLabels`, quit hook `restoreWebContentSwitches()` |
| Classifiers and safety gate | HFDecisions | **Real**: `Classifiers` (Jev with word-list fallback), `SafetyGate` |
| Stop watcher | HFDecisions | **Real**: `StopWatcher`, cancelling the runner |
| Memory | HFMemory | **Real**: `Memory` at `<data dir>/memory.db`, `MemoryTools` (6 tools) |
| Screen agent | HFScreenAgent | **Real**: `ScreenAgent` with `ClaudeClient` (`claude-sonnet-5-5`) |
| Task runner | HFTasks | **Real**: `TaskRunner`, `TaskTools`; cancel halts the hands first |
| Voice session | HFVoice | **Stand-in.** The package links, but it has no `VoiceSession` yet, only `AgentConfiguration`. The adapter goes in `RealParts.makeVoice`: a class conforming to `VoiceConnecting` (start with tools, memory summary and a transcript listener; push a task event; stop). Until then the companion shows "Not connected" and the panel says why. |

What still has to happen to call the integration done: the voice adapter, then one real spoken run with all permissions granted.

## Signing and permissions: what was found

**The question.** Clicky's notes say "do not run xcodebuild from the terminal, it invalidates the permissions". Is that true with a stable signing identity?

**How macOS remembers a permission.** For Microphone, Accessibility and Screen Recording, macOS stores the app's bundle ID together with its *designated requirement*: a rule, carried in the code signature, that says which future code counts as "the same app".

**What we found (verified with `codesign` on this Mac):**

- Our builds are signed by `scripts/build_app.sh` with one Apple Development certificate, chosen by its fingerprint and remembered in `build/signing-identity`, so every rebuild uses the same one. The designated requirement is:
  `identifier "com.handsfree.Handsfree" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: <your Apple ID> (<certificate ID>)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`
  It names the bundle ID and the certificate, not the code. The code hash (`CDHash`) changes with every build; this rule does not.
- The same app signed ad hoc (`codesign -s -`, which is what a terminal build gets when no team is set) has the designated requirement `cdhash H"59f7…" or cdhash H"befb…"`: exactly this build's code hashes. The next build has different hashes, so macOS sees a different app and the old grant no longer applies. **This is almost certainly what Clicky's note is about**: the problem is an ad-hoc signature, not the terminal.
- The app is also launched with `open` (in `run_app.sh`), not by running the binary from the shell. A program started directly from a terminal counts, for macOS privacy, as part of the terminal (Orca here), so its prompts and grants would go to Orca instead of Handsfree.
- Hardened runtime is on, the sandbox is off, and the entitlements are `audio-input` (needed by the hardened runtime for the microphone) and `get-task-allow` (added by Xcode to development-signed builds; harmless locally).

**Not yet verified:** that a grant actually survives a rebuild on this Mac. That needs one real grant, and only the user can click Allow. The steps are below; afterwards: rebuild, relaunch, and check `app-status.json`. Expected result, from the designated requirement above: all three stay granted. Inferred, not yet observed.

**What the user (or a helper) must do once:**
1. Run `scripts/run_app.sh --request-permissions --show-panel`.
2. Microphone dialog: click **Allow**.
3. Accessibility dialog: click **Open System Settings**, switch **Handsfree** on (macOS may ask for the password).
4. System Settings > Privacy & Security > **Screen & System Audio Recording**: switch **Handsfree** on, and choose **Quit & Reopen** if offered (macOS applies this one only after a restart).
The panel lists exactly what is still missing, in words written for whoever is helping, with an "Ask macOS" or "Open Settings" button for each.

Caveats: if the signing certificate is ever replaced by one with a different name, the grants will be asked for again. On a crowded menu bar, macOS can hide a new status item behind the MacBook's notch; on this Mac the Handsfree icon appears to land there. The panel opens by itself at launch while setup is incomplete, and `--show-panel` opens it any time.

## Keeping the overlay out of screenshots

The screen agent must never see our halo and captions on top of the app it is operating. Two layers do this:

1. The overlay and panel windows set `sharingType = .none`, which tells the window server to leave them out of other processes' captures.
2. HFEyes' `ScreenEyes` leaves every window of our own process out of its ScreenCaptureKit filter (Clicky's method).

**Verified on 5 Nov (A/B test), saved as `docs/research/screens/capture-exclusion-ab.png`:** the demo was frozen on the held confirmation (amber card, halo on the Send button) and the screen was captured by two other processes: macOS's `screencapture` tool, and a small ScreenCaptureKit program that excludes nothing. With the overlay as shipped, neither capture shows the card, glyph or halo. With `--capturable` (`sharingType = .readOnly`), both captures show them. The practice backdrop (a window of the same app, left capturable) appears in all four, which proves the captures were real. ScreenCaptureKit still lists the overlay window (layer 1000) but leaves it out of the image. This test checks layer 1; layer 2 is HFEyes' own test.

## The overlay never takes a click

The overlay covers every screen, so it must let every click through (`ignoresMouseEvents = true`, kept from Clicky). At each launch the app checks this with the window server: for 9 points on every screen, `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` returns the window a mouse-down there would hit, and none may be an overlay. The result is in `app-status.json` (`"overlay_click_through_check": "passed"`) and the log. A negative control was run: with `ignoresMouseEvents` temporarily set to false, the check reported `FAILED`. The check moves nothing and clicks nothing.

## The companion's states

Photographed from the demo over the practice backdrop, in `docs/research/screens/` (01 to 16, plus 17 for the panel).

| State | What the user sees | It ends when |
|---|---|---|
| Listening | A small iris dot beside the pointer, slowly breathing | Something happens |
| User speaking | The dot grows into a dark disc with a white waveform that follows the voice | 0.7 s of silence |
| Heard | The sentence in quotes, with a microphone icon | 4 s |
| Agent speaking | A speaker waveform; what it says as a caption (timed to its length) | Its length, 2.5 to 10 s |
| Thinking | Spinner round the disc with an eye; "Looking at the screen" | The next action |
| Progress | "→ Opening WhatsApp" | 10 s, or the next line |
| Moving | Motion-arrow symbol; a dashed ring at the target closes in as the pointer arrives | Arrival + 0.8 s |
| Click | Tapping-hand symbol; a halo lands and ripples out from the click point | 1.1 s |
| Typing / scrolling | Keyboard / up-down symbols | 1.2 s / 0.9 s after the last one |
| Question | Amber "?" disc; a card "QUESTION", the question in 20 pt, "Say your answer." | The task moves on (backstop 180 s) |
| Waiting for your yes | Amber pause disc; an amber pulsing ring on the target; an amber-edged card "WAITING FOR YOUR YES", the question, "Holding: Click button 'Send' in …", "Say 'yes' to go ahead, or 'no' to stop." | The click lands, the task moves on, or stop |
| Stopped | Solid red disc with a stop symbol; "Stopped" | 3 s |
| Done / failed / cancelled | Green check / red "!" / grey "x", with the summary | 4.5 s (caption 6 s) |
| Not connected | Grey disc with a crossed-out signal; "Not connected. Trying again…" | The caption after 8 s; the grey disc until the voice is back, then "Connected again" |

Placement: the companion sits below and to the right of the pointer's tip, never on it, and mirrors to the left or moves above near a screen edge. It moves further out when the user has enlarged the pointer in Accessibility settings.

## Demo mode

`scripts/run_app.sh --demo` plays `Handsfree/Demo/DemoScript.swift` (about 54 seconds) on the real ActivityBus, so the companion and the panel react exactly as they would to the real packages: a message to "Amma" with a which-chat question and a held Send, a task stopped mid-glide, a dropped connection, and a failure. It uses no network and no permissions, and moves a drawn pointer, never the real one. `--backdrop` puts a plain mock chat app behind it (it covers the Dock but not the menu bar), so recordings show nothing private.

## Tests

`scripts/build_app.sh --test` runs 44 tests in `HandsfreeTests/` (not hosted in the app, so no overlay appears): the event-to-companion mapping, including every state ending by itself; first-run checks and their wording; the session log; launch options; coordinate conversions and placement at every edge and corner; and the demo script, which is checked to reach every glyph and to end at rest.
