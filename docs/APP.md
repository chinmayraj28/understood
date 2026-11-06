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
scripts/run_app.sh --request-permissions      # show macOS's permission dialogs (four in wake-phrase mode)
scripts/run_app.sh --capturable               # let screenshots include the overlay (design review only)
scripts/run_app.sh --wait --render-states DIR # draw the companion's states into PNGs in DIR and quit
```

Moments for `--freeze`: asleep, waking, listening, speaking, heard, thinking, progress, moving, clicked, typing, asking, holding, answering, done, stopped, disconnected, reconnected, failed, asleep-again.

`--render-states` is for design review without the Screen Recording permission: it draws the companion's real SwiftUI views for asleep, waking, awake and a few existing states, over a light and a dark background, framed like the photographs in `docs/research/screens/`, plus the panel. It puts nothing on screen. (SwiftUI's offscreen renderer cannot draw AppKit views and puts a yellow "no entry" placeholder in their place. The only one in the app is the invisible pointing-hand cursor layer on buttons (`pointerCursor()`), so the renderer sets `drawsForSnapshot` and leaves that layer out; the panel's buttons now render as they look. The real panel draws them too: see the close button in `17-panel.png`.)

**Wake settings** (in `.env`, all optional): `WAKE_PHRASE` (default `Hey Handsfree`), `WAKE_MODE` (`phrase`, the default, or `always` to keep one conversation open as before, for demos and testing), `SLEEP_AFTER_IDLE_S` (default 25, at least 5).

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
    CompanionGlyphs.swift      waveform, spinner, resting dot, asleep moon, waking ear, symbols
    TargetMarkerView.swift     the ring where the agent is about to click, the halo when it does
    OverlayGeometry.swift      coordinate conversions and placement (unit tested)
    PointerTracker.swift       where the pointer is, 60 times a second
    SoundCues.swift            when the waking and sleeping sounds play, and the tones (pure, unit tested)
    CuePlayer.swift            plays them as the ActivityBus reports waking and sleeping
  Panel/                     menu bar icon and panel, session log (transcript and task)
  Setup/                     permission checks and the first-run wording for a carer
  Demo/                      demo script, player, practice backdrop, state snapshots (--render-states)
  Integration/               connecting the packages:
    Parts.swift                small app-side interfaces for voice, runner, stop watcher, listening cycle
    PartAssembly.swift         creates one of each part and connects them
    CycleWiring.swift          "is anything going on", the cycle's hooks, the always-open cycle (unit tested)
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
10. Voice: `VoiceSession` is *prepared* once with every tool (quick, memory, task, and HFVoice's `go_to_sleep`) and memory's summary. That updates the agent's definition on ElevenLabs once, in the background, and fetches a connection token ahead of the first wake. Every sentence the user says goes to the stop watcher. No conversation is opened here.
11. Listening cycle: HFWake's `ListeningCycle` with its on-device `WakeListener` (wake mode "phrase", the default). The app starts **asleep**; on the phrase the cycle posts `.waking`, stops the wake listener so the conversation can have the microphone, and opens a conversation with the rest of the sentence as the user's first turn; after `SLEEP_AFTER_IDLE_S` with nothing going on it closes the conversation, posts `.asleep` and listens for the phrase again. "Nothing going on" is built in `CycleWiring.snapshot`: no task running or waiting for an answer, nobody speaking, the agent not talking or thinking or running a tool, and no task event still to be said. In wake mode "always", or if HFWake is not linked, `AlwaysOpenCycle` keeps one conversation open, as before.

The cycle starts only once the Microphone permission, the Speech Recognition permission (only if the wake listener needs it, which it does not on macOS 26) and the ElevenLabs key are in place; until then the companion says what it is waiting for.

**Why a task keeps it awake:** a spoken "stop" is heard by the voice session and passed to the stop watcher. While a task runs or waits for an answer, the cycle never closes the conversation, so there is always a session to hear "stop", and the hold-while-speaking signal (`isUserSpeaking`) works as before. While asleep there is no task, `isUserSpeaking` is false, and nothing is held.

On quit, the listening cycle stops (wake listener off, any conversation closed), the runner shuts down (its cancel halts the hands), the hands are halted, and `restoreWebContentSwitches()` undoes the web-accessibility switch AccessibilityLabels turned on in Chrome and Electron apps.

## Linking a package, and why a broken package cannot break the app

Each package under `Packages/` is linked when its name is in `Handsfree/LinkedPackages.txt` (all seven are listed). For each listed package, `build_app.sh`:

1. skips it if `Packages/<Name>/Package.swift` does not exist;
2. runs `swift build` on it in our own folder (`build/package-check/<Name>`), so we never touch the owner's `.build`; if that fails, it retries once from an empty folder, because SwiftPM's cached plan can miss a file just added to HFCore and report a false failure (this happened);
3. links it only if it compiles, by writing `build/generated/linked-packages.yml`, which `project.yml` includes.

The app's code for a package is behind `#if canImport(<Name>)` in `RealParts.swift`, so a package that is not linked is simply not compiled, and `PartAssembly` uses the stand-in from `StandIns.swift`. Stand-ins never act on the Mac, fail with a sentence that can be read aloud, and never say yes to a risky action (the stand-in safety gate asks about everything).

One more trap the script handles: when the set of linked packages changes, it deletes the previous build products. Otherwise a package linked last time leaves its compiled module behind, `canImport` still finds it, and the Swift compiler crashes loading a stale module. That happened on 5 Nov when the HFCore contract changed.

To unlink a package by hand, comment out its line in `LinkedPackages.txt`.

## Integration checklist (6 Nov 2026, 03:00)

All 9 parts are real: every package, including HFVoice and HFWake, is linked and its adapter written. Checked by launching the app (permissions not yet granted) and reading `~/Library/Application Support/Handsfree/app-status.json`, which the app writes at launch (it never contains a key). It now also records `wake_mode`, `wake_phrase`, `sleep_after_idle_seconds`, `listens_for_wake_phrase` and `speech_recognition`.

| Part | Package | Status (6 Nov) |
|---|---|---|
| Voice session | HFVoice | **Real**: `VoiceSession`, prepared once at launch, opened on each wake, closed on each sleep. Text-mode live tests pass against the real agent (5 wakes in a row, nothing left open). |
| Listening cycle | HFWake | **Real**: `ListeningCycle` with the on-device `WakeListener`, adapted in `RealParts.swift` (`WakeCycleAdapter`). Not yet run with a microphone: it starts only after Microphone and Speech Recognition are granted, and no live microphone run was allowed. |
| Sleep tool | HFVoice | **Real**: `go_to_sleep`, refused in code while a task is running or waiting for an answer. |
| All other parts | | As in the table below (unchanged). |

What still has to happen: the user grants the four permissions, then one spoken run with a person: "Hey Handsfree" alone, "Hey Handsfree, open Spotify", "that's all", a task with "stop" in the middle, and 25 s of silence.

### Before wake phrases (5 Nov 2026, 21:42)

7 of 8 parts were real.

| Part | Package | Status |
|---|---|---|
| Hands and quick tools | HFHands | **Real**: `SystemHands`, `QuickTools` (13 tools). Its build failed on and off while its owner was editing it; the script then fell back to the stand-in, as designed. |
| Eyes and labels | HFEyes | **Real**: `ScreenEyes`, `AccessibilityLabels`, quit hook `restoreWebContentSwitches()` |
| Classifiers and safety gate | HFDecisions | **Real**: `Classifiers` (Jev with word-list fallback), `SafetyGate` |
| Stop watcher | HFDecisions | **Real**: `StopWatcher`, cancelling the runner |
| Memory | HFMemory | **Real**: `Memory` at `<data dir>/memory.db`, `MemoryTools` (6 tools) |
| Screen agent | HFScreenAgent | **Real**: `ScreenAgent` with `ClaudeClient` (`claude-sonnet-5-5`) |
| Task runner | HFTasks | **Real**: `TaskRunner`, `TaskTools`; cancel halts the hands first |
| Voice session | HFVoice | Then a stand-in; now real (see above). |

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

**What the user (or a helper) must do once, on this Mac (macOS 26):**
1. Make sure the Mac is online (the first start of the wake listener downloads Apple's speech model; no audio is sent).
2. Run `scripts/run_app.sh --request-permissions --show-panel`.
3. Microphone dialog: click **Allow**.
4. Accessibility dialog: click **Open System Settings**, switch **Handsfree** on (macOS may ask for the password).
5. System Settings > Privacy & Security > **Screen & System Audio Recording**: switch **Handsfree** on, and choose **Quit & Reopen** if offered (macOS applies this one only after a restart).
6. In the panel's LISTENING section, wait for "Wake listener: listening on this Mac for “Hey Handsfree”".

**Speech Recognition is not asked for here.** The wake listener uses Apple's SpeechAnalyzer on macOS 26, which needs only the Microphone (checked on 6 Nov: `SpeechTranscriber.isAvailable` is true and `en_IN` is supported on this Mac). The app asks the listener (`WakePermissions.needsSpeechRecognition` in HFWake) and adds a Speech Recognition step, dialog and panel dot only when it falls back to the older recogniser, on earlier macOS. `app-status.json` records this as `wake_listener_needs_speech_recognition`. The usage text `NSSpeechRecognitionUsageDescription` stays in `project.yml` for that fallback.

The panel lists exactly what is still missing, in words written for whoever is helping, with an "Ask macOS" or "Open Settings" button for each.

**Granting them one at a time is fine.** The app checks every 2 s. The listening cycle starts the moment the Microphone permission and the ElevenLabs key (and Speech Recognition, only where the wake listener needs it) are in place, and until then the companion and the panel say exactly which are still missing ("Waiting for the Microphone permission."). Voice works without Accessibility and Screen Recording; tasks then fail with a sentence saying why.

**Diagnosis: the panel's LISTENING section and `app-status.json` → `listening`.** They show:
- which permissions are granted (one dot each);
- the wake listener: not started (and what it is waiting for), listening on this Mac (with the recogniser's name), paused while a conversation has the microphone, or not running (with the reason);
- the conversation: closed, opening or reconnecting, or open and able to hear;
- counts since launch: how many times it heard speech that was not the phrase, and how many times it woke, with how long ago. **What was said is never stored, logged or shown**, only counted. This is what lets the first real test tell "it cannot hear me" (no counts move while someone speaks) from "it heard me but did not recognise the phrase" (the "not the phrase" count goes up). While asleep the companion's hint also changes for 3 s to "Heard something. Say “Hey Handsfree”" each time.
- `app-status.json` holds the same as `cycle_state`, `waiting_for`, `wake_listener` (`running`, `recognizer`, `problem`, `speech_without_phrase_count`, `phrase_heard_count`, `wake_count`, `restart_count`, seconds since the last of each) and `conversation` (`open`, `connected`). It is rewritten whenever any of these change.
- The "speech that was not the phrase" count needs a content-free diagnostic from HFWake (`speechWithoutPhrase`), requested from its owner on 6 Nov; until it lands that count stays at 0 and the hint does not change. Everything else above works now.

The panel's **TO START** section tells the helper how it is used: "The person says “Hey Handsfree”, then what they want, in one go: “Hey Handsfree, open Spotify”. A rising chime means it is listening. A falling chime means it has gone back to sleep, after about 25 seconds of quiet or when they say “that’s all”. Until the phrase is heard, nothing they say leaves this Mac."

Caveats: if the signing certificate is ever replaced by one with a different name, the grants will be asked for again. On a crowded menu bar, macOS can hide a new status item behind the MacBook's notch; on this Mac the Handsfree icon appears to land there. The panel opens by itself at launch while setup is incomplete, and `--show-panel` opens it any time.

## Keeping the overlay out of screenshots

The screen agent must never see our halo and captions on top of the app it is operating. Two layers do this:

1. The overlay and panel windows set `sharingType = .none`, which tells the window server to leave them out of other processes' captures.
2. HFEyes' `ScreenEyes` leaves every window of our own process out of its ScreenCaptureKit filter (Clicky's method).

**Verified on 5 Nov (A/B test), saved as `docs/research/screens/capture-exclusion-ab.png`:** the demo was frozen on the held confirmation (amber card, halo on the Send button) and the screen was captured by two other processes: macOS's `screencapture` tool, and a small ScreenCaptureKit program that excludes nothing. With the overlay as shipped, neither capture shows the card, glyph or halo. With `--capturable` (`sharingType = .readOnly`), both captures show them. The practice backdrop (a window of the same app, left capturable) appears in all four, which proves the captures were real. ScreenCaptureKit still lists the overlay window (layer 1000) but leaves it out of the image. This test checks layer 1; layer 2 is HFEyes' own test.

## The overlay never takes a click

The overlay covers every screen, so it must let every click through (`ignoresMouseEvents = true`, kept from Clicky). At each launch the app checks this with the window server: for 9 points on every screen, `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` returns the window a mouse-down there would hit, and none may be an overlay. The result is in `app-status.json` (`"overlay_click_through_check": "passed"`) and the log. A negative control was run: with `ignoresMouseEvents` temporarily set to false, the check reported `FAILED`. The check moves nothing and clicks nothing.

## The companion's states

Photographed from the demo over the practice backdrop, in `docs/research/screens/` (01 to 16, plus 17 for the panel). Asleep, waking and awake (6 Nov) were drawn with `--render-states`, because this Mac's terminal no longer has the Screen Recording permission that `screencapture` needs; they show the same SwiftUI views the overlay draws.

| State | What the user sees (and hears) | It ends when |
|---|---|---|
| Asleep | A smaller, still disc in a dim night tint of iris (not the grey of "Not connected") with a moon, and a quiet pill: "Asleep. Say “Hey Handsfree”", the phrase in bright white. No glow, no motion. A falling two-note chime plays when it goes to sleep after a conversation (never at launch) | The phrase is heard |
| Waking | Full-size disc with a bright iris ring, an ear, and a ripple going out; "Heard you". Shown the moment the phrase is heard, before the conversation has opened | The conversation is ready (typically 0.3 s in text mode; voice mode not yet measured) |
| Awake | The iris dot, with "Listening" (ear icon) for 2.5 s. A rising two-note chime plays at this moment: it means "it can hear you now" | Something happens |
| Wake that could not connect | The reason as the caption ("I heard you, but I couldn't reach the voice service. Say the wake phrase to try again."), then asleep again. The session retries once by itself first (a wake that connects on that retry plays only the rising chime); if it still cannot connect within about 4 s it closes everything and a low double note plays as it goes back to sleep, instead of the falling chime | 8 s, then the asleep hint |
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

`scripts/run_app.sh --demo` plays `Handsfree/Demo/DemoScript.swift` (about 60 seconds) on the real ActivityBus, so the companion and the panel react exactly as they would to the real packages: asleep with the hint, the phrase heard (waking, then "Listening" with the rising chime), a message to "Amma" with a which-chat question and a held Send, a task stopped mid-glide, a dropped connection, a failure, and back to sleep (falling chime). The demo plays the chimes, so it makes sound. It uses no network and no permissions, and moves a drawn pointer, never the real one. `--backdrop` puts a plain mock chat app behind it (it covers the Dock but not the menu bar), so recordings show nothing private.

## Tests

`scripts/build_app.sh --test` runs 68 tests in `HandsfreeTests/` (not hosted in the app, so no overlay appears): the event-to-companion mapping, including every state ending by itself and the asleep and waking states; first-run checks and their wording, including Speech Recognition and the "to start" text; the session log; launch options; coordinate conversions and placement at every edge and corner; the demo script, which is checked to reach every glyph, asleep and waking included, and to end asleep; when each chime plays, and that each generated tone is a short valid WAV with no click; and the listening cycle's wiring with a fake voice session and task runner ("is anything going on", the first utterance and fresh memory on open, a wake that cannot connect closes the session and throws, wake mode "always" never sleeps, the thread-safe mirror, the sleep tool's relay).

**Fixed on 6 Nov:** `--quit-after` used to hang the app for ever. It called `NSApp.terminate` from inside a `DispatchQueue.main.asyncAfter` block; quitting waits for shutdown work that runs on the main queue, which cannot run while it is still inside that block. It now uses a run-loop timer, and the app quits on time (checked: asked to quit after 6 s, it was gone after 7). Quitting from the panel's button was never affected.
