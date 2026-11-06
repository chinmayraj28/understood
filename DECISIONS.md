# Decisions

A running log of the choices made while building, in plain words: what was chosen, what was rejected, and why. Newest at the bottom.

## 5 Nov 2026

**The repo root is the project.** Code lives in `src/voicelaptop/`, not in a nested `voice-laptop/` folder as `BUILD_PLAN.md` section 6 drew it. One less level to explain, and the planning documents sit beside the code they describe.

**Jev is called through OpenRouter's System One endpoint, with plain `httpx`.** The plan assumed a direct TypeSafe API and a `JEV_API_KEY`. The user's access is through OpenRouter, where the endpoint is `POST /api/v1/systemone`. A hand-written client of a few dozen lines is easier to explain than a second SDK, and it keeps the timeout and fallback behaviour in our own code. Rejected: the `typesafe-sdk` and `openrouter` packages.

**The native Mac executor is our own loop around the `macos-harness` command-line tool.** The plan assumed the harness was an in-process library with six primitives. It is a command-line tool with eleven commands that reads a window as numbered text. So Claude reads that text, picks an element number, and we run the matching command. This matches the research lesson "pick element IDs, not pixels".

**One source of truth for voice tools.** Each tool is a `ToolSpec` (name, description, JSON schema, handler). The same list registers the local handlers and generates the ElevenLabs agent's tool definitions, so the two sides cannot drift apart.

**The ElevenLabs agent is defined in code, not in the dashboard.** `scripts/setup_agent.py` creates or updates it from `voice/agent_config.py`. Anyone cloning the repo gets the same agent, and the prompt is reviewable.

**Memory was added to scope.** The user asked for the agent to remember and learn preferences. It is stored locally in SQLite, outside the repo. Design rules: something the user states explicitly is trusted at once; something inferred is only trusted after it is seen twice; the user can list, correct and delete everything by voice; secrets are never stored; and nothing remembered can make a risky action skip its spoken confirmation. Rejected: embeddings and a vector store, which are more than tens of facts need and harder to explain.

**API keys were created with limits.** The ElevenLabs key is restricted to Agents, text-to-speech, speech-to-text and reading voices. The OpenRouter key has a $50 cap and a 30-day expiry, matching the key the user had made for Jev.

**`anthropic` stays on 1.x.** browser-use 0.13.14 requires a version below 2.0.

**Work is split by folder between parallel agents**, each with its own files, against the contracts in `docs/ARCHITECTURE.md`. Three of them first ran the risky libraries for real (ElevenLabs, macos-harness, browser-use) because the plan's assumptions about them came from search results.

## 5 Nov 2026, later: the agent acts like a person at the laptop

**The user's instruction:** "It should be controlling the laptop like a user, not opening specific apps in its own way or programmatically. It's basically just the laptop user. So it clicks things on the screen. Kind of like Hey Clicky."

**What changed.** The agent now only uses what a person has: it looks at the screen, moves the real pointer, clicks, scrolls and presses keys. The user watches it work in their own apps.

- **browser-use was dropped.** It drives a separate browser through the page's code. That is faster and more reliable on websites, but it is not "the laptop user", and it could not use the Chrome the user already has open and signed in.
- **macos-harness was dropped as the way to act.** Its selling point is that it works in the background without moving the pointer, which is the opposite of what is wanted.
- **Scripted shortcuts became recipes.** There is no hidden WhatsApp script. A recipe is a short hint in memory ("open WhatsApp, click the search field, type the name...") that the screen agent treats as advice while it does every step visibly.
- **One executor.** There is no web-or-native choice any more, so Jev's third job changed to reading the user's reply to a confirmation: yes, no or unclear.
- **Quick tools stayed, done the person's way.** "Open Spotify" is Spotlight: Command+Space, type, Return. Volume is the keyboard's volume keys.

**What it costs, said plainly.** Looking and clicking is slower than calling an app directly: a multi-step task takes several seconds per step, and opening an app takes about a second rather than a few milliseconds. The trade is deliberate. A user who cannot touch the keyboard needs to *see* what the agent is doing in order to trust it and to stop it, and an agent that works on anything visible needs no per-app integration.

**What got stronger.** The safety check now runs in code before every click and every Return key press. It reads the name of the control under the pointer from the accessibility tree (for example: button "Send" in WhatsApp) and asks the gate about that exact action. It no longer depends on the model remembering to ask.

**Stop freezes the hands.** The pointer and keyboard module checks a stop flag between every small movement and every typed character, so "stop" halts a glide or a sentence mid-way.

## 5 Nov 2026, later still: a native Swift app, built on Clicky

**The user's instructions:** "Let's make it a native Swift app." "I want it to be Clicky-level quality." "You can use the Clicky codebase as the base and take the code from it."

**What changed.** The product is now a native Swift macOS app. Its shell is adapted from Clicky, an open-source (MIT) menu bar companion by Farza: the menu bar panel, the full-screen transparent overlay with a buddy beside the pointer, the design system and the permission flow.

**Why this is the right base.**
- A user who cannot use their hands cannot start a program from a terminal. A real app starts at login and has its own permissions under its own name.
- The pointer, keyboard, screenshot and accessibility interfaces are macOS's own, and Swift calls them directly.
- Clicky already solves the hard visual parts well, and its licence and its author's README both invite reuse. Starting from it is how the app can reach that standard in six days.

**How ours differs from Clicky, which is the point of the project.**
- Clicky shows you where to click. Ours clicks, with the real pointer.
- Clicky is push-to-talk: you hold Control+Option. Ours is always listening, because its users cannot press a key.
- Ours adds what a hands-free user needs: tasks that run in the background of a conversation and can ask questions, a stop that freezes the pointer, a safety check on the real button about to be clicked, and memory.

**What was removed from Clicky.** Its push-to-talk and speech-to-text stack, its Cloudflare proxy, its analytics and its auto-updater.

**How the code is organised.** The app target is the shell. The logic is in separate Swift packages (`HFVoice`, `HFHands`, `HFEyes`, `HFScreenAgent`, `HFTasks`, `HFDecisions`, `HFMemory`), each depending only on a small shared package of types and protocols (`HFCore`). Each package builds and tests on its own, which lets several agents work at once and keeps every piece small enough to explain.

**The Python prototype was retired** a few hours in. Its designs carried over as language-neutral specs (`docs/TASKS.md`, `docs/MEMORY.md`, `docs/spikes/jev.md`) and data (`Fixtures/`). The code sits in `legacy_python/` for reference, cannot be run, and is not in the repo's history.

**Credit and honesty.** Clicky's licence and copyright notice are kept in `third_party/clicky/`, each adapted file says so in a header, and the use of Clicky's code is stated in the README, `ai.md` and the write-up.

**Cost.** The reviewer needs a Mac with Xcode to build it. The demo video matters more as a backup than it did.

## 5 Nov 2026, night: the safety gate judges a structured action, not a sentence

**What was found.** The agent that tests the packages together fed the real output of the eyes and the screen agent into the safety gate, and they did not agree on wording. Three examples:

- The screen agent described a Return key press as "..., which may send or submit it". The gate's rule only recognised "..., which may send it", so the rule did not fire.
- The eyes described an icon-only button as `button with identifier "ChatBar_SendButton"`. There is no gap before "Send", so the gate's word match missed it.
- The eyes said "an unlabelled link". The gate only recognised "unlabelled control, element, button or item".

Every package's own tests passed, because each one tested its own wording. Only a test across packages could see it.

**What was chosen.** Sentences were removed from the contract. There is now one type, `ScreenAction`, in the shared core. It carries the kind of action, the key, and the control it lands on as fields: role, label, identifier, app, window. The gate's fixed rules read those fields. The one sentence form is built in one place and is used only for the classifier, the log and the spoken fallback.

**What was rejected.** Agreeing a common wording and fixing the three sets of strings. That would have worked today and broken again the next time anyone reworded a phrase.

**What else came with it.**
- The control is read **at the moment of the click**. On this Mac, the same spot in WhatsApp is "Voice message" before text is typed and "Send" after, so a name read before the pointer arrives cannot be trusted.
- Long text inside a message bubble is left out of what is sent to the classifier, so the words of private messages never leave the laptop for that purpose.
- A control that cannot be identified is "unknown", and unknown is never treated as safe.

**The lesson for the write-up.** Unit tests proved each piece did what its author intended. They could not prove the pieces meant the same thing. The integration tests are what found the real safety hole.

## 5 Nov 2026, night: smaller decisions

- **While a confirmation is open, "no, don't" is an answer, not a stop.** Nothing is sent either way, the task survives, and the user can follow with a correction ("say fifteen minutes"). Only phrases that unmistakably end the whole thing ("stop", "cancel the task") cancel it. Rejected: cancelling the task, which throws away work a hands-free user cannot redo by hand.
- **The agent holds new actions while the user is speaking.** A spoken "stop" is only understood once the sentence is transcribed. The voice SDK reports the moment speech starts, so the screen agent waits rather than clicking again. The wait is bounded so background noise cannot freeze a task.
- **A remembered choice seen once is offered, not assumed.** The second time, the agent asks "Priya Shah, like last time?" instead of the open question. A yes makes it trusted.
- **Only the task runner announces a stop and releases the hands.** Three places were doing it, which would have shown "stopped" three times and could have released the pointer while an old action was still unwinding.
- **Sonnet 5.5 is the default model for the screen agent.** It needed fewer steps than Haiku and finished sooner, though it misread one page in testing. It is a setting, not a fixed choice.

## 6 Nov 2026: a wake phrase instead of an always-open microphone

**The user's instruction:** "Let's not have an always-on mic. Let there be a key word, so that way we don't use up all the minutes."

**What was chosen.** The app sleeps. While asleep it listens, on the Mac itself, for a wake phrase ("Hey Handsfree" by default, set with `WAKE_PHRASE`). When it hears the phrase it opens a conversation with ElevenLabs. After a short silence with no task running, it closes the conversation and goes back to sleep. Anything said in the same breath as the phrase ("Hey Handsfree, open Spotify") is passed to the conversation as its first message, so nothing is lost while it connects.

**Why.**
- **Cost.** ElevenLabs bills by the minute of open conversation, whether or not anyone is speaking.
- **Privacy.** While asleep, no audio leaves the laptop. An earlier test with an always-open conversation picked up people talking in the room and sent their words to the cloud.
- **Other voices.** A bystander's sentence can only be acted on while a conversation is open.

**What stays the same.** It is still hands-free. There is no key to press, because the people this is for cannot press one. A running task keeps the app awake, so "stop" always has a conversation to be heard in, and a task waiting for the user's yes is never put to sleep.

**How the phrase is heard.** With Apple's own speech recognition running on the device. Rejected: a third-party wake-word service, which would add a dependency and another key for the reviewer to obtain.

**What it costs.** A fourth macOS permission (Speech Recognition), and a short delay while the conversation opens after the phrase. Apple's recogniser may do worse on slow, quiet or atypical speech, which many of these users have, so the phrase can be changed to whatever the user can say reliably.

**Always-on is still available** with `WAKE_MODE=always`, for demos and testing.

## 6 Nov 2026: smaller decisions

- **Which model does which work** (the user's instruction): Opus 5.5 agents for the harder tasks (design, safety, new packages, integration, reviews) and Sonnet 5.5 agents for lighter ones (documents, mechanical edits). Fewer agents run at once, because eight at a time used up the account's limit twice and stalled the work for hours.
- **Install, Update and Allow buttons always ask.** A dedicated installer or updater app is refused outright. The same buttons inside an ordinary app's own window (an "Install Update" sheet) were only being held when the classifier happened to be off. They are now held by a fixed rule.

## 6 Nov 2026: the voice agent had none of the app's real tools

**What the user saw.** In the first real spoken run, the agent "kept searching for tools" and could not do anything on the Mac.

**The cause.** ElevenLabs requires a description on every tool setting. Four quick commands (`media_control`, `scroll`, `shortcut`, `pointer`) each had one setting without a description, so ElevenLabs refused the whole update with HTTP 400 every time the app started. The app wrote the error to a log and carried on. The agent kept the single test tool that the live tests had left on it.

**Why the tests did not catch it.** Each package passed its own tests, but no test had ever sent the real tool list to ElevenLabs. The live tests sent only a test tool, which did have descriptions. This is the same kind of fault as the safety-gate wording mismatch on 5 Nov: the pieces were right and the join between them was not.

**What was chosen.**
- Every tool setting gets a description when it is converted for ElevenLabs, at any depth.
- After each update the app reads the agent back and compares the tool names with the ones it built. A mismatch is shown in the panel and blocks waking, instead of being logged and ignored.
- A live test sends all 24 real tools to a separate test agent and reads them back. Tests and command-line tools never touch the user's agent again; they use agents named "Handsfree TEST agent" and "Handsfree EVAL agent".

**Rejected.** Only adding the four missing descriptions. That fixes today's fault and leaves the next rejected update just as silent.
