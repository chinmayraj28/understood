# Hands-Free Laptop Agent: working instructions

This repo is the Hiya Voice AI Challenge submission (Accessibility track). A person who cannot use their hands controls their Mac by speaking goals. **Deadline: Wed 11 Nov 2026, 11:59pm GMT. Target: submitted by 6pm.**

**The core rule of the product: the agent acts like a person at the laptop.** It looks at the screen, moves the real pointer, clicks, scrolls and presses keys, visibly, in the user's own apps and their own Chrome. It does not script apps behind the scenes (no AppleScript or `open -a` to make things happen, no separate automation browser, no DOM control, no background accessibility actions). Reading state without acting is fine. The model is the Mac companion Clicky: it sits beside the cursor, sees the screen and talks. See `docs/ARCHITECTURE.md`.

**It is a native Swift macOS app, built on Clicky's open-source code** (github.com/farzaa/clicky, MIT). The user chose this on 5 Nov and wants Clicky's level of polish. The app shell (menu bar panel, full-screen overlay with the companion beside the pointer, design system, permission flow) is adapted from Clicky, with credit kept in `third_party/clicky/`. Our logic lives in Swift packages under `Packages/`. **There is no Python in the product.** An early Python prototype sits in `legacy_python/` as read-only reference with no environment; never run it, never add to it, and never start browser-use, Playwright, macos-harness or a second Chrome.

These instructions apply to every Claude Code session and every subagent working here. Follow them without being asked again.

## Read first

| File | What it is |
|------|------------|
| `CHALLENGE.md` | The brief, the deliverables and the submission checklist |
| `BUILD_PLAN.md` | The design: three tiers, flows, tool specs, repo layout, edge cases, schedule |
| `PITCH.md` | User story, why voice, likely questions |
| `RESEARCH.md` | Prior art and lessons |
| `DECISIONS.md` | Running log of choices made and why |
| `docs/ARCHITECTURE.md` | Product rules, the Swift package layout, conventions and module contracts. **Read before writing code.** |
| `Packages/HFCore/Sources/HFCore/` | The shared Swift types and protocols every package builds on. Short and commented |
| `docs/APP.md`, `docs/research/clicky.md` | How the app is put together, and what was taken from Clicky and why |
| `docs/spikes/*.md` | What was found by running each library for real on this Mac |

`BUILD_PLAN.md` is the agreed plan. Where it disagrees with "Verified facts" below, the verified facts win; fix the plan when you notice the gap.

## 1. Own the outcome

- The user gives the goal. You deliver it: build, test, debug and refine until it meets the definition of done in section 8.
- Do not ask the user to pick between reasonable technical options. Pick the one that best serves the goal, write one line in `DECISIONS.md`, and continue.
- Do not stop on small ambiguities. Read the code and the docs above, then decide.
- When something fails, find the root cause, fix it, and rerun the tests that cover it. Do not paper over a failure or skip a failing test.
- If an outside dependency blocks one piece, finish everything else and report the blocker clearly: what is blocked, why, and exactly what unblocks it.
- This project's autonomy rule replaces the "get agreement before writing code" rule in the user's global instructions. Still plan before large changes; just do not wait for sign-off.

**Escalate to the user only for:**
- a credential or macOS permission that only they can provide,
- anything that reaches a real person or cannot be undone outside this repo (see section 6),
- pushing to GitHub or submitting to Hiya,
- cutting something the plan says is never cut (stop watcher, safety gate, hands-free activation).

## 2. Agents

- Use subagents for implementation, architecture, review, testing and debugging. Launch them with the Agent tool. **Match the model to the task** (the user's instruction, 6 Nov):
  - `model: "opus"` (Opus 5.5) with `effort: "high"` for the harder work: design, anything touching safety, new packages, cross-package integration, debugging, and reviews.
  - `model: "sonnet"` (Sonnet 5.5) for lighter work: documentation, write-ups, mechanical edits across files, renames, and tidying.
- Keep the number of agents running at once small (three or four). Eight at a time used up the account's five-hour limit twice on 5 Nov and stalled everything for hours.
- Run independent workstreams in parallel, in one message. The split is one Swift package per agent, listed in `docs/ARCHITECTURE.md`: `HFVoice`, `HFHands`, `HFEyes`, `HFScreenAgent`, `HFTasks`, `HFDecisions`, `HFMemory`, `HFWake`, plus the app itself. Packages depend only on `HFCore`, so each builds and tests on its own.
- Every agent brief must contain:
  1. **Ownership:** the exact files or folder it owns. Two agents never edit the same file at once.
  2. **Objective:** what must work when it finishes.
  3. **Context:** the relevant sections of `BUILD_PLAN.md`, the verified facts below, and the interfaces it must match.
  4. **Acceptance criteria:** the commands that must pass and the behaviour that must be seen.
- Agree shared interfaces (function names, return shapes, task states) before parallel work starts, and write them where every agent can read them.
- After a piece of work lands, have a different agent review it for correctness, safety and regressions. Fix what the review finds, then rerun the tests.
- The lead session integrates, runs the full test suite, and is responsible for the final result. An agent's report is a claim until the lead has checked it.

## 3. Build and test every feature end to end

For each feature:

1. Read the existing code and conventions before changing anything.
2. Write down the intended behaviour and what it depends on.
3. Implement it across every layer it touches (voice agent config, quick tool, screen agent, task runner, safety gate, memory).
4. Write and run unit tests (`cd Packages/<Name> && swift test`, with the network and the Mac faked behind protocols).
5. Run it for real on this Mac: `HF_LIVE=1 swift test` in the package, the package's small command-line tool, then the built app through a live ElevenLabs conversation.
6. Check edge cases and error states from `BUILD_PLAN.md` section 7.
7. Fix what breaks and repeat from step 4.
8. Review for regressions, safety gaps and leftover debug code.

Do not rely only on mocks when the real thing can be tested. The real Mac, real Chrome, real WhatsApp and the real ElevenLabs agent are all available.

**Testing voice without a human speaking:** `VoiceSession.sendText(_:)` injects a user turn as text, so full flows can be tested without a microphone. Use it for automated end-to-end runs. Microphone and speaker behaviour (interruption, echo, slow speech) still needs a real spoken run before a feature is called done.

## 4. Browser and Chrome extension

- Use the Claude in Chrome tools for the ElevenLabs dashboard, OpenRouter, Google Calendar and Meet when checking that a task really produced the right result.
- Web tasks in the product itself are done in the user's own Chrome window by the screen agent, looking and clicking like a person. There is no automation browser.
- After a web task, verify the result in the page (the event exists, the draft says the right thing), not only from the agent's own summary.

## 5. Credentials and secrets

- All secrets live in `.env` at the repo root. It is gitignored and mode 600. `.env.example` lists every variable with placeholders only.
- Read keys only through `Settings.load()` in `HFCore`. Never hardcode a key, print it, log it, put it in a test fixture, or commit it.
- Do not ask the user for a credential that is already in `.env`. Check first.
- Before any commit, run `git diff --cached` and confirm no secret is staged.
- Required: `ELEVENLABS_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY` (for Jev). `ELEVENLABS_AGENT_ID` is written by our own setup script.
- macOS permissions (Microphone, Accessibility, Screen Recording) belong to **Handsfree.app** once it is built and signed, and to **Orca** (the terminal's host app) for command-line tools and tests. Only the user can grant them. Check at startup and say which one is missing. Never try to change system settings.

## 6. Safety when testing on a real laptop

This product sends messages and invites. Tests run on the user's real accounts.

- Send WhatsApp messages only to `TEST_WHATSAPP_CONTACT`. Send calendar invites and emails only to `TEST_INVITE_EMAIL`. If either is empty, test up to the draft and stop.
- Never test payments, purchases, deletions of real data, or posts to public sites.
- The product itself must never send, pay, delete, submit or invite without a spoken yes. A test that shows it can is a release blocker.
- When the safety gate is unsure, or Jev is down, it asks. Never change this to "allow".
- Return sends in chat apps. `Hands.typeText` refuses a newline unless told otherwise, and the screen agent asks the safety gate before every click and every Return key press, using the name of the control under the pointer.
- Live tests move the user's real pointer and press real keys. Keep them short, type only into a scratch document, restore what you change, and never leave a key or button held down.
- **One live run at a time.** There is one pointer, one keyboard and one front window. Before any command that moves the pointer, presses keys, brings an app to the front or plays sound, run `scripts/live_lock.sh acquire <your-name>`, and run `scripts/live_lock.sh release <your-name>` as soon as it finishes. Read-only checks and tests with fake hands need no lock. Never drive the GUI from a package that has no reason to (use the eyes package's tools to read a control), and never with `osascript` or Python.

## 7. Verified facts (checked against current docs, 5 Nov 2026)

| Thing | Fact |
|-------|------|
| ElevenLabs (Python SDK, superseded) | The app now uses the ElevenLabs **Swift** SDK; see `docs/spikes/elevenlabs.md` for what is verified there. Platform facts below still hold. Python: `elevenlabs` 2.76.0. `Conversation(client, agent_id, requires_auth, audio_interface=DefaultAudioInterface(), client_tools=ClientTools(), callback_user_transcript=..., callback_agent_response=...)`. `ClientTools.register(name, fn)`. `AsyncConversation` is the async twin. The conversation API is marked beta. |
| Pushing into a live conversation | `send_contextual_update(text)` adds background context and does **not** make the agent speak. `send_user_message(text)` sends a user turn. Mid-task questions need the second, or a polling tool. Test before relying on it. |
| Patient turn-taking | Agent config `conversation_config.turn.turn_eagerness = "patient"`; `turn_timeout` defaults to 7 seconds. |
| Client tool settings | `interruption_mode` (default `allow`), `response_timeout_secs` (5 to 300, default 20), `pre_tool_speech`, `tool_call_sound`. |
| browser-use | **Not used.** Dropped on 5 Nov when the user asked for person-like control: it drives a separate browser through the page's code rather than the screen. Notes in `docs/spikes/browser_use.md`. |
| macos-harness | **Not used to act.** It is a command-line tool that works in the background without moving the pointer, the opposite of what is wanted. Notes in `docs/spikes/macos_harness.md`. |
| Screen control | The agent's hands are `HFHands.SystemHands` (Quartz CGEvent: the pointer visibly glides, keys are real key events, and a stop flag freezes an action mid-flight). Its eyes are `HFEyes.ScreenEyes` (screenshots, with exact mapping between image pixels and screen points on a Retina display). `HFEyes.AccessibilityLabels` reads, and never acts on, the accessibility tree to name what is under the pointer for the safety gate. Posting events needs the Accessibility permission and screenshots need Screen Recording, both for the host app. |
| Jev | TypeSafe's classifier, reached through **OpenRouter**: `POST https://openrouter.ai/api/v1/systemone` with `Authorization: Bearer $OPENROUTER_API_KEY` and body `{"model": "jev-latest", "state": ..., "questions": {...}}`. Question types: `noul` (returns the probability of yes), `choice` (returns the label, per-label probabilities and a confidence) and `score`. Several questions in one request are answered together. **Run for real on 5 Nov:** 200 to 320 ms per call from this Mac, about $0.00002 per call, and correct on "stop" (cancel), "stop the music" (command) and "Click Send" (needs confirmation). `jev-latest` currently resolves to `typesafe/jev-1.14`. It is not a chat model: `/chat/completions` rejects it. Keyword fallbacks must still always work. |
| Anthropic SDK | Available models include `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-5-5` and `claude-fable-5-1`. The screen agent uses Claude's computer-use tool; the exact tool version and settings are recorded in `docs/SCREEN_AGENT.md`. |
| This Mac | macOS 26.3.1, Apple Silicon, Xcode 26.6, Swift 6.3.3, XcodeGen, and Apple Development signing identities in the keychain. Chrome (profiles `Default`, `Profile 1`), WhatsApp and Spotify are installed. `portaudio` is installed through Homebrew (the microphone interface needs it; a clean machine needs `brew install portaudio` before `uv sync`). |
| Keys | All three keys are in `.env` and verified working. The ElevenLabs and OpenRouter keys are both named `hiya-voice-laptop` in their dashboards. The OpenRouter key has a $50 cap and expires on 5 Dec 2026. |

Use Context7 for current ElevenLabs, Anthropic and Jev docs before using a method not listed here. Add what you verify to this table.

## 8. Definition of done

A feature is done only when all of these are true:

- [ ] It works end to end on the real Mac, through the real voice agent.
- [ ] Its unit tests pass, and the whole suite still passes.
- [ ] The real flow has been run and the result checked (in the app or page, not just the tool's return value).
- [ ] Bugs found along the way are fixed, not noted and left.
- [ ] A second agent has reviewed it.
- [ ] `README.md` and the plan are updated if behaviour or setup changed.
- [ ] `ai.md` and `DECISIONS.md` are updated (see section 9).

The whole submission is done when the `CHALLENGE.md` checklist is complete and the prototype starts from a clean clone by following `README.md` alone.

## 9. Things the user must be able to explain

Hiya grades understanding as well as the result, and requires `ai.md`.

- Keep code readable and modest in size. Prefer a small clear module to a clever one.
- Log each real decision in `DECISIONS.md`: what was chosen, what was rejected, and why, in plain words.
- Keep `ai.md` current: which AI tools were used, for what, and what the user decided or checked themselves.
- When reporting to the user, use plain language and full sentences, with a concrete example of what changed.

## 10. Repo rules

- Never commit `.env`, `graphify-out/`, `legacy_python/`, build output, logs or recordings.
- Keep `third_party/clicky/LICENSE` and `NOTICE.md` accurate: every file adapted from Clicky is listed and carries a header comment saying so. Report the use of Clicky's code honestly in `README.md`, `ai.md` and the write-up.
- Commit messages: no `Co-Authored-By` trailer and no "Generated with Claude Code" footer.
- Commit locally at working checkpoints. Do not push or create a GitHub repo until the user says so.
- Do not use or recommend Amazon or AWS services.
- Write task specifications in LeetCode style: description, examples, constraints.

<!-- claude-reflect: learned rules (saved from the band; edit freely) -->
## Learned rules
- Control the laptop like a human user: operate it by seeing the screen and clicking, not by scripting apps programmatically.
<!-- end claude-reflect -->
