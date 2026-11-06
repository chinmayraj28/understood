# Handsfree

Handsfree is a native macOS app that lets a person who cannot use their hands run their Mac by speaking goals. You say "WhatsApp Mum: running late, ten minutes", and it opens WhatsApp, finds the chat, types the message and reads it back. It sends nothing until you say yes.

It is my submission for the Hiya Voice AI Challenge (Accessibility track). The one-page write-up is in [WRITEUP.md](WRITEUP.md) and the AI tools I used are described in [ai.md](ai.md).

## How it works

The agent uses the Mac the way a person sits at it. It looks at the screen, moves the real pointer, clicks, scrolls and presses keys, in your own apps and your own Chrome, while you watch. It does not script apps behind the scenes, so there is no AppleScript, no hidden browser and no per-app integration.

In words, the pieces are these:

1. **Voice.** An ElevenLabs conversation agent hears you, talks back, asks questions ("Priya Shah or Priya Patel?") and waits patiently for slow speakers.
2. **Quick tools.** One-step commands such as volume, scrolling, opening an app through Spotlight, or a keyboard shortcut. Each is done with real key presses, in about a second.
3. **Screen agent.** For any goal that takes several steps, Claude looks at a screenshot, picks one action, and the real pointer and keyboard carry it out. The task runs in the background of the conversation, so it can pause to ask you something.
4. **Safety gate.** Before every click and every Return key press, code reads the name of the control under the pointer (for example `button "Send" in WhatsApp`) and decides whether you must say yes out loud first. If it is unsure, it asks.
5. **Stop.** Every sentence you speak is checked for "stop". A stop freezes the pointer and keyboard mid-movement.
6. **Memory.** It remembers things you tell it ("Mum is Amma on WhatsApp") and learns which Priya you usually mean. It is stored on the Mac only.
7. **Companion.** A small shape beside the pointer shows what the agent is doing: listening, thinking, moving, clicking, waiting for your yes.

The app shell (menu bar panel, the overlay beside the pointer, the design tokens, the permission checks) is adapted from [Clicky](https://github.com/farzaa/clicky), an MIT-licensed open-source Mac app by Farza. Everything under `Packages/` was written for this project. The details are in [Credits](#credits).

## Waking and sleeping

The app does not keep a microphone conversation open all day. It sleeps, and while it sleeps it listens on the Mac itself for a wake phrase, "Hey Handsfree" by default, using Apple's on-device speech recognition (SpeechAnalyzer on macOS 26). Nothing it hears while asleep leaves the laptop, and no audio is saved or logged. When it hears the phrase it opens a conversation with the ElevenLabs agent. Anything said in the same breath ("Hey Handsfree, open Spotify") becomes the first message. When nobody has spoken for a while and no task is running (25 seconds by default), it closes the conversation and sleeps again. A task waiting for your yes is never put to sleep.

I chose this so that ElevenLabs minutes are used only while someone is talking, and so that other people's voices in the room are not sent to the cloud. There is still no key to press, because the people this is for cannot press one. Full detail, measurements and limits are in `docs/WAKE.md`.

| Setting in `.env` | Default | Meaning |
|---|---|---|
| `WAKE_PHRASE` | `Hey Handsfree` | What you say to wake it |
| `WAKE_MODE` | `phrase` | `phrase` sleeps until the phrase is heard. `always` keeps a conversation open the whole time, for demos and testing |
| `SLEEP_AFTER_IDLE_S` | `15` | Seconds of quiet, with no task running, before it sleeps (minimum 5) |
| `SLEEP_AFTER_UNUSED_WAKE_S` | `8` | The shorter wait when nothing was said after waking (minimum 3) |
| `WAKE_LANGUAGE` | the Mac's own | The English the recogniser listens in: `en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA` |
| `WAKE_ALTERNATIVES` | none | Extra phrases that also wake it, separated by commas |
| `WAKE_STRICTNESS` | `balanced` | `strict`, `balanced` or `lenient` |

**What you see and hear.** Asleep, the companion is a small still disc with a moon and the hint "Asleep. Say “Hey Handsfree”". Waking, it shows that it heard you. Awake, a rising two-note chime plays and it shows "Listening". Going back to sleep plays a falling two-note chime. The macOS orange microphone light is on while it sleeps, because the Mac is listening for the phrase.

**If the phrase is not heard**, change one setting at a time in this order and restart the app after each:

1. `WAKE_LANGUAGE`: set it to the speaker's own English (`en_GB`, `en_US`, `en_IN` and so on). Accent changes how every word is heard, and this made the biggest difference in testing.
2. `WAKE_ALTERNATIVES`: add a phrase the person can say clearly, such as `Hello Sam's Mac`. A two-word phrase with a greeting first works best.
3. `WAKE_STRICTNESS=lenient`: last, because it also wakes by mistake more often.

Under "Listening details" at the bottom of the panel, the app counts how often the Mac heard speech that was not the phrase (it never stores what was said). If that count goes up when you say the phrase, the Mac hears you but does not recognise the phrase, and the steps above help. If it stays at zero, look at the microphone instead.

## Status

> **To be updated before submission.** This is what was true on 6 November 2026.

- Every package builds and passes its unit tests (770 package tests and 74 app tests in the last run; see [Run the tests](#run-the-tests)). A clean clone of the repository builds and passes (see [Setup](#setup)).
- The first demo task, drafting a WhatsApp message and stopping before sending, has been run for real through the screen agent from the command line (17.0 seconds, five model turns, the send refused as intended; see `docs/SCREEN_AGENT.md`).
- A typed conversation with the real ElevenLabs agent works.
- **The wake phrase has been tested only with synthetic voices.** Sentences written to sound files with macOS's `say`, in nine English voices and three speeds, were fed to Apple's recogniser in place of the microphone: 100 of 108 wake sentences were caught, and 3 false wakes in 132 other sentences came from one sentence. 114 seconds of ordinary conversation caused no wakes. It has never been tried with a real voice or a real microphone.
- **Not yet done:** a full spoken run through the built app. The app has not yet been granted its macOS permissions. The Google Meet task has not been run, because Chrome was signed out of Google.

If you only have a few minutes, use the [demo mode](#try-it-without-any-setup-demo-mode), which needs no keys and no permissions.

## What you need

- A Mac with Apple silicon. The project was built and tested on macOS 26.3.1 with Xcode 26.6 (the app targets macOS 14 or later, and the build script builds for `arm64`).
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- An Apple Development certificate in your keychain. Xcode creates one for any Apple ID (Xcode > Settings > Accounts). Without it the build still works but is signed ad hoc, and macOS will forget the permissions you grant after every rebuild.
- About 10 GB of free disk (a clean clone measured 9.0 GB after building).
- Three API keys (not needed for demo mode):

| Key | What it is for |
|---|---|
| `ELEVENLABS_API_KEY` | The voice conversation. It needs write access to Agents (ElevenAgents) and access to Text to Speech, Speech to Text and Voices (read) |
| `ANTHROPIC_API_KEY` | Claude, which looks at the screen and chooses each action, and which writes memory from finished tasks |
| `OPENROUTER_API_KEY` | Jev, a fast classifier from TypeSafe, used for the stop check, the safety check and reading your yes or no. Optional: without it, fixed keyword rules decide instead, and the safety check asks whenever it is unsure |

- Optional, for the demo tasks: WhatsApp installed and signed in, and Chrome signed in to Google.

## Setup

**Warning about the first build.** The ElevenLabs Swift SDK brings LiveKit and WebRTC as prebuilt frameworks of about 2.3 GB. Measured on a clean clone on 6 November 2026 (on the Mac that built the project, so its download cache may have been warm; a first-ever download on a slow connection will take longer): step 3 below took 1 minute 11 seconds, step 4 took 5 minutes 56 seconds including the app's tests, and the clone used 9.0 GB afterwards (4.7 GB in `build/DerivedData`, 3.0 GB in `Packages/HFVoice/.build`, 1.2 GB in `build/package-check`). Later builds take seconds to a minute or two.

1. Get the code and enter the folder.

```bash
git clone <repository-url> handsfree
cd handsfree
```

2. Create your settings file and fill in the three keys. `.env` is ignored by git.

```bash
cp .env.example .env
chmod 600 .env
open -e .env
```

3. Create the ElevenLabs agent. This defines the agent from code (its prompt, tools and turn-taking settings), then writes `ELEVENLABS_AGENT_ID` into `.env`. It is safe to run again.

```bash
cd Packages/HFVoice
swift run hf-voice setup
cd ../..
```

4. Build the app. This generates the Xcode project, checks that each package compiles, builds a signed Release app at `build/Handsfree.app`, and verifies the signature. With `--test` it also runs the app's own unit tests.

```bash
scripts/build_app.sh --test
```

Other options: `--debug` for a Debug build, `--generate-only` to write `Handsfree.xcodeproj` and open it in Xcode.

5. Optional: install it as an ordinary app. `scripts/install_app.sh` builds, copies the app to `/Applications/Handsfree.app`, and links `~/Library/Application Support/Handsfree/.env` to the repository's `.env`, so an app opened from Finder finds your keys. Quit Handsfree first if it is running. This script was not part of my clean-clone check.

## Grant the macOS permissions

Only you can grant these, and they belong to Handsfree.app (not to your terminal). Do it once. On macOS 26 there are three: Microphone, Accessibility and Screen Recording. Speech Recognition is asked for only on older macOS, where the wake listener falls back to Apple's older recogniser.

1. Make sure the Mac is online. The first start of the wake listener may download Apple's speech model for the language. No audio is sent.
2. Run the app with the permission dialogs:

```bash
scripts/run_app.sh --request-permissions --show-panel
```

3. **Microphone:** click Allow.
4. **Accessibility:** click Open System Settings, switch Handsfree on (macOS may ask for your password). This lets it move the pointer and press keys.
5. **Screen Recording:** open System Settings > Privacy & Security > Screen & System Audio Recording and switch Handsfree on. Choose Quit & Reopen if macOS offers it. This lets it take screenshots.
6. Wait for the panel to change from the setup checklist to "Say “Hey Handsfree”". The wake listener's state is under "Listening details" at the bottom of the panel.

You can grant them one at a time; the app checks every two seconds. The panel lists exactly what is still missing, with a button for each. Voice works without Accessibility and Screen Recording, but tasks then fail with a sentence saying why. On a crowded menu bar, macOS can hide the new icon behind the notch; the panel also opens by itself at launch while setup is incomplete.

Whether a grant survives a rebuild on this Mac has not yet been observed. The signing design says it should (`docs/APP.md`).

## Run it

```bash
scripts/run_app.sh
```

The app has no Dock icon. It lives in the menu bar and draws its companion beside your pointer. Quit it from the panel ("Quit Handsfree") or with `pkill -x Handsfree`. It never adds itself as a login item.

**A first run, in this order:**

1. Say "Hey Handsfree" on its own, then wait for the rising chime. That means it is listening.
2. Say "Turn the volume to thirty percent." Then say nothing for 25 seconds and listen for the falling chime.
3. Say "Hey Handsfree, open Spotify" in one breath. It should open Spotify without asking again.
4. Say "that's all" to send it back to sleep early.

**Other things to say** (after the wake phrase):

- "Scroll down." "Open Spotify." (quick tools)
- "WhatsApp Mum: running late, ten minutes." It drafts, reads the message back and waits for your yes before sending. Use a test contact: it really types in your WhatsApp.
- "Remember that Mum is Amma on WhatsApp." "What do you know about me?" "Forget that." (memory)
- "Stop." Freezes whatever it is doing.

Other launch options: `--quit-after 20` (quit by itself), `--wait` (block until the app quits). Set `WAKE_MODE=always` in `.env` to keep a conversation open without the phrase.

## Try it without any setup (demo mode)

Demo mode plays a scripted run of about 60 seconds so a reviewer can see the companion without keys, network or permissions. It moves a drawn pointer, never the real one. It does make sound: it plays the rising and falling chimes.

```bash
scripts/build_app.sh
scripts/run_app.sh --demo --backdrop
```

The script shows the app asleep with its hint, the phrase heard, a message to "Amma" with a which-chat question and a held Send, a task stopped mid-glide, a dropped connection, a failure, and back to sleep. `--backdrop` puts a plain mock chat window behind it. Add `--loop` to repeat, or `--freeze holding` to stop at one moment (others: asleep, waking, listening, speaking, heard, thinking, progress, moving, clicked, typing, asking, answering, done, stopped, disconnected, reconnected, failed, asleep-again). Screenshots of every state are in `docs/research/screens/`.

## Run the tests

Each package builds and tests on its own, with the network and the Mac faked behind protocols:

```bash
cd Packages/HFCore && swift test    # likewise HFDecisions, HFEyes, HFHands, HFMemory,
                                    # HFScreenAgent, HFTasks, HFVoice, HFWake, HFIntegration
scripts/build_app.sh --test         # the app's own tests
```

Results of the last full run (6 November 2026, `swift test` in each package):

| Package | Tests | Package | Tests |
|---|---|---|---|
| HFCore | 25 | HFTasks | 55 |
| HFDecisions | 86 | HFVoice | 91 |
| HFEyes | 40 | HFWake | 100 |
| HFHands | 127 | HFIntegration | 58 (1 known issue) |
| HFMemory | 121 | the app (`HandsfreeTests`) | 74 |
| HFScreenAgent | 67 | **Total** | **844** |

All passed. The known issue in `HFIntegration` is deliberate and recorded in the test: one failed wake shows one disconnection per reconnect attempt instead of one in total. `HFIntegration` holds the cross-package tests that feed one package's real output into another.

Tests that touch the real Mac or a real API only run when `HF_LIVE=1` is set. They move the real pointer and press real keys, so take the lock first and release it straight after:

```bash
scripts/live_lock.sh acquire <your-name>
cd Packages/HFHands && HF_LIVE=1 swift test --filter Live
cd ../.. && scripts/live_lock.sh release <your-name>
```

Command-line tools for trying one part on its own: `swift run hf-voice text` or `talk` (in `Packages/HFVoice`), `swift run hf-wake status` (in `Packages/HFWake`), `swift run hf-agent "Open TextEdit and type hello"` (in `Packages/HFAgentCLI`, moves the real pointer), `swift run hf-hands --list` (in `Packages/HFHands`). Live tests send messages and invites only to `TEST_WHATSAPP_CONTACT` and `TEST_INVITE_EMAIL` from `.env`; if either is empty they stop at the draft.

## What leaves the laptop, and what does not

| What | Goes to | When |
|---|---|---|
| Your voice, as audio, and the agent's replies | ElevenLabs | Only while the app is awake and a conversation is open |
| Screenshots of your main display | Anthropic (Claude) | Only while a task is running |
| Short descriptions of an action ("Click button Send in WhatsApp"), your spoken sentences for the stop check, and your replies to a confirmation | OpenRouter, which passes them to Jev | Only if `OPENROUTER_API_KEY` is set. Fixed rules decide first where they can (77% of risk decisions in the final run were made by rule, with no network) |
| The goal and your answers to its questions, with message wording replaced by `[message]`, for learning | Anthropic (Claude Haiku) | After a task finishes |

What stays on the Mac: the wake phrase listening (Apple's on-device recogniser; no audio is saved, and no transcript is logged or stored; the only network use is macOS downloading its speech model once), the memory database (`~/Library/Application Support/Handsfree/memory.db`), the logs, and your keys. The text inside message bubbles is left out of what is sent to the classifier. Memory never stores passwords, PINs, card numbers, one-time codes or the content of private messages.

Hiding our own overlay from screenshots is checked: the overlay is left out of the screenshots Claude sees, which was tested with two other capture tools (`docs/APP.md`).

## Safety rules the product follows

- It never sends, pays, deletes, submits or invites without a spoken yes.
- The check runs in code before every click and every Return key press, using the name of the control under the pointer, read at the moment of the click. The model cannot skip it by forgetting.
- A control that cannot be identified counts as unknown, and unknown is never treated as safe. If Jev is down, slow or unsure, the gate asks.
- "Stop" freezes the pointer and keyboard within a fraction of a second, even mid-glide or mid-sentence.
- It never operates password prompts, Touch ID prompts, installers, software updaters, "are you sure you want to open this downloaded app" warnings or password managers. This rule exists because of a real incident, described in [ai.md](ai.md).
- It never types into a password field. Typing refuses a line break unless told otherwise, because Return sends in chat apps.
- A remembered choice never lowers safety: a yes to a confirmation is never learned.
- While you are speaking, it holds new actions, so a spoken "stop" can win. The wait is bounded so background noise cannot freeze a task.

## Map of the repo

```
Handsfree/            the app: menu bar panel, overlay companion, setup, demo, and the
                      composition root that connects the packages (adapted from Clicky)
HandsfreeTests/       the app's unit tests
Packages/
  HFCore/             shared types and protocols; every other package depends only on this
  HFVoice/            ElevenLabs conversation, agent definition and setup
  HFHands/            real pointer and keyboard, and the 13 quick tools
  HFEyes/             screenshots, and read-only accessibility lookups (names the control)
  HFWake/             on-device wake phrase listener and the sleep and wake cycle (hf-wake tool)
  HFScreenAgent/      Claude's look, decide, check, act loop
  HFTasks/            the task runner: runs one goal in the background, asks questions
  HFDecisions/        Jev client, the three classifiers, safety gate, stop watcher
  HFMemory/           SQLite memory, learning, recipes, memory voice tools
  HFIntegration/      tests that run real packages against each other
  HFAgentCLI/         hf-agent, runs the screen agent from a terminal
Fixtures/             golden examples, recipes and tool definitions shared by tests
docs/                 one document per part, plus prompts, spikes and Clicky notes
scripts/              build_app.sh, run_app.sh, live_lock.sh, render_app_icon.swift
third_party/clicky/   Clicky's licence and a file-by-file notice
project.yml           XcodeGen spec for the app
```

Where to read first: `docs/ARCHITECTURE.md` (the contracts between packages), `DECISIONS.md` (every significant choice and why), then the document for whichever part you care about: `docs/APP.md`, `docs/SCREEN_AGENT.md`, `docs/TASKS.md`, `docs/MEMORY.md`, `docs/TOOLS.md`, `docs/spikes/jev.md`, `docs/spikes/elevenlabs.md`, `docs/spikes/screen_eyes.md`. `BUILD_PLAN.md`, `PITCH.md`, `RESEARCH.md` and `CHALLENGE.md` are the planning documents; where `BUILD_PLAN.md` disagrees with later documents, the later ones are right.

## Known limits

- **Speed.** Looking and clicking is slower than calling an app directly. A multi-step task takes about two to three seconds per model turn plus the time to act: on the real Mac, typing a line into TextEdit took 16 to 38 seconds depending on the model, and the WhatsApp draft took 17.0 seconds. Opening an app through Spotlight takes 0.9 to 1.2 seconds. This is deliberate: the user can see what is happening and stop it.
- **Other voices.** Voice processing removes echo, not other people. While a conversation is open, bystanders have been transcribed as the user, and a bystander saying "stop" could cancel a task. The wake phrase narrows that window but does not check who is speaking: anyone who says it wakes the app. The protection is the spoken yes that every risky action needs.
- **The wake phrase is untested with a real voice.** All measurements use synthetic voices fed to Apple's recogniser as files. Accent matters a lot (see `WAKE_LANGUAGE`), and slow, quiet or atypical speech has not been measured. The orange microphone light is on while it sleeps, and AirPods used as the input switch to their lower-quality mode.
- **Words after a pause during waking can be lost.** If you say the phrase, pause, and keep talking while the conversation is opening, those words reach nobody. Words in the same breath are kept.
- **Tested on few tasks.** The screen agent is general by design but tuned and tested on a few tasks. Runs are single samples, not statistics.
- **One display.** Screenshots are of the main display.
- **Updaters in ordinary windows.** An update sheet drawn inside an ordinary app's own window (a Sparkle "Install Update" sheet) is not recognised as protected; only the gate's word rules ("install", "update") cover it.
- **Spoken-run checks are outstanding.** Slow or paused speech, interrupting the agent, and a spoken run through the built app have not been done yet.
- **Mac only.** No Windows, no offline mode.
- **Certificate changes.** If the signing certificate is replaced by one with a different name, macOS asks for the permissions again.

## Credits

- **Clicky** by Farza (https://github.com/farzaa/clicky, MIT licence, copyright 2026 Farza), cloned on 5 November 2026 at commit `e71105ce091d71dff4d89cf5d8d37ea1df460961`. Taken and adapted: the menu bar app entry point; the full-screen transparent click-through overlay window; the companion that follows the pointer with a spring; the waveform and spinner; pointer polling; the coordinate conversions; the design-token structure; the menu bar status item and panel; and the permission checks. Each adapted file starts with a comment naming the Clicky file it came from. The full list is in `third_party/clicky/NOTICE.md` and the licence is in `third_party/clicky/LICENSE`. **Not taken:** Clicky's voice pipeline, its Claude and OpenAI clients, its element detector, the Cloudflare proxy, analytics, the updater, the login item, its name, icon, branding, music and copy. The colours, icon, wording, behaviour and everything under `Packages/` are ours. Clicky shows you where to click and needs a key held down; this app does the clicking and has no key to press.
- **ElevenLabs** (voice and conversation, Swift SDK 3.4.0), **Anthropic** (Claude and its computer-use toolset), and **TypeSafe's Jev** through **OpenRouter** (fast decisions).
- `legacy_python/` holds an early Python prototype kept only as read-only reference. It is not part of the product and is not run.
