# The Handsfree app

Handsfree.app is the native macOS app that holds everything together. It lives in the menu bar (no Dock icon), draws a companion beside the pointer that shows what the agent is doing, and connects every package: the voice, the hands, the eyes, the decisions, memory, the task runner and the screen agent. It is built on the open-source Clicky app (MIT, by Farza); what was taken and why is in `docs/research/clicky.md`, and the file-by-file list is in `third_party/clicky/NOTICE.md`.

## Build and run

You need Xcode 26, XcodeGen (`brew install xcodegen`) and an Apple Development certificate in the keychain (Xcode > Settings > Accounts makes one for any Apple ID).

```bash
scripts/build_app.sh            # Release build, signed, at build/app.noindex/Handsfree.app
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

**Only one copy runs (6 Nov).** On first use, two copies ran at once: the user's, and a demo copy started by the panel's old "Play demo" button. That means two overlays, two wake listeners on one microphone, and possibly two conversations. Now:
- At launch, before anything is created, the app looks for another running process with its bundle identifier (`com.handsfree.Handsfree`), whatever its path, build configuration or how it was started, `open -n` included. If one was running first, the new copy posts a distributed notification asking it to show its panel (a demo launch doesn't) and quits. If two start in the same instant, the earlier launch date wins, then the lower process id. The rule is `Handsfree/App/SingleInstance.swift`, unit tested with fake process lists. Only `--render-states` is exempt: it shows nothing, uses no microphone and quits.
- The panel no longer has "Play demo". The demo is for us (reviewing the look, recording), from the command line only.
- `scripts/run_app.sh` never stops a running copy; it is the user's. A plain start then just brings up its panel. A demo or test launch (`--demo`, `--freeze`, `--quit-after`, ...) refuses with one line: "Handsfree is already running (process N), so this test or demo launch was not started. Quit it from its panel first."
- `scripts/build_app.sh` keeps its app copies out of Spotlight. The build products go to `build/Products.noindex/` (Xcode's `SYMROOT`) and the finished app to `build/app.noindex/Handsfree.app`: Spotlight skips folders whose names end in `.noindex`, so it neither offers these copies nor gets macOS to register them again. A `.metadata_never_index` file was tried first and ignored. `lsregister -u` alone was undone within 40 s, because Spotlight kept indexing the copies and they were registered again. Each build also removes copies left at the old indexed places (`build/Handsfree.app` and DerivedData's products) and unregisters every copy it made. Only the installed copy (`scripts/install_app.sh`, `/Applications`) is found by Spotlight.

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
6. The panel changes from the setup checklist to "Say “Hey Handsfree”". To be sure the listener has started, open "Listening details" and wait for "Wake listener: listening on this Mac for “Hey Handsfree”".

**Speech Recognition is not asked for here.** The wake listener uses Apple's SpeechAnalyzer on macOS 26, which needs only the Microphone (checked on 6 Nov: `SpeechTranscriber.isAvailable` is true and `en_IN` is supported on this Mac). The app asks the listener (`WakePermissions.needsSpeechRecognition` in HFWake) and adds a Speech Recognition step, dialog and panel dot only when it falls back to the older recogniser, on earlier macOS. `app-status.json` records this as `wake_listener_needs_speech_recognition`. The usage text `NSSpeechRecognitionUsageDescription` stays in `project.yml` for that fallback.

The panel is a checklist of what is still missing, in words written for whoever is helping, with one button for the next step ("Allow Microphone", or "Open Microphone Settings" once it has been refused).

**Granting them one at a time is fine.** The app checks every 2 s. The listening cycle starts the moment the Microphone permission and the ElevenLabs key (and Speech Recognition, only where the wake listener needs it) are in place, and until then the companion and the panel say exactly which are still missing ("Waiting for the Microphone permission."). Voice works without Accessibility and Screen Recording; tasks then fail with a sentence saying why.

**Diagnosis: the panel's "Listening details" and `app-status.json` → `listening`.** Which permissions are granted is the setup checklist; once set up, the details show:
- whether the voice service is set up correctly, and when that was last checked;
- the wake listener: not started (and what it is waiting for), listening on this Mac (with the recogniser's name), paused while a conversation has the microphone, or not running (with the reason);
- the conversation: closed, opening or reconnecting, or open and able to hear. While open it also says when it will close: "Goes back to sleep after 15 seconds of quiet, or when they say “that’s all”, with a falling chime; never while a task is running or waiting for an answer." (the number is `SLEEP_AFTER_IDLE_S`);
- counts since launch: how many times it heard speech that was not the phrase, and how many times it woke, with how long ago. **What was said is never stored, logged or shown**, only counted. This is what lets the first real test tell "it cannot hear me" (no counts move while someone speaks) from "it heard me but did not recognise the phrase" (the "not the phrase" count goes up). While asleep the companion's hint also changes for 3 s to "Heard something. Say “Hey Handsfree”" each time.
- `app-status.json` holds the same as `cycle_state`, `waiting_for`, `wake_listener` (`running`, `recognizer`, `problem`, `speech_without_phrase_count`, `phrase_heard_count`, `wake_count`, `restart_count`, seconds since the last of each) and `conversation` (`open`, `connected`). It is rewritten whenever any of these change.
- The "speech that was not the phrase" count comes from HFWake's word-free `speechWithoutPhrase` diagnostic: once per final transcript with words and no phrase. `phraseHeard` carries only the configured phrase, and `woke`'s rest-of-sentence is dropped by the app, so nothing heard while asleep is kept.

Once set up, the panel's ready screen says how it is used: "Say “Hey Handsfree”. Then say what you want, in one go.", with three things to try and what the two chimes mean (the falling chime "after 15 seconds of quiet, or when you say “that’s all”", the number from settings).

Caveats: if the signing certificate is ever replaced by one with a different name, the grants will be asked for again. On a crowded menu bar, macOS can hide a new status item behind the MacBook's notch; on this Mac the Handsfree icon appears to land there. The panel opens by itself at launch while setup is incomplete, and `--show-panel` opens it any time.

## Task news must really be said (6 Nov)

A task's question, confirmation or result that the agent skips, answers with an empty reply or with something else ("On it.") is sent once more, worded so it must be said now. If it is still not said it stays as unsaid news. An unsaid question or confirmation keeps the conversation open; an unsaid result does not (it stays on the panel and is offered again next conversation). Either way `app-status.json` counts it under `spoken_news`. The user's answer reaches a waiting task only after the agent has said that task's question in this conversation, so a "yes" said before the question was heard is never consent; the question is asked again instead. Details in `docs/spikes/elevenlabs.md` §15.

A yes to a held action is judged on the user's own words: when the agent passes on an answer to a confirmation, the task gets the user's most recent sentence after the confirmation was said, not the agent's wording. With no sentence from the user since then, nothing is passed on. (For an ordinary question such as "which Priya?" the agent's wording is still used.) Task news is never said more than 30 minutes after it happened. News that cannot be delivered (no conversation, or one that has not reconnected within 30 s) waits for the next conversation and does not keep the app awake. A goodbye ("that's all") waits up to 15 s for the conversation to go quiet, and past that never closes while the agent is still talking (it may be saying a result), up to 60 s in all. A task that starts in the moment the app decides to sleep is stopped at the close, so nothing runs with no conversation to hear "stop".

## A task owns the hands (6 Nov)

While a task is running or waiting for an answer, quick tools that use the pointer or keyboard (type_text, press_keys, shortcut, pointer, scroll, open_app, open_url, and any quick tool added later) refuse with "A task is in progress. Say the question aloud, or use answer_task or cancel_task." (`Handsfree/Integration/TaskOwnsHands.swift`). The backup model once typed a task's question into the focused field with type_text; this makes that impossible. Still allowed: where_am_i, read_text, take_screenshot, and set_volume, set_brightness and media_control (top-row keys go to the system as system-defined events, never to the focused field), plus memory, task_status, answer_task, cancel_task and go_to_sleep.

## The voice agent is kept in step with the app (6 Nov)

**What went wrong.** In the user's first spoken conversations, the agent on ElevenLabs had one tool, `demo_set_volume`, put there by the live tests. The app's update at launch had been rejected every time: ElevenLabs answers **HTTP 400, "Must set one of: description, dynamic_variable, …"** when any tool parameter has no description. Four did: `media_control.action`, `scroll.direction`, `shortcut.action` and `pointer.action`, all in HFHands. The error was only logged. So the agent apologised that it could only change the volume, once claimed YouTube was open with no tool call at all, and could not "stop listening".

**What is true now:**
- The conversion (`AgentConfiguration.clientTool`) gives every parameter a description, at any depth, so ElevenLabs accepts all 24 tools. It is a safety net: the four parameters that lacked one now have real descriptions at their source in HFHands (`QuickTools.swift` and `Fixtures/quick_tools.json`), and the live sync test reports any parameter still relying on the fill-in.
- An update counts only when a read-back of the agent shows exactly the app's 24 client tools and the built-in `skip_turn` tool (`AgentSyncer.verify`). A missing `skip_turn` is listed under `missing`. A different model or reasoning setting read back (ElevenLabs may alias or retire a model) is only a `warning`: logged and shown, never a refusal. It starts at launch, whatever the permissions.
- Three states: in step; **out of step** (a confirmed mismatch, or an update ElevenLabs refused); and **could not check** (`couldNotCheck`: network, timeout, 5xx, 429 or an answer that would not decode, which says nothing about the agent). Read-backs time out after 5 s, updates after 10 s. Every check is numbered when it starts, and an older result is ignored unless it confirms the agent in step, so a slow update that fails late cannot put a red banner over a working conversation.
- A wake is refused only for a confirmed mismatch that a repair, tried at once for at most 4 s, could not fix: "Handsfree's voice isn't set up correctly yet. It is trying again." A failed or slow check never refuses a wake and never re-sends the definition. Each wake reads the agent back alongside connecting (0.2–0.3 s); nothing is said, and "listening" isn't shown, until it answers or 2 s pass. If it confirms the agent changed, that conversation is ended unheard, the agent is updated (at most 4 s), and it reconnects. Otherwise the conversation carries on. What is true while the read-back is pending: the agent can already hear the user (speech cannot be held). With a good check earlier in this launch, tool calls run as normal; with none yet (the first wake, with the launch update failed), tool calls wait for the read-back, at most 2 s. A call from a conversation that has since closed or been replaced never runs. The repair after a confirmed mismatch is retried after 30 s, 1 min, 2 min, then every 5 min.
- When ElevenLabs cannot be reached at a wake, the sentence is "I can't reach the voice service right now. Say Hey Handsfree to try again."
- When it is out of step, the panel shows a red banner, "Handsfree’s voice could not be set up", saying it cannot wake and what to do, and its header says "Needs attention". When it is in step, the panel says nothing about it, apart from one line in "Listening details" ("Voice: set up correctly, checked 12 s ago"). The names of missing or extra tools are only in the status file and the log. `app-status.json` has `listening.agent` (`in_sync`, `tool_count`, `expected_tool_count`, `checked_seconds_ago`, `problem`, `missing`, `unexpected`, `could_not_check`, `warning`). The red banner and the companion's "cannot wake" hint are for a confirmed mismatch only; "could not check" is shown amber.
- A call to a tool the app doesn't have is answered "There is no tool called X in this app. Do not try it again, and do not say it was done…". The agent is also marked out of step and repaired at once.
- Tests and `hf-voice text/talk` use their own agent, "Handsfree TEST agent (tests only, safe to delete)", with its id in `.env` as `ELEVENLABS_TEST_AGENT_ID`. The prompt evaluation uses another, `ELEVENLABS_EVAL_AGENT_ID`. In code, test tools are refused for the app's agent, a test agent can never be the app's agent, and an update never renames an agent.
- `swift run hf-voice check` (read only, in `Packages/HFVoice`) prints the app's agent's tools; `check --test` does the same for the test agent. `scripts/run_app.sh --sync-only --quit-after 12` updates and checks the agent and starts no listening (no microphone).
- Live proof: `HF_LIVE=1 swift test --filter AgentSyncLiveTests` in `Packages/HFIntegration` sends the real tools from every package to the test agent and reads them back, and checks that a setup-style update without tools keeps them. After a `--sync-only` launch on 6 Nov, `hf-voice check` showed the app's agent with all 24 tools.

## Stopping it listening

- **In the user's own words, decided by the app** (`Handsfree/Integration/SleepPhrases.swift`, routed by `SentenceRouting.swift`). "Stop listening", "go to sleep", "that's all", "that's it", "goodbye", "we're done" and close variants end the conversation when they are the whole sentence, give or take "thanks", "okay", "please" or the wake name. The sign-off goes to the cycle's `requestSleep`, which waits for the agent's short reply. "Stop", "stop the music", "be quiet" and "send Amma a message saying that's all for today" are not sign-offs. "Yes, that's it" isn't either, since it usually answers the agent's question.
- **The stop watcher hears every sentence (since the 6 Nov review).** A sign-off is detected as well, never instead. The wake phrase and its alternatives are taken off the front first, so "Hey Handsfree stop" reaches it as "stop": an instant stop, with or without a comma, even with Jev down. A stop at the end of a longer sentence ("okay stop listening to him and stop") is left to Jev, because "don't stop" also ends in "stop".
- **"Stop listening" during a task stops it at once, then sleeps.** It is an instant stop phrase in HFDecisions, even while a question waits for a yes, since someone who says it mid-action almost certainly means "stop everything". The other sign-offs ("that's all", "goodbye", "go to sleep") let the task finish and its result be said, then it sleeps.
- **During a task**, or while a question waits for the user's yes, a sign-off never sleeps over it: it sleeps as soon as the task ends. Anything else the user says afterwards takes the sign-off back. Example: "that's all", then "actually, open my email after that" does not sleep over the new request. The go_to_sleep tool gets the same answer ("It will stop listening as soon as the task ends; say so in a few words"), so the agent's words match what happens. These rules are tested in `HandsfreeTests/SentenceRoutingTests.swift` and HFDecisions' `StopListeningRuleTests`.
- **By itself, after quiet:** `SLEEP_AFTER_IDLE_S`, now 15 s after the last thing said, with a falling chime. A wake where the user says nothing at all sleeps after `SLEEP_AFTER_UNUSED_WAKE_S` (8 s), counted from the connect or the end of the agent's greeting or news. Anything they say (the rest of the wake sentence, a transcript, or a task starting) switches that conversation to the ordinary 15 s. Voice activity alone (someone nearby, a TV) does not count as saying something. HFWake's `ListeningCycle` reads both settings through `init(settings:)`; tests are in its `CycleUnusedWake` suite. Live proof that idle sleep happens: `HF_LIVE=1 swift test --filter LiveIdleSleepTests` in `Packages/HFIntegration` uses a real text conversation, HFWake's real cycle and a 6 s idle time; it went back to sleep 6.5 s after the agent's reply.
- **What resets the idle wait:** the user's speech (voice activity of at least 0.5, or a transcript), the agent talking, thinking or running a tool, a task running or waiting, and task news not yet said. Low room noise does not: a quiet room measured 0.000 median and 0.002 at the 90th percentile, and the agent's own voice through the speakers at most 0.11. Since 6 Nov `.userSpeaking` is posted only from 0.5, so low noise no longer counts. **People talking nearby, or a TV, do count as speech** and will keep it awake while they talk; that needs a spoken test in the user's room.

## A locked Mac

`Handsfree/Integration/ScreenLock.swift` has one lock check (`ScreenLock.isLockedNow`), used by the app's tools, its task executor and the script runner alike. While the Mac is locked, no quick tool and no task step acts, and Handsfree says "The Mac is locked, so I can't use it until someone unlocks it."
- **A held action is never pressed on a locked Mac.** The lock is checked before the question is asked, and again when the answer comes back, the last moment before the press. Example: "Send it to Amma?" waits a few minutes, the Mac locks itself, then the user says yes. The task ends with the lock sentence and nothing is pressed. (Tested in "A held action on a locked Mac".)

**Known limits:**
- Media and volume keys are refused while locked, although macOS's own media keys work on the lock screen. This keeps the rule simple and safe for now.
- The screen saver before its lock starts, a sleeping display, and a user switched out by fast user switching all read as unlocked. In those states Handsfree may try to act on a screen it cannot really use, as it did before this rule.
- The lock flag (`CGSSessionScreenIsLocked`) is not documented by Apple. If it can't be read, the Mac is taken as unlocked.

## The menu bar panel (redesigned 6 Nov)

The panel is the window that drops down from the menu bar icon, and opens by itself while setup is incomplete. It is for the person helping as much as for the user. The first version was one dark, custom-drawn card of labelled sections (setup, listening, to start, now, conversation, learned, parts). It read like a debug console. The new panel looks like a current Mac utility. It sits on the system's own translucent material, follows light and dark mode, and is built from SF Pro, SF Symbols and grouped cards on a 4/8-point grid, with one accent (iris).

**Three layouts, chosen by one rule** (`PanelSnapshot.mode`, unit tested):

| Layout | When | What it shows |
|---|---|---|
| Setup | Any permission or required key is missing (never in the demo) | "Set up Handsfree", a progress bar ("2 of 4 done") and one row per requirement: icon, name, a one-line reason ("So it can move the pointer, click and type for them") and its state as an icon and a word (Done, Needed, Turned off). The next step opens out with what to do and one primary button ("Allow Microphone", or "Open Screen Recording Settings" once refused). A missing keys file shows where the file goes and its three lines. |
| Ready | Set up and asleep, with no task running | The wake phrase in large type, from settings (`Say “Hey Handsfree”`), a card of three things to try, two quiet lines on what the chimes mean (the quiet time from settings), then the last task and what it remembers, if any |
| Active | Awake, or a task is running | With no task running, a card for what it is doing now (Listening, Hearing you, Done, Couldn't finish…). While a task runs, the task card is the status: the goal as its title, a small moving "Working" dot in its header, and its last five steps, the current one marked. While it waits, an amber card on top with the question in large type and "Say “yes” to go ahead, or “no” to stop.", and the task card lists only its last two steps. Then the conversation as a message thread: the user on the right in iris, Handsfree on the left in grey, each turn named |

**Trouble banners** sit above any layout: red when Handsfree cannot work, amber when it works but needs a look. There are five kinds. "Handsfree's voice could not be set up" (red) means a confirmed mismatch between the voice service and the app, so it cannot wake. "Handsfree couldn’t check its voice just now" (amber) means the check itself failed (offline, slow or busy): nothing is known, it still wakes, and "It will check again when you wake it." A difference in the model or reasoning setting is never a banner, only a quiet line in "Listening details". "Handsfree cannot reach its voice service" means the connection dropped. "Handsfree cannot listen for “Hey Handsfree”" means the wake listener stopped. "It hears speech, but not “Hey Handsfree”" appears after 3 or more pieces of speech with no wake. While a red one stops it waking, the ready layout greys its hero and says it will listen again once the problem is fixed. With any banner, the header says "Needs attention" with a warning symbol (red or amber, as the banner), never "Asleep" above a banner saying it cannot wake. A missing key is not a banner, because it sends the panel to the setup checklist. When all is well, nothing is said about the voice service at all.

**Always there:** the header (the app's mark, its state as an icon and a word, and the close button), a closed "Listening details" section with the diagnostic lines for whoever is checking why it does not respond (counts only, never what was said), and a quiet footer with "Quit Handsfree", the wake mode and the version. There is no "Play demo".

**Accessibility, the track being judged:**
- Every button has a visible text label that Voice Control can say. The close button is the only icon-only control.
- Colour is never the only signal: every state pairs a colour with an icon and a word.
- Text colours meet WCAG AA in both appearances. The ratios are noted beside each token in `DS.Panel`, and the system's own grey secondary text (about 3.9:1 on white) is not used.
- VoiceOver reads the header as "Handsfree, Asleep" and the checklist row by row with each state. It reads conversation lines as "You said: …" and "Handsfree said: …".
- Pulsing stops under Reduce Motion. Escape closes the panel. Keyboard and VoiceOver order is top to bottom: header, banners, content, details, footer.
- Text scales: every panel font and symbol goes through `panelFont` and `panelSymbol`. macOS has no system text size for apps, so a carer can set one with `defaults write com.handsfree.Handsfree PanelTextScale 1.3` (1 to 1.6). No word is ever broken. Where two texts share a line, they stack when they no longer fit: the footer's Quit and its quiet information, and a checklist row's name and state. Renders `11-larger-text` (1.4) and `11b`–`11d` (1.6, the largest) show this. Every state is also drawn at 1.6 into the render folder's `panel/largest/` for checking.
- Long content scrolls instead of clipping. The conversation scrolls beyond 220 points (× text size) and stays pinned to the newest line. The whole body scrolls beyond 680 points, or less on a short screen: each time the panel opens, the manager keeps 150 points (× text size) for the header and footer, and the window never runs past the bottom of the screen.

**The window** (`MenuBarPanelManager.swift`). The panel sits on an `NSVisualEffectView`, material `.popover`, blending behind the window. That is the system's own translucent material: it follows light and dark mode, and turns opaque under Reduce Transparency. It is rounded to 16 points by a stretchable mask image with continuous corners, the same shape as the SwiftUI clip and edge line. It has the system window shadow, which follows the mask. The SwiftUI content reports its own height whenever it changes (a new line, a step done). The window follows it just after that layout pass, even while hidden, so it opens at the right size, and it keeps its top edge 4 points under the menu bar. Escape closes it (`cancelOperation` on the panel). Kept from Clicky: non-activating, centred under the icon, closes on a click elsewhere after 0.3 s, and reopens when the app is opened again.

A second agent reviewed this window code, since a render cannot exercise it. It found three bugs, now fixed:
- **The panel stretching with a blank gap.** The conversation's own scroll area passed its full, unclipped height up to the body's measurement, so the panel would have stretched with a blank gap once a conversation got long. Each scroll area now stops its height at its own edge.
- **Escape not closing it.** `onExitCommand` never fires in this panel, because nothing in it holds keyboard focus.
- **A thin strip on first open.** The first opening could show a thin strip for up to 2 s, until the next refit.

**Files** (all in `Handsfree/Panel/` unless noted):

| File | Job |
|---|---|
| `PanelSnapshot.swift` | Everything the panel shows, as plain values, and the rules: which layout, which main button, whether it can wake. Pure, unit tested |
| `PanelSnapshotBuilder.swift` | Makes a snapshot from the live model's values: `SetupFacts`, `CompanionState`, `SessionLog`, `ListeningStatus`. Pure, unit tested |
| `PanelCopy.swift` | Every sentence the panel shows, in one place. The wake phrase is always passed in |
| `PanelView.swift` | The live panel: watches `AppModel` and `CompanionModel` and draws a fresh snapshot of them (AppCoordinator creates it; the call is unchanged) |
| `PanelRootView.swift` | Header, banners, one of the three layouts, details, footer |
| `SetupChecklistView.swift`, `ReadyView.swift`, `ActivityView.swift` | The three layouts |
| `TaskCardView.swift`, `ConversationThreadView.swift`, `TroubleBanner.swift`, `PanelFooter.swift` | One part each |
| `PanelComponents.swift` | Card, section heading, icon tile, status tag, pulsing dot, and a scroll area that is only as tall as its content |
| `Handsfree/Design/DesignSystem.swift` | `DS.Panel`: adaptive colours (a SwiftUI `ShapeStyle`, so they also resolve when drawn off screen), the type ramp, and the panel's button styles |
| `Handsfree/Demo/PanelStateCatalogue.swift` | The review states, each made from real events through the builder; also used by the tests |
| `Handsfree/Demo/PalettePNG.swift` | Writes the renders as 256-colour PNGs, about 65 KB each instead of 500 KB |

**Rendering it:** `scripts/run_app.sh --wait --render-states build/renders` also writes every panel state, in light and dark, to `build/renders/panel/`. The committed set is in `docs/research/screens/panel/`: first run, mid setup, a refused permission, keys missing, ready, ready after a task, listening, a task running, waiting for a yes, finished, failed, three trouble banners, a long session (a 160-character goal, 12 steps, 30 turns) and larger text. `24-panel-first-run` and `26-panel-asleep-ready`, in the render folder itself, are drawn through the real `PanelView` from a real `AppModel` and `CompanionModel`, the same path the app uses.

**What a render cannot show.** The material cannot be drawn off screen, so renders use a flat stand-in colour close to it (`DS.Panel.snapshotBackground`). The real panel's translucency, vibrancy, window shadow, rounded mask, hover and pressed states, the pulsing animation, scrolling, and the window resizing to its content have to be checked by looking at the real panel on screen.

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

`scripts/build_app.sh --test` runs 111 tests in `HandsfreeTests/` (6 Nov, 24 of them the panel's; not hosted in the app, so no overlay appears): the event-to-companion mapping, including every state ending by itself and the asleep and waking states; first-run checks and their wording, including Speech Recognition and the "to start" text; the session log; launch options; coordinate conversions and placement at every edge and corner; the demo script, which is checked to reach every glyph, asleep and waking included, and to end asleep; when each chime plays, and that each generated tone is a short valid WAV with no click; and the listening cycle's wiring with a fake voice session and task runner ("is anything going on", the first utterance and fresh memory on open, a wake that cannot connect closes the session and throws, wake mode "always" never sleeps, the thread-safe mirror, the sleep tool’s relay); and the menu bar panel (`PanelRedesignTests.swift`: the layout and main button for every review state, the mapping from the live model, that the wake phrase comes from settings, and that nothing the panel says mentions tools, syncing or agent IDs).

**Fixed on 6 Nov:** `--quit-after` used to hang the app for ever. It called `NSApp.terminate` from inside a `DispatchQueue.main.asyncAfter` block; quitting waits for shutdown work that runs on the main queue, which cannot run while it is still inside that block. It now uses a run-loop timer, and the app quits on time (checked: asked to quit after 6 s, it was gone after 7). Quitting from the panel's button was never affected.

**Why idle never expired in the user's first spoken runs (6 Nov), from the conversation records:** the three conversations lasted 71, 78 and 91 s, with a turn every few seconds (10–11 from the user and 10–17 from the agent in each). The longest gaps between turns were 9, 10 and 22 s, and all three ended because the app was quit. So the quiet never lasted the 25 s the idle wait then needed; the user kept speaking (including "stop listening" six times) and the agent kept replying. Nothing in the record points to room noise, and that build already posted voice activity only from 0.5. With the 15 s wait, the sign-off rule and the 8 s unused-wake rule, those sessions would have ended.
