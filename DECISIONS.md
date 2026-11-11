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

## 6 Nov 2026: a stronger model and a rewritten prompt for the voice agent

**The user's complaint.** "It has to be smarter and not just tool call, or shouldn't seem like that."

**How it was decided.** A set of 37 typed test conversations (`Packages/HFVoiceEval`), each checked for the right action, honest wording and no machine words. One run per row:

| Setup | Passed | Time to act |
|-------|--------|-------------|
| Old prompt, Haiku 5.5 | 23 of 37 | 0.71 s |
| New prompt, Haiku 5.5 | 29 of 37 | 0.68 s |
| New prompt, Sonnet 5.5, no reasoning | 33 of 37 | 1.44 s |
| New prompt, Haiku 5.5, low reasoning | 34 of 37 | 0.79 s |
| New prompt, Sonnet 5.5, low reasoning | 36 of 37 | 0.87 s |

**What was chosen.** Sonnet 5.5 with low reasoning, the rewritten prompt, and ElevenLabs' built-in "skip turn" so the agent can stay silent when speech is meant for someone else. It acts about 0.16 seconds later than before and speaks about half a second later.

**Why.** Only this setup never claimed something was done before the result came back, which was the exact fault in the user's first run ("YouTube is open now"). The prompt mattered more than the model: with the old prompt, Sonnet scored lower than Haiku on the first 16 cases.

**What the prompt does differently.** It describes the person and their situation (every word costs them effort, they cannot undo a mistake by hand) rather than listing rules, gives three choices (talk, one quick action, or a task), and says that everything written is spoken aloud.

**Not known.** Each setup ran once, so a difference of one or two cases is noise. The tests are typed, so mishearing and talking over the agent are not covered. Sonnet costs more per conversation than Haiku and that was not measured.

**Also changed.** Task progress is no longer sent as something the agent must answer, because it replied "Nothing to add yet." after every task start. Progress is background information now, and the companion beside the pointer shows it.

## 6 Nov 2026: a yes only counts if the question was heard

**What was found.** Once the voice agent could stay silent for a turn, it could also stay silent on a question the app had sent it to say, such as "Send 'running late' to Amma?". The app counted the question as said. Looking further, nothing in code had ever checked that the user heard a question before their answer was passed to the task: a "yes" said a moment too early, or one the agent made up, would have been consent. The only guard was a sentence in the prompt.

**What was chosen.**
- A question or confirmation counts as said only when the agent's reply contains at least half of its meaningful words. If not, it is sent once more with wording that says it must be spoken. It is never sent a third time in the same conversation.
- An answer reaches a task only after that task's question has been said in the current conversation. Otherwise the answer is held back and the question is asked again. A question from before the app slept must be heard again.
- A result that is not said after two attempts no longer keeps the conversation open; it stays on the panel and is offered at the next wake. A waiting question still keeps the app awake.
- While a task is running or waiting, quick commands that use the keyboard or pointer are refused, so the agent cannot type a question into the focused text box (the backup model did this once in testing).

**Rejected.** Trusting the prompt. A rule about consent has to hold when the model is wrong.

**What it costs.** The word match is rough. A heavily reworded question is repeated once, which is safe but can sound repetitive.

## 6 Nov 2026: a locked Mac

With the screen locked, the app used to say "Spotlight didn't open" or "I can't find the main display". Now every quick command and every task checks first, does nothing, and says "The Mac is locked, so I can't use it until someone unlocks it." The agent never offers to unlock the Mac and never asks for a password. Found by the typed end-to-end run on the night of 5 to 6 Nov, when the screen had locked.

## 7 Nov 2026: the product becomes understanding impaired speech

**What happened.** A Hiya engineer reviewed the idea. Their advice: build around recognising impaired speech (noise cancellation is already solved), keep the Clicky-based Mac agent if it works but don't over-focus on it, and be ready to justify every design choice.

**What was chosen.** The product is now a layer, `HFUnderstand`, that understands slow, slurred or quiet speech before the voice agent acts on it. The Mac agent is where it is shown. The layer records each turn on the Mac, hears it with three recognisers (ElevenLabs Scribe with personal keyterms, Gemini shown a few of the person's own clips, Apple on-device), lets Claude pick the most likely meaning from context, decides in code whether to act or ask a short yes/no question, and learns from every confirmed or corrected turn. Plan and reasons: `docs/SPEECH_PLAN.md`.

**Why it fits.** The people who cannot use their hands (ALS, cerebral palsy, MS, Parkinson's, stroke) very often have dysarthria too. Every voice agent, ours included, fails them first.

**The big change.** The app now listens for itself instead of letting ElevenLabs hear the user, because ElevenLabs' agent answers its own raw transcript at once and there is no point on the Mac where a mishearing could be repaired first. The repaired sentence is sent to the agent as the user's turn.

**Rejected.** A web app (the engineer's tip for easy reviewing): the user chose to demonstrate on the Mac app; instead `hf-understand eval` runs from a clean clone with only API keys. Training a model per person: best results in research, but needs hundreds of recordings and days. Telling models the person has dysarthria: research shows it does not help and often hurts.

**What it costs.** Two to four extra seconds on unclear turns, a second AI vendor (Gemini, through OpenRouter), and taking over turn detection and the fast stop from ElevenLabs.

## 8 Nov 2026: a text-only conversation, with the agent's voice played by the app

**What was found.** ElevenLabs' Swift SDK (3.4.0) always switches its own microphone on when a voice conversation connects; it can be muted but not left off. When the agent's voice plays through the SDK's own audio, our echo cancellation cannot remove it from our recording, so the app could hear the agent as the user. Details: `docs/spikes/own_listening.md`.

**What was chosen.** The ElevenLabs conversation runs text only. The repaired sentence goes in as the user's turn; the agent's reply text comes back and is turned into speech with ElevenLabs text-to-speech, played through the same audio engine as our recorder (`TurnRecorder.playAgentAudio`), so the echo canceller knows what to remove.

**Rejected.** A muted voice conversation: simpler, but the echo cannot be cancelled and the SDK grabs the microphone anyway.

**What it costs.** About 0.8 s more before the agent starts speaking (measured: sound 1.63 s after sending, against about 1.36 s before), which streaming text-to-speech should mostly win back. We also take over cutting the agent off when the person speaks.

## 9 Nov 2026: the repair step uses Haiku 5.5, and a model alone never causes an action

**What was chosen.** Claude Haiku 5.5 picks the most likely meaning from the three transcripts. Measured on the real repair request, 7 calls each: Haiku 1.3 to 1.7 s, Sonnet 5.5 2.2 to 4.1 s. Both read the test cases correctly, including one where a screen label tried to give orders. Sonnet's slower calls would overrun the 3-second repair limit; Haiku says "medium" a little more often, which only costs one extra yes/no question.

**How the answer is requested.** Structured outputs (`output_config.format`), not a forced tool call, because the API rejects a forced tool choice on Sonnet 5.5 and we wanted one code path for both.

**The rule that matters.** A "high" reading from Claude acts only when the recognisers agree on the same words, or a phrasebook entry confirmed at least twice matches. Claude alone never makes the app act; at most it shapes the question. A mishearing learned once is asked about once more, then acted on from the next time.

## 9 Nov 2026: the demo moves to a website; the Mac app is parked

**What the user asked.** Focus on the speech model, leave the Clicky-based Mac app for now, and run it on a website that shows the pipeline working, such as the live transcript updating and each stage in turn.

**What was chosen.** A website, "Understood" (`web/`): the browser records and shows a live transcript, the server runs the same five stages and streams each step back, and the page draws the turn moving through them. Plan: `docs/WEB_PLAN.md`. TypeScript with React and Vite for the page and Hono for the server, because one language covers both and Hono runs unchanged locally and on Cloudflare.

**What changes in the pipeline.** Apple's on-device recogniser cannot run on a web host, so the third vote is ElevenLabs Scribe realtime, which also gives the live transcript. The decider and phrasebook matching are ported from Swift with the same test cases, so the website decides exactly as the evaluated pipeline does.

**Rejected.** A Swift web server around the existing package (it depends on Apple's recogniser, so it could only run on a Mac). Vercel hosting (it runs on AWS).

**Parked, not deleted.** The Mac app, the own-listening mode in `HFVoice` (its consent gap was closed before parking: a question counts as said only once its audio has played; see `docs/spikes/own_listening.md`) and `TurnRecorder` (a noise-floor bug found on 9 Nov).

## 11 Nov 2026: the website is the whole submission

**What the user asked.** "Scratch the Mac app, the website is our main."

**What was chosen.** Documents only: `README.md`, `WRITEUP.md`, `ai.md` and `.env.example` now describe the website alone. The write-up keeps one sentence of history (started as a Mac app, changed course after the Hiya engineer's feedback), because changing course on feedback is part of the story. The old README, including the Mac app's settings template, moved to `docs/MAC_APP.md`.

**Rejected.** Deleting the Mac app's code. Its folders held uncommitted work from other sessions that would have been lost, and `HFCore` and `HFUnderstand` are still needed for the TORGO evaluation. The code stays; the README names those folders in one line as an earlier prototype, and keeps the Clicky credit because Clicky's code is still in the repo.

## 11 Nov 2026: a Recordings tab to browse and play the TORGO clips

**What the user asked.** "Make a tab to see all the dataset audios in the website itself."

**What was chosen.** A second view, "Recordings" (`#dataset`), listing all 3,897 TORGO clips on this computer with filters (speaker, kind, set-up or test, evaluated only, search), a player per clip, and for the 121 evaluated clips what each recogniser heard, Claude's reading and the decision, beside Scribe alone. Opening it stops the microphone and any example, so a playing clip is not heard as the person's own turn.

**How the licence is respected.** TORGO is free for academic, non-profit use and may not be redistributed. The audio is read from the person's own disk by `web/server/dataset.ts`, which only the local Node server mounts (`dev.ts`); the hosted app has no such route. It answers only requests from this machine (loopback socket and a localhost Host header), serves only clips named in the manifest by id, and refuses any file outside the data folder or not a `.wav`. Nothing is bundled into the page or committed.

**Rejected.** Copying clips into `web/public/` (it would ship them in every build and invite a commit). Serving the folder statically (any path could be read). Sending clips through the live pipeline from this tab (it would put another person's speech into the visitor's own phrasebook; possible later with learning switched off).

## 11 Nov 2026: real recordings in, transcription first; the made-up examples are gone

**What the user asked.** "We don't need mock setups. The pipeline page should work with real audio. Let users choose an audio file from their recordings or upload one. Make the main pipeline page fully functional, with accurate transcription as its primary goal; actions based on the transcript can come later."

**What was chosen.**
- The "Watch an example" replays (made-up text with scripted timings) and the replayed evaluation turns are off the page. Their scripts now live in `web/tests/fixtures/`, where the tests still use them to drive the page code.
- A "Hear a recording" panel: a TORGO clip (picked by speaker, test or set-up, or search, or from the Recordings tab's "Hear it in the pipeline" link), or the visitor's own audio file, decoded and resampled to 16 kHz in the browser (60-second cap, the server's 2 MB limit). The recording plays out loud at its own pace while it streams to Scribe realtime, so the live transcript and the third vote work as for speech.
- A TORGO clip is heard as its speaker: the page sets up that speaker's voice from up to 20 of their own enrolment clips, chosen as the evaluation chose them (prompts said again later first), never from test clips. Their prompts become Scribe's hints, five clips Gemini's examples, and each mishearing a phrasebook entry. A set-up clip heard again is flagged as not a fair test.
- The result is a transcript, scored word by word against what was said with a TypeScript port of the evaluation's `WordErrorRate.swift`, per recogniser and for the whole pipeline. Recordings go through `Conversation.transcribe`: nothing acted on, asked, spoken or learned, and an empty context so one recording cannot steer the next.
- Requests carry `purpose: "transcribe"`. The server then gives the recognisers 15 s instead of 4 and Claude 8 s instead of 3, and leaves the demo phone's contact names out of the hints. Measured on 11 Nov: Gemini with five example clips took between 1.4 and 14 s for the same clip (one provider, Google, either way), and with the time it heard M05's "up" where Scribe and realtime heard "Uh". Spoken turns keep 4 s and 3 s.
- The evaluation table on the page now shows the real TORGO numbers (`web/scripts/exportEval.ts`); it had been showing placeholder numbers marked as fake. Words wrong leads the table.

**Rejected.** Running Scribe realtime faster than real time to save waiting (the realtime API is built for live audio, and hearing the clip play is part of seeing what the pipeline hears). A separate "transcription" server route (the same pipeline with one flag keeps one code path, so the evaluation's numbers still describe it). Learning from recordings into the visitor's own phrasebook (it would teach them someone else's speech).

## 11 Nov 2026: a landing page, and the pipeline as its own workspace page

**What the user asked.** "Work on a better UI for pipeline. Make it a separate page, let the main page be the landing page. Industrial level design and structure, influenced by current modern websites, so it's more organised and not everywhere."

**What was chosen.** Three hash-routed pages under one header (`web/src/router.ts`), so the site is still static files: a landing page (`#/`), the pipeline workspace (`#/pipeline`) and the recordings (`#/recordings`). Old links (`#dataset`, `#hear=<clip>`) still work.
- The landing page tells the story once: what it is, the five stages as a numbered line (they are a sequence), "it asks before it acts", the TORGO results as a words-wrong chart with the full table one click away, privacy, and a way in. Its opening diagram is a real run (M05 saying "up": two recognisers heard "Uh", Gemini heard "up"), drawn as three coloured tracks merging into one line, the transit-line idea the pipeline view already used. That diagram is the one moment of motion, and it is still under reduced motion.
- The pipeline page is a workspace: input on the left (TORGO, your file, or the microphone, with the stage switches folded under it), the scored transcript and the pipeline line in the middle, and an inspector on the right (phrasebook, conversation, phone). On narrow screens the columns stack in that order.
- One typeface (Atkinson Hyperlegible Next, made for low-vision readers) and the existing palette: cool paper, navy ink, the three recogniser colours and signal yellow.

**Rejected.** A router library (three pages do not need one, and hash routes keep hosting static). A dark marketing-style hero (the product's identity is the transit map, which reads best on light paper). Keeping everything on one long page (what the user asked to change).

## 11 Nov 2026: transcription accuracy first, measured on held-out recordings

**What the user asked.** "The current transcription quality is poor. Improve it until the pipeline produces accurate, genuinely useful transcripts. Don't check only with known audios and give fake benchmarks." Focus on transcription; actions later.

**How it was decided.** A harness that runs the website's own pipeline on TORGO test clips the way the page does (`web/scripts/evalTranscription.ts`), with the test clips split once into a dev half (all choices) and a held-out half (run once, at the end). Component bake-offs on dev: 13 speech recognisers, 5 audio language models with and without the speaker's clips, merging strategies, repair prompts. Full record: `docs/TRANSCRIPTION.md`.

**What was chosen, for a recording** (spoken turns to the pretend phone are unchanged):
- Scribe `scribe_v3` with `no_verbatim`, and no hints (hints hurt new sentences).
- Two Gemini listeners shown five of the speaker's clips, in one labelled message with the new clip last: Gemini 3.1 Pro (the Gemini lane) and Gemini 4 Carbon (a new fourth lane). The old chat-turn layout let Gemini answer with an example's text.
- Claude Opus 5.5 merging the transcripts with a transcription prompt: it knows Scribe and the live transcript are one engine, and uses the speaker's known phrases only when a transcript nearly matches one.
- `scribe_v3_live` for the live transcript.

**Result (held-out, 110 clips):** words wrong 42.4% → 18.7%; speakers with dysarthria 55.7% → 24.4%; every word right 43% → 64%.

**Rejected after measuring:** giving Claude the recording's length; snapping Claude's text to the nearest transcript; ten examples instead of five (no gain); an audio "re-listen" stage (within noise, 4 s slower); Gemini 4 Argon (invents long text for single words); Sonnet and Haiku for the merge (more errors than Opus); OpenAI, Deepgram, AssemblyAI and other recognisers as the main voice (Scribe v3 was best alone; they did not add enough to the merge with the Gemini pair).

**The cost.** A recording takes about 6 to 15 seconds after it plays and costs more (two large audio models with example clips, and Opus). Accepted because the transcript is the point; spoken turns keep the fast path.
