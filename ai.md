# How I used AI

I used AI heavily, in two ways: as the coding agent that built most of the code, and as parts of the product itself. This file says which tools did what, how the work was organised, what I decided myself, what the AI got wrong, and how I can vouch for the result.

Where a sentence below is marked **[CHECK]**, it is something I must confirm in my own words before submitting.

## The tools

**Claude Code, as the coding agent.** One lead session planned the work, wrote the contracts between modules, ran the whole test suite, reviewed and integrated what the others produced. The rules it followed are in `CLAUDE.md`. Subagents did the implementation, one Swift package each. The project instructions tell the lead to launch them as Opus 5.5 at high effort. **[CHECK: which model the lead session itself ran on, and whether every subagent used Opus 5.5.]** I did not type most of the Swift by hand **[CHECK: confirm this is fair]**.

**Claude inside the product.** The screen agent calls Claude (`claude-sonnet-5-5` by default, set by `TASK_MODEL`) through the Anthropic Messages API with its computer-use toolset. It looks at a screenshot and chooses one action. A smaller model (`claude-haiku-5-5`, set by `SMALL_MODEL`) learns from finished tasks, for example which Priya I meant. The ElevenLabs agent that talks to the user also runs on `claude-haiku-5-5`, because it was the fastest model that passed all 78 behaviour checks in the voice spike (`docs/spikes/elevenlabs.md`).

**ElevenLabs.** It provides the voice: speech recognition, the conversation, interruption handling, patient turn-taking for slow speakers, and the speech you hear. The agent is defined in code (`Packages/HFVoice`), not in the dashboard, so anyone who clones the repo gets the same agent.

**Jev, through OpenRouter.** Jev is TypeSafe's classifier. It is not a chat model. It answers three kinds of question quickly, with a label and a confidence: is this sentence a cancel, does this action need a spoken yes, and was this reply a yes, a no or unclear. I measured it on this Mac: a median of about 200 to 220 ms per call, and about $0.00002 per call (`docs/spikes/jev.md`). Keyword rules sit behind it, and the safety check asks whenever it is unsure.

**Clicky's code.** Not an AI tool, but a large starting point, so it belongs here. The app shell is adapted from Clicky, an MIT-licensed open-source Mac app by Farza. `third_party/clicky/NOTICE.md` lists every file.

## How the work was organised

- **One package per agent.** The logic lives in separate Swift packages (`HFVoice`, `HFHands`, `HFEyes`, `HFScreenAgent`, `HFTasks`, `HFDecisions`, `HFMemory`). Each owns its own files, and two agents never edited the same file at once.
- **A shared core so packages cannot depend on each other.** `HFCore` holds the shared types and protocols. Every other package depends only on it, so each builds and tests alone and several agents could work in parallel. The contracts are written down in `docs/ARCHITECTURE.md` before the work started.
- **A separate agent for testing and review.** One agent's only job was to run the packages against each other and review them (`Packages/HFIntegration`). Work was reviewed by an agent that had not written it.
- **A lock so only one agent drove the real Mac.** There is one pointer, one keyboard and one front window. `scripts/live_lock.sh` makes a run take the lock before anything moves the pointer or presses keys, and release it straight after. Without it, two agents fight over the front window.
- **Spikes before building.** Three agents first ran the risky libraries for real (ElevenLabs, macos-harness, browser-use), because the plan's assumptions about them came from search results. Later, each package's author measured their part on this Mac and wrote the numbers into its document (`docs/spikes/`, `docs/SCREEN_AGENT.md`).

## What I decided myself

These are my instructions, quoted from `DECISIONS.md`, and the choices that followed from them.

1. **Act like a person at the screen.** I said: "It should be controlling the laptop like a user, not opening specific apps in its own way or programmatically. It's basically just the laptop user. So it clicks things on the screen. Kind of like Hey Clicky." That threw away two working approaches: browser-use (which drives a separate browser through page code) and macos-harness (which works in the background without moving the pointer). It made the agent slower, and I accepted that: a user who cannot touch the keyboard needs to see what the agent is doing in order to trust it and stop it.
2. **Make it a native Swift app, at Clicky's standard, on Clicky's code.** I said: "Let's make it a native Swift app." "I want it to be Clicky-level quality." "You can use the Clicky codebase as the base and take the code from it." A user without hands cannot start a program from a terminal, and macOS gives a real app its own permissions. The Python prototype was retired a few hours in; its designs survived as written specifications.
3. **Memory.** I asked for the agent to remember and learn my preferences. The design rules are mine to explain: something I state is trusted at once, something inferred is trusted only after it is seen twice, I can list, correct and delete everything by voice, secrets are never stored, and nothing remembered can make a risky action skip its spoken confirmation.
4. **A wake phrase instead of an always-open microphone.** On 6 November I said: "Let's not have an always-on mic. Let there be a key word, so that way we don't use up all the minutes." Earlier tests also showed that an open conversation sent bystanders' words to the cloud. The details are in `Packages/HFCore/Sources/HFCore/Wake.swift`. This was my decision; the feature is still being finished (see the README's Status section).
5. **Which models do which work.** Opus 5.5 for the hard, careful work of building; Sonnet 5.5 as the screen agent's default (it needed fewer steps than Haiku and finished sooner, though it misread one page in testing); Haiku 5.5 for fast, small jobs. **[CHECK: the Sonnet default is recorded in `DECISIONS.md` as chosen by the lead after measuring. Confirm this is a choice I agreed with, not only one I was told about.]**
6. **How the agents report and when they ask me.** Plain-language reports with examples, no unnecessary questions, and escalation to me only for credentials, macOS permissions, anything that reaches a real person, and pushing or submitting.

## What the AI got wrong, and how it was caught

I am listing these because they show where the process needs a person, and because I can explain each one.

**A test installed software nobody asked for.** On 5 November a test pressed Return to open an app through Spotlight at the moment Oracle's Java updater popped up by itself. The key reached the updater's default button and an update was installed. It showed that an assistant pressing keys for someone who cannot reach the keyboard must never agree to an install, approve downloaded software or type into a password prompt. The result is `ProtectedSurfaces` in `HFCore`: system password and Touch ID prompts, installers, software updaters, Gatekeeper warnings and password managers are windows the agent never operates, whatever it was asked. The quick tools, the screen agent and the safety gate all use the same list. It has a known gap, stated in the file: an update sheet drawn inside an ordinary app's own window is only covered by the gate's word rules.

**Every package's tests passed, and the safety check could still be bypassed.** The agent that tested the packages together fed real output from the eyes and the screen agent into the safety gate, and they did not agree on wording. The screen agent described a Return press as "..., which may send or submit it", but the gate's rule only recognised "..., which may send it". The eyes described an icon-only button as `button with identifier "ChatBar_SendButton"`, with no gap before "Send", and the word match missed it. The eyes said "an unlabelled link"; the gate only knew "unlabelled control". Each package had tested its own wording, so each passed. Only a test across packages could see it. I chose not to agree a common wording, because that would have broken the next time anyone reworded a phrase. Instead the contract changed: sentences were removed, and there is now one type, `ScreenAction`, with the kind of action, the key and the control (role, label, identifier, app, window) as fields. The gate reads fields. The one sentence form is built in one place, for the classifier and the log only. The lesson: unit tests proved each piece did what its author meant, but not that the pieces meant the same thing.

**Early microphone tests picked up bystanders.** In the voice spike, people talking in the room were transcribed as the user ("You wanna start a new Zoom?"). They held the screen agent, they could interrupt the agent, and a bystander saying "stop" would have cancelled a task. Voice processing removes echo, not other voices. This is one of the reasons for the wake phrase, and the README lists it as a known limit until the wake phrase has been checked against it.

**The plan's assumptions came from search results, and several were wrong.** `macos-harness` was assumed to be an in-process library with six primitives; it is a command-line tool with eleven commands. Jev was assumed to be a direct TypeSafe API with its own key; my access is through OpenRouter. Clicky's request to Claude uses a computer-use tool version that the 5.5 models reject with a 400 error, so only its idea could be reused. The plan was corrected (`BUILD_PLAN.md` section 0) and the rule became: run the library for real before relying on it.

**An agent misreported a model's answer.** A first report said Sonnet got a page heading wrong. A direct fetch of example.com showed the page has no heading element at all, so it was a bad test, not a bad model. The correction is written in `docs/SCREEN_AGENT.md`.

**A race on the real Mac.** Command+Space, the typed name and Return, sent back to back, made Spotlight open Calculator instead of the app, because Return arrived before Spotlight had updated its top hit. Mocks could never have shown this. The agent now pauses 0.2 seconds before each action that follows another in the same turn.

**Build trouble that looked like code trouble.** The build script once reported a false failure because SwiftPM's cached plan missed a file newly added to `HFCore` (it now retries from an empty folder). A stale compiled module crashed the Swift compiler when the linked set of packages changed (the script now clears old build products). A note in Clicky said not to run `xcodebuild` from the terminal; checking with `codesign` showed the real cause is an ad hoc signature, which changes on every build, not the terminal. We sign with one stable certificate.

**A small design correction.** While a confirmation was open, "no, don't" was first treated as a cancel, which would have thrown away work a hands-free user cannot redo. It is now an answer, the task survives, and the user can follow with a correction. Only phrases that clearly end the whole thing cancel it.

## How I can vouch for the code

- **The contracts.** `docs/ARCHITECTURE.md` says what each package owes the others, in plain words, with the safety contract written out in full.
- **The decision log.** `DECISIONS.md` records each choice, what was rejected and why, so I can explain the reasons and not only the result.
- **The tests.** Each package has unit tests that fake the network and the Mac. `HFIntegration` runs packages against each other. Live tests (`HF_LIVE=1`) run against the real Mac and real APIs, one at a time under the lock. The risk classifier was measured on a labelled set: in the final run it missed no risky action, and asked needlessly on about 7% of safe ones (`docs/spikes/jev.md`).
- **Documents written to be explained.** Each part has its own document with measured numbers marked as measured and designs marked as designs: `docs/APP.md`, `docs/SCREEN_AGENT.md`, `docs/TASKS.md`, `docs/MEMORY.md`, `docs/TOOLS.md`, `docs/spikes/`.
- **Small modules.** The project rules ask for a small clear module over a clever one.

What is not yet verified, and I will not claim otherwise: a full spoken run through the built app, the app's macOS permissions, and the Google Meet task.

**[CHECK: add here, in my own words, what I personally read, ran and verified before submitting, and what I could explain without notes in the video review.]**
