# Build Plan: Hands-Free Laptop Agent

Written 5 Nov 2026. Deadline 11 Nov, 11:59pm GMT. Builds on [RESEARCH.md](RESEARCH.md); the pitch is in [PITCH.md](PITCH.md).

---

## 0. Corrections after checking against real docs and real runs (5 Nov, evening)

### 0a. Direction change: the agent acts like a person at the laptop

After this plan was written, the user set a new rule: the agent must control the laptop **like a user**. It looks at the screen, moves the real pointer, clicks and presses keys, visibly, in the user's own apps. It does not script apps behind the scenes. The reference is the Mac companion Clicky.

That replaces the "hands" in sections 2 and 3:

| Was | Now |
|-----|-----|
| Tier 1 quick tools through direct system calls | Quick tools done the person's way: volume and media keys, Spotlight to open an app, keyboard shortcuts, scroll wheel, typing |
| Tier 2 scripted shortcuts (WhatsApp draft, instant Meet) | **Recipes**: short hints in memory that the screen agent treats as advice while doing every step visibly |
| Tier 3 with browser-use for web and macos-harness for native apps | **One screen agent**: Claude looks at a screenshot, decides, and the real pointer and keyboard act |
| Jev picks web or native | Jev reads the user's reply to a confirmation: yes, no or unclear |
| Safety gate called by the task when it reaches a risky step | Safety gate called **in code before every click and every Return key press**, using the name of the control under the pointer |

The conversation layer, the task runner, the stop watcher, the safety gate, memory and the schedule all stand. The contracts are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the reasoning and the cost are in [DECISIONS.md](DECISIONS.md).

### 0b. Other corrections

The details below changed once the libraries were checked. Where this section and a later one disagree, this section wins. Rows about browser-use and macos-harness are kept as a record of what was learned before they were dropped.

| Topic | The plan said | What is true |
|-------|---------------|--------------|
| **macos-harness** | An in-process library with six primitives, including Apple Events | A command-line tool with eleven commands (`get_app_state`, `click`, `type_text`, `press_key`, `set_value`, `scroll`, `paste`, `drag`, `select_text`, `perform_secondary_action`, `list_apps`). It reads a window as numbered text and acts in the background without moving the pointer. `native.py` is our own Claude loop around it |
| **macos-harness keys** | Used for Tier 1 keys and scroll | Its keys only reach one named app, so Tier 1 uses direct system calls. A newline in `type_text` presses Return, which sends in chat apps, so drafts never pass a newline through it |
| **Pushing to the agent** (4b) | "The SDK lets the client send messages into a live conversation" | `send_contextual_update` adds background context but does not make the agent speak. `send_user_message` sends a user turn. The mechanism is chosen in `docs/spikes/elevenlabs.md` |
| **Jev access** | Direct TypeSafe API with `JEV_API_KEY` | Through OpenRouter: `POST https://openrouter.ai/api/v1/systemone` with `OPENROUTER_API_KEY`, model `jev-latest` |
| **Jev speed** | About 150ms | Measured 200 to 320ms from this Mac, about $0.00002 per call |
| **Patient turn-taking** | To be found | `conversation_config.turn.turn_eagerness = "patient"` |
| **Repo layout** (section 6) | A nested `voice-laptop/` folder | The repo root is the project; code is in `src/voicelaptop/` |
| **Stop speed** | "At once" | The stop watcher only sees a sentence when ElevenLabs finishes transcribing it, and patient turn-taking makes that later. Cancelling still happens the moment the sentence arrives |
| **Memory** | A "with more time" idea | In scope: see section 5, Problem 5, and `docs/MEMORY.md` |

---

## 1. Goal

The user controls their whole Mac by voice, at any size of task:

| Size | Example | What should happen |
|------|---------|--------------------|
| Tiny | "Scroll down", "volume to 30%", "open Spotify" | Done in about a second, no questions |
| Medium | "Message Mum on WhatsApp: running late" | Opens WhatsApp, finds Mum, types it, **asks before sending** |
| Big | "Set up a Google Meet with Priya tomorrow at 3" | Knows to open Chrome → Google Calendar → create event with Meet link. **Asks if unsure** ("Priya Shah or Priya Patel?"). Confirms before sending the invite |
| Any time | "Stop" / "wait, cancel that" | Stops talking **and** stops whatever it's doing on the computer, at once |

---

## 2. Is there a base to build on?

There's no single project that does all of this. Good pieces exist for each layer, so the plan is to **combine three bases and write the glue ourselves**.

| Layer | Pick | Why | Rejected options |
|-------|------|-----|------------------|
| **Ears + mouth + conversation** | **ElevenLabs Agents** (Python SDK, your subscription) | Has speech-to-text, text-to-speech, turn-taking and **interruption built in**. Its LLM asks clarifying questions naturally. Calls local Python functions through `ClientTools` | Pipecat / LiveKit: more control but more to build. A good later move if we need Jev to route before the LLM |
| **Hands for web tasks** (Meet, Gmail, anything in Chrome) | **browser-use** (MIT, Python, very widely used) | Purpose-built for an AI agent driving Chrome. Supports Claude | Raw Playwright: we'd rebuild what browser-use already does |
| **Hands for native Mac apps** (WhatsApp, Finder, Spotify, Settings) | **browser-use/macos-harness** (MIT, Python) | Six raw primitives: screenshot, key, type, click, **accessibility tree**, Apple Events. It runs in the same process as browser-use, so it's one stack | **Agent S3**: strongest benchmark scores but heavy and slow; it's our fallback if the harness breaks. **cua**: runs in a VM, not your real laptop. **UI-TARS Desktop**: a standalone app, can't be embedded. **CursorTouch macos-use**: backup option |
| **Fast decisions** | **Jev** | Stop-vs-command, safe-vs-risky, web-vs-native, each in about 150ms | Having the LLM do all of it: slower, and free text instead of typed labels |
| **Brain for big tasks** | **Claude** (through browser-use and the harness) | Plans multi-step tasks and reads screens | n/a |

### Change from RESEARCH.md

RESEARCH.md recommended building our own voice pipeline. **This plan switches to letting the ElevenLabs Agent drive**, for three reasons:

1. You want the ElevenLabs agent to ask clarifying questions, and it does that out of the box.
2. Interruption and turn-taking are already solved in it, and building them well ourselves would take most of the week.
3. Six days is short.

**What we give up:** about a second of delay on tiny commands, because every sentence goes through the ElevenLabs LLM first, and Jev doesn't route before the LLM. That's fine for a prototype. It's listed as the first "with more time" item: move to Pipecat with Jev routing first.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  ElevenLabs Agent  (cloud: speech-to-text → LLM → text-to-speech)    │
│  • hears the user, speaks back, handles barge-in interruption         │
│  • system prompt: "ask if unsure, confirm before sending anything"    │
│  • calls client tools ↓                                               │
└───────────────┬──────────────────────────────────────────────────────┘
                │ client tool calls (via the Python SDK, running on the Mac)
┌───────────────▼──────────────────────────────────────────────────────┐
│  LOCAL APP (Python, on the laptop)                                    │
│                                                                       │
│  TIER 1 · Quick tools (instant, no AI)                                │
│    set_volume · scroll · open_app · open_url · press_keys ·           │
│    type_text · media_control                                          │
│                                                                       │
│  TIER 2 · App shortcuts (scripted, reliable)                          │
│    whatsapp_draft · meet_instant · (more added over time)             │
│                                                                       │
│  TIER 3 · General task runner (AI agent, works on anything)           │
│    start_task(goal) → Jev picks: WEB → browser-use                    │
│                                  NATIVE → macos-harness + Claude      │
│    answer_task(id, answer) · cancel_task(id)                          │
│                                                                       │
│  ALWAYS ON                                                            │
│    Stop watcher: reads every user transcript → Jev: CANCEL? → kill    │
│    Safety gate: every send/pay/delete/submit → Jev: CONFIRM? → ask    │
└──────────────────────────────────────────────────────────────────────┘
```

### Why three tiers

- **Tier 1** is for things that have one obvious system call. "Volume to 30%" is `osascript -e "set volume output volume 30"`. Using an AI agent for it would be slow and could get it wrong.
- **Tier 2** covers common multi-step tasks we can script exactly. A script is faster and more reliable than an AI working it out each time. For example, `meet.new` in Chrome creates an instant Meet in one step.
- **Tier 3** handles everything else. This tier is what makes "do anything" true.

The ElevenLabs LLM picks the tier, because the tool descriptions tell it when to use each.

---

## 4. Key flows

### 4a. Tiny command
```
User:  "Volume to 30 percent"
Agent → set_volume(percent=30) → returns "ok"
Agent: "Done."
```

### 4b. Clarifying question in the middle of a task
The hard part is that a Tier 3 task runs for a while, and the AI agent inside it may get stuck ("two contacts called Priya"). It can't talk to the user directly, so it **pauses and returns a question**:

```
User:  "Set up a Google Meet with Priya tomorrow at 3"
Agent: "Want me to send Priya a calendar invite, or just make a link?"   ← ElevenLabs LLM asks first
User:  "Send her an invite"
Agent → start_task(goal="Create Google Calendar event tomorrow 15:00 with Google Meet,
                         invite Priya")  → returns {task_id: "t1", status: "running"}
Agent: "On it."
   ... browser-use opens Chrome → Calendar → finds 2 Priyas ...
Local app → pushes to agent: {task_id: "t1", status: "needs_input",
                              question: "Priya Shah or Priya Patel?"}
Agent: "I found two Priyas. Priya Shah or Priya Patel?"
User:  "Shah"
Agent → answer_task("t1", "Priya Shah")
   ... task continues, reaches "Save & send invite" ...
Safety gate (Jev: NEEDS_CONFIRMATION) → pushes question:
Agent: "Ready to send the invite to Priya Shah for tomorrow 3pm with a Meet link. Send it?"
User:  "Yes"
Agent → answer_task("t1", "yes") → task finishes
Agent: "Sent."
```

**How the local app "pushes" to the agent:** the ElevenLabs SDK lets the client send messages and context into a live conversation. Check the exact method name in the docs (via Context7) on day 1. If pushing doesn't work, fall back to a `check_task(id)` tool that the agent polls, with the prompt telling it to check every few seconds.

### 4c. Interruption
There are two kinds of "stop", and both need handling:

| Situation | What handles it |
|-----------|-----------------|
| Agent is **talking**, user says anything | ElevenLabs barge-in, built in. Keep `interruption_mode = allow` on all tools |
| Agent is **doing** something on the computer | **Stop watcher.** Every user transcript goes to Jev. If the label is `CANCEL`, it cancels the running task at once (cancels the asyncio task and stops the browser-use / harness agent) |

**Why Jev here and not a keyword match:** "stop the music" is a *command* (pause Spotify), while "stop" or "no wait, don't" means *cancel*. A keyword match gets this wrong; a classifier with labels `CANCEL`, `COMMAND`, `OTHER` gets it right.

### 4d. Safety gate
Before any action that's hard to undo, the task runner calls `gate.check(action_description)`:

- Jev labels it `SAFE` or `NEEDS_CONFIRMATION`.
- On `NEEDS_CONFIRMATION`, the task pauses and asks the user (same path as 4b).
- **Fallback if Jev fails or times out (>800ms):** a keyword list (send, pay, buy, delete, remove, submit, post, invite, share). If there's any match, ask. **When unsure, always ask.**

---

## 5. Tool specifications

### Problem 1: `set_volume`

**Description:** Set the Mac's output volume to an exact percentage.

**Example 1**
```
Input:  {"percent": 30}
Output: {"ok": true, "volume": 30}
```
**Example 2**
```
Input:  {"percent": 150}
Output: {"ok": false, "error": "percent must be 0–100"}
```
**Example 3 (relative change)**
```
Input:  {"change": -10}        // current volume 45
Output: {"ok": true, "volume": 35}
```
**Constraints**
- Exactly one of `percent` (0–100) or `change` (−100–100).
- The result is clamped to 0–100.
- Must return in < 200ms.
- Implementation: `osascript -e "set volume output volume N"`; read the current level with `output volume of (get volume settings)`.

---

### Problem 2: `scroll`

**Description:** Scroll the window under focus.

**Example 1**
```
Input:  {"direction": "down"}
Output: {"ok": true}            // scrolls one "page" (default amount)
```
**Example 2**
```
Input:  {"direction": "up", "amount": "a_little"}
Output: {"ok": true}
```
**Constraints**
- `direction` ∈ {up, down, left, right, top, bottom}.
- `amount` ∈ {a_little, page, a_lot}, default `page`.
- `top`/`bottom` map to Cmd+↑ / Cmd+↓.
- Implementation: CGEvent scroll-wheel events (via the harness, or pyobjc Quartz).

---

### Problem 3: `whatsapp_draft`

**Description:** Open WhatsApp Desktop, open the chat with a contact, and type a message **without sending it**. Sending is a separate step that needs confirmation.

**Example 1**
```
Input:  {"contact": "Mum", "message": "Running late, 10 mins"}
Output: {"ok": true, "status": "drafted", "matched_contact": "Mum"}
        // agent then asks: "Send 'Running late, 10 mins' to Mum?"
```
**Example 2: ambiguous contact**
```
Input:  {"contact": "John", "message": "See you at 6"}
Output: {"ok": false, "status": "needs_input",
         "question": "I see John Smith and John Lee. Which one?",
         "options": ["John Smith", "John Lee"]}
```
**Example 3: no match**
```
Input:  {"contact": "Zed", "message": "hi"}
Output: {"ok": false, "status": "not_found",
         "question": "I couldn't find Zed in WhatsApp. Who did you mean?"}
```
**Constraints**
- WhatsApp Desktop must be installed and logged in; if not, return a clear spoken-friendly error.
- Contact matching: search through the accessibility tree; never guess when there are 2+ matches.
- **Must never press Send.** A separate `whatsapp_send()` runs only after a spoken yes.

---

### Problem 4: `start_task` / `answer_task` / `cancel_task`

**Description:** Run any goal that the quick tools and shortcuts can't cover. Tasks run in the background, so the conversation (and interruption) keeps working while they run.

**Example 1**
```
Input:  start_task({"goal": "Open Google Meet and start an instant meeting"})
Output: {"task_id": "t1", "status": "running"}
Later push: {"task_id": "t1", "status": "done",
             "summary": "Meeting started. Link copied: meet.google.com/abc-defg-hij"}
```
**Example 2: needs input**
```
Later push: {"task_id": "t1", "status": "needs_input", "question": "Use your work or personal Google account?"}
Input:  answer_task({"task_id": "t1", "answer": "work"})
Output: {"task_id": "t1", "status": "running"}
```
**Example 3: cancel**
```
Input:  cancel_task({"task_id": "t1"})
Output: {"task_id": "t1", "status": "cancelled", "summary": "Stopped after opening Chrome."}
```
**Constraints**
- Only **one** task runs at a time; a new `start_task` while one is running returns `{"status": "busy"}` and the agent asks whether to cancel the old one.
- Each task is limited to **25 agent steps** and **3 minutes**; past either limit it stops and reports where it got to.
- Status: `running` → `needs_input` ⇄ `running` → `done` | `failed` | `cancelled`.
- Executor choice: Jev labels the goal `WEB` or `NATIVE`. Fallback: if the goal mentions a website or Google/Gmail/YouTube/Meet, use `WEB`.
- Every irreversible step goes through the safety gate (section 4d).

---

### Problem 5: `remember` / `recall` / `forget` (memory)

**Description:** The agent remembers what it learns about the user so it stops asking the same questions. Some things the user tells it directly; others it works out from the answers the user gives during tasks. The user can inspect, correct and delete all of it by voice.

**Example 1: told directly**
```
User:  "Remember that Mum is Amma on WhatsApp."
Input:  remember({"kind": "alias", "key": "mum", "value": "Amma", "scope": "whatsapp"})
Output: {"ok": true, "status": "active"}
Later:  "WhatsApp Mum: running late" → drafts to Amma, and reads back "Send 'running late' to Amma?"
```
**Example 2: learned from answers**
```
Task 1: "Meet with Priya tomorrow at 3" → asks "Priya Shah or Priya Patel?" → "Shah"
        stored as a candidate: priya → Priya Shah   (seen once, not yet relied on)
Task 2: same question, same answer → promoted to active
Task 3: no question. The confirmation still says "Send the invite to Priya Shah?"
```
**Example 3: corrected**
```
User:  "No, I meant Priya Patel."
        the Priya Shah fact loses confidence; Priya Patel is stored
```
**Example 4: refused**
```
Input:  remember({"kind": "note", "key": "bank pin", "value": "4921"})
Output: {"ok": false, "error": "I don't store passwords, PINs or card numbers."}
```
**Constraints**
- Stored locally in SQLite at `~/.voicelaptop/memory.db`, readable only by the user. Nothing is sent to a memory service.
- Told directly → trusted at once. Inferred → trusted only after it is seen twice.
- A new value for the same key retires the old one. Retired facts are kept for the audit trail; `forget` wipes the value.
- A "yes" to a confirmation is never learned. **Nothing in memory can make a risky action skip its spoken confirmation.**
- Secrets (passwords, PINs, card numbers, one-time codes) are never stored.
- Learning runs in the background and can never slow down or break a task.
- "Forget everything" needs its own spoken confirmation.

---

## 6. Repo layout

```
voice-laptop/
├── README.md               setup + run (required)
├── ai.md                   AI tools used and how (required)
├── WRITEUP.md              1-page write-up (required)
├── pyproject.toml
├── .env.example            ELEVENLABS_API_KEY, ELEVENLABS_AGENT_ID,
│                           ANTHROPIC_API_KEY, JEV_API_KEY
├── agent_config/
│   └── agent.json          ElevenLabs agent prompt + tool schemas
│                           (synced with `elevenlabs` CLI pull/push)
├── src/voicelaptop/
│   ├── main.py             start conversation, register tools, run loop
│   ├── voice/
│   │   ├── session.py      ElevenLabs Conversation + callbacks
│   │   └── stop_watch.py   transcript → Jev → cancel
│   ├── tools/
│   │   ├── quick.py        Tier 1: volume, scroll, open_app, open_url, keys, type, media
│   │   └── apps/
│   │       ├── whatsapp.py Tier 2
│   │       └── meet.py     Tier 2
│   ├── tasks/
│   │   ├── runner.py       Tier 3: task state machine, one-at-a-time, limits, cancel
│   │   ├── web.py          browser-use wrapper
│   │   └── native.py       macos-harness + Claude wrapper
│   ├── safety/gate.py      Jev SAFE/NEEDS_CONFIRMATION + keyword fallback
│   └── jev/client.py       Jev API client, timeouts, fallbacks
└── tests/
    ├── test_quick.py       tools with osascript/CGEvent mocked
    ├── test_runner.py      state machine, cancel, limits, busy
    ├── test_gate.py        risky actions always ask, incl. when Jev is down
    └── jev_golden.jsonl    ~60 labelled utterances for router/stop/safety checks
```

---

## 7. Edge cases and failure modes

| Case | Expected behaviour |
|------|--------------------|
| "Stop the music" vs "stop" | Jev: `COMMAND` (pause media) vs `CANCEL` (kill task) |
| TV or another person talking in the background | ElevenLabs agent may react. Mitigation: agent prompt to ignore unclear speech; later, a wake word or speaker check |
| User dictates text containing "send" ("tell him to send the files") | The safety gate checks *actions*, not message content, so there's no false trigger |
| Contact name matches 2+ people | Always `needs_input`, never guess |
| WhatsApp not installed / not logged in | Spoken error: "WhatsApp isn't logged in. You'll need someone to scan the QR code once." |
| Chrome not running | `web.py` launches it; if it's not installed, fall back to Safari or explain |
| macOS permission missing (Accessibility, Screen Recording, Microphone, Automation) | Check at startup; speak which one is missing and how to grant it |
| Screen locked | Detect and say "Your screen is locked"; don't attempt actions |
| Task loops or gets lost | 25-step / 3-minute limit, then report the last step reached |
| Jev slow or down | Router → simple rules; safety → keyword list (asks more often); stop → keyword "stop/cancel/wait" |
| ElevenLabs connection drops | Auto-reconnect; running task keeps going, result spoken after reconnect |
| New task while one is running | `busy` → agent asks "Cancel the current task?" |
| Multiple monitors | Prototype targets the main display only (stated in README) |

---

## 8. Safety and privacy

- **The agent runs on your real laptop** with full control. It has a kill word, step and time limits, a confirmation gate, and runs one task at a time.
- **Screenshots go to Claude** for Tier 3 native tasks. Tier 1 and 2 send no screenshots. Stated in README.
- **API keys** stay in `.env`, never committed. `.env.example` has placeholders only.
- **No banking or payment demos.** The safety gate always asks for pay/buy actions anyway.

---

## 9. Testing

| Level | What | How |
|-------|------|-----|
| Unit | Quick tools, task state machine, safety gate | pytest, with system calls mocked |
| Classifier | Jev labels for router, stop and safety | Golden file of ~60 utterances; report accuracy and latency. Gate must have **zero** missed risky actions |
| Integration | Each tool really works on the Mac | Script that calls each tool directly (no voice) and checks the result |
| End to end | Full voice flows 4a–4d | Manual checklist of 10 spoken scenarios, run before recording. Note pass/fail and latency |
| Demo insurance | — | Record the 2–3 min video as soon as 3 flows work (day 5), then re-record if it improves |

---

## 10. Schedule

| Day | Date | Goal | Done when |
|-----|------|------|-----------|
| 0 | Thu 5 Nov | Research, pitch prep | ✅ This doc |
| 1 | Fri 6 Nov | **Pitch meeting.** Skeleton: ElevenLabs conversation from Python + mic + one tool (`set_volume`) | Say "volume to 30" and it changes |
| 2 | Sat 7 Nov | All Tier 1 tools + stop watcher + Jev client | 7 quick commands work; "stop" cancels a dummy 10-second task |
| 3 | Sun 8 Nov | Tier 3 web: `start_task` + browser-use + push-back to agent | "Start a Google Meet" works by voice |
| 4 | Mon 9 Nov | Tier 3 native (harness) + WhatsApp shortcut + `needs_input` flow | WhatsApp draft → spoken confirm → send works |
| 5 | Tue 10 Nov | Safety gate, edge cases, tests, **record backup video** | Checklist of 10 scenarios mostly passing |
| 6 | Wed 11 Nov | README, ai.md, write-up, final video. **Submit by 6pm** (6h buffer) | Submitted |

**If behind schedule, cut in this order:** native Tier 3 (keep WhatsApp as Tier 2) → Jev executor choice (use the keyword rule) → relative volume. **Never cut:** the stop watcher, the safety gate, hands-free activation.

---

## 11. Fallback plans

| If this breaks | Switch to |
|----------------|-----------|
| macos-harness too unstable | CursorTouch `macos-use`, or raw pyobjc accessibility calls for the WhatsApp script only |
| browser-use too slow or flaky for Meet | Tier 2 script: open `https://meet.new` in Chrome, read the URL |
| ElevenLabs push into a live conversation not possible | `check_task` polling tool |
| Jev access problems | LLM call for routing; keyword lists for stop and safety |
| ElevenLabs Agents delay too high for tiny commands | Accept for prototype; list Pipecat + Jev-first routing as next step |

---

## 12. Check on day 1 (before writing much code)

- [ ] ElevenLabs Python SDK: `Conversation` + `ClientTools` + mic audio interface run on your Mac
- [ ] ElevenLabs SDK: how to push a message or context into a live conversation
- [ ] ElevenLabs agent setting for **patient turn-taking**, so slow speakers aren't cut off
- [ ] Jev: API access, request format, real latency
- [ ] macos-harness installs and can click a button in WhatsApp
- [ ] browser-use can drive your normal Chrome profile (logged into Google)

Use Context7 for the current ElevenLabs, browser-use and Jev docs when building. The method names above are from search results and need checking.

---

## Sources

- macOS agents: [browser-use/macos-harness](https://github.com/browser-use/macos-harness/wiki), [macos-harness releases](https://github.com/browser-use/macos-harness/releases), [MoClaw on macos-harness](https://moclaw.ai/blog/browser-use-macos-harness), [macOS-use by browser-use](https://www.sourcepulse.org/projects/1839452), [CursorTouch macos-use](https://pypi.org/project/macos-use/), [logesh45/computer-control](https://github.com/logesh45/computer-control), [macOS26/agent](https://github.com/macOS26/agent)
- General computer-use agents: [Agent S](https://github.com/simular-ai/agent-s), [Agent S docs](https://docs.simular.ai/agent-s/introduction), [UI-TARS Desktop (fork)](https://github.com/Horlet/UI-TARS-desktop), [cua](https://cua.ai/articles/build-computer-use-agent-github-cua-ai-minutes)
- Browser: [browser-use overview](https://landscape.jimmysong.io/projects/browser-use/), [Launch HN: Browser Use](https://hn.svelte.dev/item/43173378)
- Voice: [ElevenLabs tool interruptions](https://elevenlabs.io/docs/eleven-agents/customization/tools/tool-configuration/tool-interruptions), [ElevenLabs tools](https://elevenlabs.io/docs/conversational-ai/customization/tools), [ElevenLabs Python SDK](https://github.com/fern-api/elevenlabs-python), [Pipecat frames](https://docs.pipecat.ai/server/frames/overview), [Pipecat vs LiveKit](https://www.channel.tel/blog/pipecat-vs-livekit-voice-framework-decision)
