# Architecture and module contracts

This is the coordination document. Every engineer builds against the contracts here and in `Packages/HFCore`. If a contract has to change, tell the lead with the exact new signature; do not edit `HFCore` yourself.

## What we are building

**Handsfree** (working name) is a native Swift macOS app that lets a person who cannot use their hands run their Mac by speaking goals. It lives in the menu bar, with a companion beside the pointer that shows what it is doing.

Three rules set by the user:

1. **It acts like a person at the laptop.** It looks at the screen, moves the real pointer, clicks, scrolls and presses keys, visibly, in the user's own apps and their own Chrome. It does not script apps behind the scenes: no AppleScript or `open -a` to make things happen, no automation browser, no background accessibility actions. Reading state without acting is fine (the current volume, the name of the button under the pointer).
2. **It is a native Swift app at Clicky's level of polish**, built on Clicky's open-source code (MIT, github.com/farzaa/clicky): its menu bar panel, its full-screen transparent overlay with the cursor companion, its design system and its permission flow. Clicky points at what the user should click and is activated by holding Control+Option. Ours does the clicking and has no button to press, because its users cannot press one.
3. **It remembers and learns the user's preferences**, and nothing it remembers can make a risky action skip its spoken confirmation.

## How the pieces run

```
 YOU (speaking)  ── microphone, always on ──▶  ElevenLabs Agent (cloud): hears, talks, handles interruption
                                                   │ calls tools on the Mac
 ┌─────────────────────────────────────────────────▼──────────────────────────────────────────┐
 │ Handsfree.app  (Swift, menu bar + overlay; shell adapted from Clicky)                        │
 │                                                                                              │
 │  HFVoice        VoiceSession: the live conversation; registers every ToolSpec; speaks events │
 │     │ every user sentence ─▶ HFDecisions.StopWatcher ─▶ Jev: cancel? ─▶ halt hands + cancel  │
 │     ├─ quick tools      HFHands.QuickTools     one action, done the way a person does it     │
 │     ├─ memory tools     HFMemory.MemoryTools   remember / recall / forget / correct          │
 │     └─ task tools       HFTasks.TaskTools ─▶ TaskRunner (one task at a time, in background)  │
 │                              └─ HFScreenAgent.ScreenAgent                                    │
 │                                    look:   HFEyes.ScreenEyes           screenshot            │
 │                                    decide: Claude computer use         next action           │
 │                                    check:  HFEyes.AccessibilityLabels  name the target       │
 │                                            HFDecisions.SafetyGate      risky? ─▶ ask the user│
 │                                    act:    HFHands.SystemHands         real pointer and keys │
 │                                                                                              │
 │  ActivityBus (HFCore): every module posts what it is doing ─▶ overlay companion + menu bar   │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Packages and ownership

Each package is its own Swift package under `Packages/`, depends on `HFCore` by path (`.package(path: "../HFCore")`), and is built and tested on its own: `cd Packages/<Name> && swift build && swift test`. Packages do not depend on each other. Anything one needs from another arrives through a protocol in `HFCore`, passed in by the app. That is what lets eight people work at once without breaking each other's builds.

| Package | Owner | Contains | Main public types |
|---------|-------|----------|-------------------|
| `HFCore` | lead | Shared types and protocols. No behaviour that touches the network, screen or microphone | `ToolSpec`, `JSONValue`, `Decision`, `ScreenAction`, `ScreenRole`, `KeyChord`, `UIElementInfo`, `TaskEvent`, `TaskContext`, `TaskExecuting`, `Hands`, `Eyes`, `Labels`, `Shot`, `MemoryProviding`, `ActivityBus`, `Settings`, `SpeakableError` |
| `HFDecisions` | decisions | Jev client, the three classifiers with keyword fallbacks, the safety gate, the stop watcher | `JevClient`, `Classifiers` (conforms to `UtteranceClassifying`, `RiskClassifying`, `AnswerClassifying`), `SafetyGate`, `StopWatcher` |
| `HFMemory` | memory | SQLite store, learning, recipes, memory voice tools | `MemoryStore`, `Memory` (conforms to `MemoryProviding`), `MemoryTools` |
| `HFHands` | quick | Real pointer and keyboard; quick voice tools; permission checks | `SystemHands` (conforms to `Hands`), `QuickTools`, `Permissions` |
| `HFEyes` | native | Screenshots; read-only accessibility lookups | `ScreenEyes` (conforms to `Eyes`), `AccessibilityLabels` (conforms to `Labels`) |
| `HFTasks` | runner | Task state machine and task voice tools | `TaskRunner`, `TaskTools` |
| `HFScreenAgent` | web | Claude client; the look, decide, check, act loop | `ClaudeClient` (conforms to `StructuredLanguageModel`), `ScreenAgent` (conforms to `TaskExecuting`) |
| `HFVoice` | voice | ElevenLabs conversation, agent definition, agent setup | `VoiceSession`, `AgentConfiguration` |
| `Handsfree/` + `Handsfree.xcodeproj` | app | The app itself, adapted from Clicky: menu bar panel, overlay companion, onboarding, and the composition root that wires every package together | |

Shared, language-neutral data lives in `Fixtures/` (golden examples, recipes, tool definitions) and prompts live in `docs/prompts/`. Load them from the package that needs them by copying them in as package resources.

## Conventions

- **Toolchain:** Xcode 26, Swift 6.3 toolchain, `// swift-tools-version: 6.0`, **Swift 5 language mode** on every target (`swiftSettings: [.swiftLanguageMode(.v5)]`), minimum macOS 14. Swift 5 mode is deliberate: it keeps async/await and actors but spares us fighting strict-concurrency errors around AppKit and the C accessibility APIs.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`). Unit tests need no network, no permissions and no real apps: inject fakes. Tests that hit a real API or the real Mac are tagged and only run when `HF_LIVE=1` is set (`@Test(.enabled(if: ProcessInfo.processInfo.environment["HF_LIVE"] == "1"))`), and skip with a clear reason when a permission is missing.
- **No third-party dependencies** unless there is no sensible alternative. SQLite is the system `SQLite3` module. HTTP is `URLSession`. The one expected exception is the ElevenLabs Swift SDK in `HFVoice`.
- **Naming, from Clicky's codebase, which the app is built on:** clarity over brevity. A reader with no context should understand a name on sight. No single-letter names. Comments explain why, especially around AppKit and accessibility quirks.
- **Errors that can reach the user are `SpeakableError`**: one short plain sentence that is fine to read aloud. Never a system error code or a stack trace.
- **Secrets** come only from `Settings.load()`. Never print, log or commit one.
- **Logging:** `os.Logger(subsystem: "com.handsfree", category: "<package>")`.
- **Post to `ActivityBus.shared`** whenever your module does something the user should see: the pointer is about to move, a click landed, a task is waiting for an answer. The companion beside the pointer is drawn from these.
- **Keep it explainable.** The user has to explain every module to Hiya's engineers. Prefer a small clear type to a clever one, and write a short doc comment on every public declaration.
- **Do not run `git commit`.** Do not edit files outside your package and your named docs. If you need something from the lead (a contract change, a shared fixture), ask.

## Contracts

The protocols and types are in `Packages/HFCore/Sources/HFCore/`. Read those files; they are short and commented. What follows is the behaviour each package owes the others.

### The safety gate judges a structured action, never a sentence

This is the most important contract in the product, and it was changed after a review found a real flaw. At first the screen agent built a sentence such as `Press Return in ..., which may send or submit it`, the eyes built phrases such as `an unlabelled link`, and the gate's rules matched sentences with patterns. Each package's own tests passed, because each tested its own wording, but the three did not agree, so a Return in a chat app or an icon-only Send button could slip past the gate's fixed rules.

Now there is one type, `ScreenAction` (in `HFCore/ScreenAction.swift`):

- **What it holds:** the kind of action (click, double click, right click, drag, key press, typed line break), the key as a parsed `KeyChord`, and the target as a `UIElementInfo`: its role (one shared `ScreenRole` vocabulary), label, developer identifier, app, window and whether it is enabled. A target that could not be determined is `nil`, which the gate treats as unknown and never as safe.
- **Who builds it:** the screen agent, through `Labels.clickAction(at:)`, `Labels.keyAction(_:)` and `Labels.lineBreakAction()`, **at the moment of the action**. On this Mac the same spot in WhatsApp reads `button "Voice message"` before text is typed and `button "Send"` after, so a name read before the pointer arrives cannot be trusted.
- **Who reads it:** the gate's fixed rules read the fields directly (`role`, `words`, `key.isReturn`, `app`). Nothing in the product pattern-matches a sentence.
- **The sentence form** exists in one place, `ScreenAction.description`, used for the classifier, the audit log and the fallback spoken question: `Click button "Send" in WhatsApp, window "WhatsApp"`.
- **Privacy:** long text inside a content control such as a message bubble is left out of the description, so the words of the user's messages are never sent to the classifier.

### Voice tools (every package that exports tools)

A tool is a `ToolSpec`. Export them from a function that takes the live objects the tools need, for example `QuickTools.make(hands:) -> [ToolSpec]`.

- A handler is `async (JSONObject) -> JSONObject` and **never throws**. Failure is `ToolResult.failure("<one short sentence that can be read aloud>")`. Success is `ToolResult.ok([...])`.
- `description` is written for the voice agent's LLM: say when to use the tool and when not to, with a spoken example.
- `parameters` is a JSON Schema object. Keep parameter names short and obvious, and use enums where the choices are fixed. Validate everything: the values come from an LLM that heard speech.

### HFDecisions

Jev is reached at `POST https://openrouter.ai/api/v1/systemone` with `Authorization: Bearer <OPENROUTER_API_KEY>` and body `{"model": "jev-latest", "state": ..., "questions": {...}}`. Measured from this Mac: 200 to 320 ms and about $0.00002 per call. The full question wording, thresholds, fixed rules and fallback lists are in `docs/spikes/jev.md`; the golden examples are in `Fixtures/jev_golden.jsonl`.

- `classifyUtterance`: cancel, command or other. "Stop the music" is a command. A bare "no" while the assistant is waiting for an answer is an answer, not a cancel.
- `classifyRisk`: safe or needs confirmation, for a `ScreenAction`. Fixed rules read its fields; Jev is sent its `description`. **Never fails open**: low confidence, an error, a timeout or an unknown target mean needs confirmation. It runs before every click and every key press that can commit something, so latency and false alarms both matter.
- `classifyAnswer`: yes, no or unclear. A wrong yes is the worst error in the product, so anything uncertain is unclear.
- `SafetyGate.check`: the risk classifier plus fixed rules that always ask, plus a short audit log.
- `StopWatcher`: given every sentence the user says. When a task is running and the sentence is a cancel, it calls its cancel closure at once. It never blocks the caller, and never cancels a task that started after the sentence was spoken.

Without an OpenRouter key, or when Jev fails or is slow, each classifier falls back to keyword rules and says so in `Decision.source`.

### HFHands

`SystemHands` implements `Hands` with Quartz events on the user's real Mac.

- The pointer **glides**; it never teleports. `click` glides to the target, then presses.
- `halt()` freezes an action in flight within a few tens of milliseconds, with no button or modifier left held down. It is checked between every small pointer movement and every typed character.
- `typeText` handles any Unicode and refuses a newline unless `allowReturn` is true, because Return sends in chat apps.
- It posts `.pointerMoving`, `.clicked`, `.typing` and `.scrolled` to the activity bus so the companion can follow.
- Needs the Accessibility permission. Detect when events are being dropped and throw a `SpeakableError` saying so.

`QuickTools` are the instant commands, each done the way a person would: volume and media with the keyboard's own keys, opening an app through Spotlight, switching windows with Command+Tab, scrolling, typing, shortcuts, and a small pointer tool. Definitions are in `docs/TOOLS.md` and `Fixtures/quick_tools.json`.

### HFEyes

- `ScreenEyes` implements `Eyes`: a screenshot of the main display scaled for the model, and a region at higher detail. The `Shot` it returns carries the screen rectangle it shows, so image pixels map back to screen points exactly. This Mac is Retina, so backing pixels, points and the scaled image are three different sizes; an error here makes every click miss. The overlay companion must not appear in screenshots.
- `AccessibilityLabels` implements `Labels`: read-only lookups that return what is under a point and what has focus, as a `UIElementInfo` with a `ScreenRole`, a label and an identifier. This is what the safety gate judges, so a Send button must come back as a button labelled "Send", and a control with no human-readable name must come back with an empty label, never a guess. Lookups are bounded by a timeout so an unresponsive app cannot hang a task, and a lookup that times out returns nil. Switching on web content in Chrome is an explicit call made by the app at startup and undone at quit.

### HFTasks

`TaskRunner` runs one goal at a time in the background of the conversation. The design, the state diagram and the test scenarios are in `docs/TASKS.md`.

- States: running → needsInput ⇄ running → done | failed | cancelled. Every change emits exactly one `TaskEvent` to the sink.
- It builds the `TaskContext` the executor uses. `askUser` and `confirm` pause the task and wait for the user's reply; `confirm` only returns true on a clear yes from `AnswerClassifying`.
- Limits: `Settings.maxTaskSteps` steps and `Settings.maxTaskSeconds` of working time. Time spent waiting for the user does not count: a user who speaks slowly must never be timed out by their own pauses.
- `cancel()` takes effect within about a second whether the task is working or waiting, and first calls an injected `onCancel` closure (the app passes `hands.halt`) so the pointer freezes at once.
- It hands every answered question and every finished task to `MemoryProviding`, and never lets memory slow down or break a task.

`TaskTools`: `start_task(goal)`, `answer_task(answer)`, `cancel_task()`, `task_status()`.

### HFScreenAgent

`ScreenAgent` implements `TaskExecuting`: look at a screenshot, let Claude decide one action, check it, act with the real pointer and keyboard, repeat. The design, the API shapes and the measured timings are in `docs/SCREEN_AGENT.md`; the prompt is in `docs/prompts/screen_agent.md`. Clicky's `ElementLocationDetector.swift` already calls Claude's computer-use tool from Swift and is a useful reference for the request shape and for picking the screenshot resolution that matches the display's aspect ratio.

**The safety backstop lives here and is in code, not only in the prompt.** For every click it first moves the pointer to the target, then asks `Labels.clickAction(at:)` what is there now, calls `context.confirm(...)` with that action, and only then presses. For every key press that can commit something (Return or Enter with any modifier, Space or Return on a focused button, delete shortcuts) it asks `Labels.keyAction(_:)` at that moment and confirms it; each press of a repeated key is confirmed separately. A typed line break is confirmed through `Labels.lineBreakAction()`. The text of a message being typed is never sent to the gate, only the action. If confirm returns false the action is not performed, and the model is given the user's own words (`context.lastAnswer`) so it can act on a correction. It never types into a password field. Only the task runner releases the hands after a stop.

It calls `context.step()` once per model turn, `context.report(...)` when it moves to a new stage, uses `context.memoryHints` as advice, and stops within a second when cancelled, leaving the hands released.

### HFMemory

Stored in SQLite at `<Settings.dataDirectory>/memory.db`, outside the repo, readable only by the user. The design is in `docs/MEMORY.md`; built-in recipes are in `Fixtures/recipes.json`.

- **Explicit beats learned.** "Remember that Mum is Amma on WhatsApp" is active at once. Something inferred starts as a candidate and becomes active when seen a second time.
- **A new value for the same key retires the old one.** Facts are retired, not deleted, so there is an audit trail. `forget` is the exception: the value is wiped.
- **Recipes** are short hints about how a task is done on this Mac ("to message someone on WhatsApp: open WhatsApp, click the search field, type the name..."). They are advice for the screen agent, which still does every step visibly and verifies what it sees.
- **Never stored:** passwords, PINs, card numbers, one-time codes, the content of private messages.
- **Memory never lowers safety.** A yes to a confirmation is never learned.
- Learning calls an injected `StructuredLanguageModel`, runs in the background, and swallows every failure.

`MemoryTools`: remember, recall, forget (with an explicit flag for "forget everything"), and a correction path.

### HFVoice

`VoiceSession` owns the live ElevenLabs conversation through the ElevenLabs Swift SDK. What was learned about the platform (agent configuration, client tool shape, turn settings, how to make the agent speak when a task has news) is in `docs/spikes/elevenlabs.md`; the system prompt is in `docs/prompts/voice_agent.md`.

- Registers every `ToolSpec` it is given and routes tool calls to the handlers.
- Calls its transcript listeners for every user sentence (the stop watcher is one).
- `push(_ event: TaskEvent)` makes the agent say a question, a confirmation or a result while the user is silent.
- Injects the memory summary into the agent's prompt at session start.
- Posts `.listening`, `.userSpeaking`, `.userSaid`, `.agentSpeaking` and `.voiceDisconnected` to the activity bus.
- Reconnects on its own when the connection drops, and never takes the app down.
- `AgentConfiguration` builds the whole agent definition from code (prompt, tools, turn settings, voice, model), and creating or updating the agent on ElevenLabs is idempotent.

### The app

Adapted from Clicky. It owns the menu bar panel, the overlay companion that follows the real pointer and shows what the agent is doing, the first-run permission flow (Microphone, Accessibility, Screen Recording), and the composition root that creates one of each package's main type and connects them. It has no dock icon and no button the user must press.
