# The screen agent

The screen agent carries out a spoken goal the way a person sitting at the Mac would. It looks at a screenshot, decides what to do, has risky actions checked, and then moves the real pointer and presses real keys while the user watches. It lives in `Packages/HFScreenAgent`. Its system prompt is `docs/prompts/screen_agent.md`, bundled into the package as a resource; a unit test fails if the two copies drift apart. `Packages/HFAgentCLI` runs it from a terminal.

Each claim below is marked **[ran]** (seen on this Mac), **[docs]** (from Anthropic's current documentation) or **[design]** (a choice we made that has not been measured).

## 1. The loop, in plain words

Each turn has four parts:

1. **Look.** Claude has the latest screenshot of the main display, scaled to 1280x800.
2. **Decide.** Claude answers with one or more actions. For example: press `cmd+space`, type `TextEdit`, press `Return`, take a screenshot. It sends several only when it is sure of each one.
3. **Check.** Before a click, a drag, a Return, or a shortcut that can send, delete or quit, the agent asks the accessibility tree what is really there, for example `button "Send" in WhatsApp`. It then calls `context.confirm(...)`. The safety gate decides whether the user must be asked out loud. A "no" means the action is skipped and Claude is told.
4. **Act.** `Hands` glides the real pointer and types the real keys.

After an acting turn, a fresh screenshot goes back to Claude (unless its own last action was a screenshot), and the next turn starts. The task ends when Claude calls `task_finished`, which carries a success flag and one spoken sentence.

```
 goal + memory hints + screenshot ─▶ Claude ─▶ actions ─▶ for each action, in order:
                                       ▲                    risky? labels.describe… ─▶ context.confirm ─▶ no: skip, tell Claude
                                       │                    act with Hands
                                       └──── tool results + fresh screenshot ◀─┘
```

Each model turn calls `context.step()` once, so the runner's step limit counts turns. When a turn reaches a new stage, Claude calls `report_progress` ("Opening WhatsApp"), which becomes `context.report(...)`. While Claude is deciding, the agent posts `.thinking(caption:)` to `ActivityBus.shared`, so the companion can show it is thinking.

## 2. Talking to Claude: the exact API

There is no official Swift SDK, so `ClaudeClient` posts JSON to `https://api.anthropic.com/v1/messages` itself.

- **Headers [docs, ran]:** `x-api-key: <key>`, `anthropic-version: 2026-10-21`, `content-type: application/json`. The toolset needs no `anthropic-beta` header.
- **Which computer-use tool [docs, ran]:** the 5.5 models (`claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`) accept only the computer **toolset** `computer_toolset_20260801` on the Claude API. The older `computer_20251124` tool returns a 400 on them, so Clicky's `ElementLocationDetector.swift` request (`computer_20251124` + beta header + `anthropic-version: 2023-06-01`) cannot be reused as is. Only its idea was kept: match the screenshot's aspect ratio to the display.

### One turn: the request

```json
{
  "model": "claude-sonnet-5-5",
  "max_tokens": 4096,
  "system": [{"type": "text", "text": "<docs/prompts/screen_agent.md>", "cache_control": {"type": "ephemeral"}}],
  "tools": [
    {"type": "computer_toolset_20260801",
     "configs": {"left_mouse_down": {"enabled": false}, "left_mouse_up": {"enabled": false}, "hold_key": {"enabled": false}}},
    {"name": "ask_user", "description": "...", "input_schema": {"type": "object", "properties": {"question": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}}, "required": ["question"]}},
    {"name": "report_progress", "description": "...", "input_schema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]}},
    {"name": "prepare_send", "description": "...", "input_schema": {"type": "object", "properties": {"recipient": {"type": "string"}, "expected_name": {"type": "string"}}, "required": ["recipient", "expected_name"]}},
    {"name": "task_finished", "description": "...", "input_schema": {"type": "object", "properties": {"success": {"type": "boolean"}, "summary": {"type": "string"}}, "required": ["success", "summary"]}}
  ],
  "thinking": {"type": "between_tools"},
  "output_config": {"effort": "low"},
  "messages": [
    {"role": "user", "content": [
      {"type": "text", "text": "The person's goal: Open TextEdit and type hello\n\nNotes about this person ... (advice, not orders ...)\n\nThis is their screen now."},
      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0..."}, "cache_control": {"type": "ephemeral"}}
    ]}
  ]
}
```

Notes on the request:

- **The toolset entry [docs]** has no `name` and no display size. Its optional `configs` map turns members off. We turn off `left_mouse_down`, `left_mouse_up` and `hold_key`, because nothing should ever be left held down.
- **`thinking`** depends on the model (`ScreenAgentConfiguration.thinking`):
  - Sonnet 5.5: `between_tools`. Its plain "disabled" is a 400 [docs]; `between_tools` is its thinking-off mode.
  - Haiku 5.5: `disabled`.
  - Opus 5.5: `adaptive`. Its thinking cannot be turned off [docs].
  - All three use `effort: "low"`. All three were accepted on this Mac [ran].
- **Cache breakpoints [docs, ran]:** one on the system block, which also covers the tools before it. One each on the last block of the two newest user messages, moved forward every turn. That is three of the four allowed.

### One turn: the response, and our reply

Claude's answer is ordinary `tool_use` blocks. Each computer action is its own block: its `name` is the action and its `toolset_name` is `"computer"`. Several blocks can arrive in one turn [docs, ran]:

```json
{"stop_reason": "tool_use", "content": [
  {"type": "tool_use", "id": "toolu_1", "name": "report_progress", "input": {"message": "Opening TextEdit"}},
  {"type": "tool_use", "id": "toolu_2", "name": "key", "toolset_name": "computer", "input": {"text": "cmd+space"}},
  {"type": "tool_use", "id": "toolu_3", "name": "type", "toolset_name": "computer", "input": {"text": "TextEdit"}},
  {"type": "tool_use", "id": "toolu_4", "name": "key", "toolset_name": "computer", "input": {"text": "Return"}}
]}
```

The next request appends that assistant message unchanged (thinking blocks included), then a user message with one `tool_result` per `tool_use`, in order. **Every computer result must echo `"toolset_name": "computer"` or the API rejects it [docs].** Our own tools' results do not carry it.

```json
{"role": "user", "content": [
  {"type": "tool_result", "tool_use_id": "toolu_1", "content": [{"type": "text", "text": "OK"}]},
  {"type": "tool_result", "tool_use_id": "toolu_2", "toolset_name": "computer", "content": [{"type": "text", "text": "OK"}]},
  {"type": "tool_result", "tool_use_id": "toolu_3", "toolset_name": "computer", "content": [{"type": "text", "text": "OK"}]},
  {"type": "tool_result", "tool_use_id": "toolu_4", "toolset_name": "computer", "content": [
     {"type": "text", "text": "OK"},
     {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}],
   "cache_control": {"type": "ephemeral"}}
]}
```

- **A refused or failed action** gets `"is_error": true`, with text saying what happened. Every later action in that turn is not run. Each gets `"is_error": true` and the documented text `Not executed: an earlier computer action in this turn failed.` [docs]. Every `tool_use` must get a result, or the request is rejected [docs].
- **When Claude declines on safety grounds,** the response has `stop_reason: "refusal"`. We say "Claude declined to help with that" and stop.

### The actions Claude can send (toolset members)

Coordinates are `[x, y]` in pixels of the **latest full screenshot**, with the origin at the top left, even after a `zoom` [docs]. `Shot.screenPoint(imageX:imageY:)` turns them into screen points.

| Action | Input | What we do |
|---|---|---|
| `screenshot` | `{}` | `eyes.grab(maxLongEdge: 1280)`; the image goes back |
| `zoom` | `region: [x0, y0, x1, y1]` | `eyes.grab(region:)` on that area; the image goes back |
| `left_click`, `double_click`, `triple_click`, `right_click`, `middle_click` | `coordinate?`, `text?` (modifiers such as `"shift"` or `"super+shift"`) | **checked**, then `hands.click` |
| `left_click_drag` | `start_coordinate`, `coordinate` | **checked** (both ends named), then `hands.drag` |
| `mouse_move` | `coordinate` | `hands.move` |
| `scroll` | `scroll_direction` (up, down, left, right), `scroll_amount`, `coordinate?` | `hands.scroll` (lines; capped at 30) |
| `type` | `text` | `hands.typeText`; **checked** only if the text contains a newline |
| `key` | `text` (xdotool style: `Return`, `super+space`, `BackSpace`), `repeat?` | converted to HFHands names; **checked** for Return, Enter, Command+Delete, Command+Q and Command+Shift+D, and for plain Delete outside a text field |
| `wait` | `duration` | sleep, at most 10 s |
| `cursor_position` | `{}` | the pointer position in image pixels |
| `left_mouse_down`, `left_mouse_up`, `hold_key` | | turned off in `configs` |

**Key names.** The model writes keys the xdotool way, and HFHands has its own names, so the agent converts them:

| The model sends | HFHands receives | Note |
|---|---|---|
| `super`, `meta`, `win` | `cmd` | |
| `alt` | `option` | |
| `BackSpace`, `Delete` | `delete` | On a Mac the key labelled "delete" is backspace, which is what "cmd+Delete" (Move to Bin) means |
| `Page_Down` | `page_down` | Every other name is lowercased |

**Our own tools:**

- `ask_user(question, options)` calls `context.askUser`. The answer goes back to Claude as "The person answered: …".
- `report_progress(message)` calls `context.report`, but only when the stage has changed.
- `prepare_send(recipient, expected_name)`: see section 3.
- `task_finished(success, summary)` ends the run. With `success` true it returns the summary's first sentence; with `success` false it throws `SpeakableError(summary)`.

## 3. The safety backstop

The backstop lives in code (`SafetyBackstop.swift`), not only in the prompt. It does not decide what is risky; the gate does that. **It decides what the gate must see, and builds it from what is really on screen at that moment.** What `context.confirm` receives is an HFCore `ScreenAction`: the kind of action, the key, and the target and destination as structured fields (role, label, identifier, app, window). Its one-sentence form, `description`, is built in HFCore and nowhere else, so the agent, the eyes and the gate cannot disagree about wording.

**For a click, the pointer glides there first; then the target is named; then the gate is asked; then the press happens.** The order matters. In WhatsApp, the spot of the voice-message button becomes Send once text has been typed, so naming the target before the glide could describe the wrong control.

| Action | What `context.confirm` receives (its `description`) |
|---|---|
| Any click (left, double, right) | `Click button "Send" in WhatsApp, window "WhatsApp"`, or for an icon-only button `Click an unlabelled button (identifier "ChatBar_SendButton") in WhatsApp, window "WhatsApp"` |
| Drag | `Drag list item "Taxes.pdf" in Finder, window "Documents" to Dock item "Bin" in Dock` |
| Return or Enter, with any modifier (Command+Return sends in Gmail) | `Press Return in text field "Type a message" in WhatsApp, window "Amma"`. **Each press of a repeated key is confirmed separately.** |
| Space on a focused button, link, menu item or checkbox (it presses it) | `Press Space in button "Delete chat" in WhatsApp, window "Amma"` |
| Command+Delete, and with Shift or Option | `Press Command+Delete in ...` |
| Plain Delete when focus is not a text field | `Press Delete in list item "Inbox" in Mail, ...` |
| Command+Q; Command+Shift+D (Send in Mail) | `Press Command+Q in ...` |
| Typed text containing a newline | `Type a line break in text area "Compose message" in WhatsApp, ...` (the text itself is left out) |
| Not checked | Screenshots, zoom, moving the pointer, scrolling, waiting, typing on one line, and other shortcuts (`cmd+space`, `cmd+l`, `cmd+t`, Tab, Escape, arrows) |

- **The text of a message never reaches the gate.** Typing "tell him to send the files" is not checked; only the Send that follows is, and its description names the button, not the message. HFCore also leaves the long text of message bubbles out of descriptions.
- **When the target can't be found,** the description says so (`Click an unknown control in WhatsApp`), and the gate treats an unknown target as unknown, never as safe.
- **It never types into a password field.** If the focused element is a password field, the typing is refused in code, and Claude is told to hand over to the person. When the hands themselves refuse because Secure Input is on, their sentence is passed on to the user, not retried.
- **Typing must land in a real text box.** Before typing, the agent reads the focused control, waiting up to 0.5 s for focus to settle (Spotlight's field appears a moment after cmd+space). If it is not a text field, text area or search field, the typing is refused and Claude is told where focus really is, so it clicks the box first. This guards against two things: the wrong-box problem (in WhatsApp, clicking the search box sometimes left focus in the message box), and the hands' current way of typing (every character on key code 0), which only real text fields read correctly.
- **The spoken question.** The second argument of `confirm` is what the user hears, and it carries the message and the recipient: `Send "running late" to Amma?`.
  - **The message** comes from the text the agent itself typed, not from the model's account of it.
  - **The recipient** cannot come from the window title, because WhatsApp's window is always titled just "WhatsApp" (found by the eyes engineer).
    - So in the same turn as the action that sends, Claude first calls `prepare_send(recipient, expected_name)`. `recipient` is the name in the open chat's header in the latest screenshot; `expected_name` is who the goal means, after memory notes such as "Mum is saved as Amma".
    - **If the two do not match, the agent is in the wrong chat.** The user is not asked at all: every send-like action is refused in code until a matching `prepare_send`, and Claude is told to open the right chat.
    - A window title that names someone (not just the app) is used only when there is no `prepare_send`.
    - **A phone number is spoken in short groups** a listener can check. An unsaved contact's header shows its number, so "+44 7700 900123" is read as "+44 7700 900 123", with WhatsApp's invisible marks removed. A saved name is used as it is.
  - **No read-back** is made for a search box or an unknown control, because typing a query into Spotlight is not a message. On the real Mac, Return in Spotlight was first read back as `Send "TextEdit" to Orca?`; that is fixed and tested [ran].
- **On a "no",** the action is skipped and the rest of the turn is not run. Claude is told, together with the user's own words from `context.lastAnswer` (for example `Their words: "no, say fifteen minutes"`), so it can fix the thing and try again. The retry goes through the backstop again. The prompt forbids trying the refused action by another route.
- **Bypasses closed off:**
  - There is no JavaScript, AppleScript or accessibility action. The only way to act is through `Hands`.
  - Mouse-down and key-hold members are turned off.
  - Every click names its target after the pointer has arrived.

### Limits, honestly

- The gate judges a control's *name*. A control that is visually labelled but has no accessibility name comes back unlabelled. The gate then has only the role and identifier to go on, and should ask; that is safe but slower.
- **Typed single-key shortcuts are not checked.** In Gmail, typing `#` with nothing focused deletes the selected email. Typing is only checked for newlines.
- **Other shortcuts are not on the list.** Only the shortcuts listed above are checked. An app-specific send or delete shortcut that is not on the list passes through, unless it includes Return or Enter.
- **The name and the press are a few milliseconds apart.** The lookup happens with the pointer already on the target (2.5 to 7 ms measured by the eyes engineer), but a window could still change in between.
- **Recipient checks have two weak spots.**
  - The header name is what Claude says it read. A misread means the user hears the wrong name; they can still say no, and the click itself is checked.
  - Names match loosely (case, accents and emoji ignored, and a first name matches a full name). So "Priya" matches "Priya Patel"; Claude must give the full expected name.
- **The CLI has no gate.**
  - Interactively, it asks on the terminal for every check.
  - With `--allow-in`, it allows only checks that name the listed apps.
  - `--never-send` refuses every Send-like target, every Return outside a search field, and every click on a control that cannot be named.

### Windows the agent did not open (`WindowGuard.swift`)

On this Mac a Return meant for Spotlight reached Oracle's Java updater, which had popped up by itself, and started an installer. A window the agent did not open can take the front at any moment, and the next key press then goes to it. So, in code:

- **Keys go only where the agent meant them.**
  - Before every key press and every typing run, the agent reads where keyboard focus is at that moment.
  - After each screenshot Claude sees, keys may go to the app that was in front then.
  - The agent's own actions may bring one new app forward: a Command shortcut or a Return (Spotlight opening an app, Command+Tab), or a click on a Dock item or a menu.
  - Anything else holding focus is a window the agent did not bring forward. The key is not pressed, Claude is told so, and a fresh screenshot goes back with the result.
- **After cmd+space, typing waits for Spotlight.** It waits up to 1 s for Spotlight to take focus, so the name cannot land in the app behind it. If Spotlight never takes focus, the typing is refused.
- **Password prompts, installers, updaters and password managers are never acted on: one shared rule.** HFCore's `ProtectedSurfaces` list matches them by bundle identifier and by name; it covers SecurityAgent, Installer, Software Update, Oracle's Java updater, Sparkle, Microsoft AutoUpdate, Gatekeeper warnings, password managers and others.
  - **Before every action of any kind** (click, drag, pointer move, scroll, typing, each key press), the agent builds the action through the labels and checks `ScreenAction.landsOnProtectedSurface`. That is true when the target's app or the app in front is on the list, or the target is a password field. Clicks and drags are checked again once the pointer has arrived.
  - The same check runs at every screenshot.
  - If it is true, nothing is done and the user is **not** asked to confirm, because a yes would still have the agent agreeing to an install or typing into a password prompt. The task stops with HFCore's sentence: "A password or install window has appeared, so I've stopped. That step needs someone's hands."
  - This replaced the agent's own password-field refusal, so there is one rule. The prompt says the same.
- **Our own overlay is never a target.** If a click target or the focus belongs to Handsfree, nothing is done, and Claude is told the agent cannot see what is really under the pointer.

Limits:
- The rule works at the level of apps. A new window or sheet inside the app already in use (WhatsApp's own pop-up, say) is not treated as foreign; the click and key checks still apply to it.
- An app opened by an earlier action of ours is accepted once. So a window that appears in the instant after our own Command shortcut can slip through as "ours". It is still subject to every other check, and protected windows never pass.

### Holding while the user speaks

A spoken "stop" is acted on only once its transcript has arrived and been classified, which can take a second or more. So the app passes `holdWhile` ("the user is speaking right now", from the voice session) to `ScreenAgent`:

- **What waits:** no new action starts while it is true. That covers the glide before a click, every press, every typing run, and each press of a repeated key.
- **How it waits:** in 50 ms slices, responsive to cancellation. If the sentence was a stop, the task is cancelled during the wait and nothing more happens; otherwise the agent carries on where it was.
- **In flight:** an action already under way finishes its current small step. The hands' `halt()` stays the hard stop.
- **Bound:** the wait is capped by `maxHoldSeconds` (default 4 s), so a stuck signal or a television cannot freeze a task. Hitting the cap is logged and counted in `lastRunStats.holdBoundHits`.
- **A stuck signal costs one bound, not one per action.** Once a hold reaches its bound, the signal is treated as stuck, and holds are skipped until it next reads false.
- **Accounting:** time spent holding is not a step or a model turn.
- **On screen:** while holding, the agent posts `.thinking(caption: "Listening")`. Posts go to the `ActivityBus` passed to `ScreenAgent(..., activity:)`, which defaults to `.shared`; tests pass their own.

## 4. Speed: measured timings and the recommended settings

Setup: a 1280x800 PNG screenshot, effort `low`, and the thinking setting per model as above. All runs were on this Mac (Accessibility and Screen Recording granted to Orca).

### Model latency on a drawn screen [ran, `HF_LIVE=1 swift test --filter Live`]

The real agent loop with real Claude, on a picture of a chat window, with fake hands (nothing on the Mac moved). The goal was to click Send, and the user declined.

| Model | Seconds per turn | What it did after the "no" |
|---|---|---|
| Haiku 5.5 | 1.1–1.3 | kept going until the 3-step limit |
| Sonnet 5.5 | 2.0–3.2 | first run: asked the user what to do. Second run: clicked another, unlabelled control (also held by the backstop) until the step limit |
| Opus 5.5 | 2.3–4.1 | stopped and said it had not sent (both runs) |

All three aimed at the Send button. The backstop asked each time, and nothing was clicked.

### Real tasks on the real Mac [ran, `swift run hf-agent ...`]

| Task | Model | Total | Turns | Seconds per model turn | Seconds acting per turn | Result |
|---|---|---|---|---|---|---|
| TextEdit: new document, type a line, close without saving | Haiku 5.5 | 34.6 | 8 | 1.1–2.4 | 1.5–5.0 | done |
| Same (TextEdit was already open, so easier) | Sonnet 5.5 | 17.5 | 5 | 2.0–2.5 | 1.1–1.9 | done |
| Same | Opus 5.5 | 37.9 | 6 | 3.5–5.2 | 1.2–4.4 | done |
| Chrome: new tab, example.com, read the heading, close the tab | Haiku 5.5 | 28.9 | 8 | 1.2–2.9 | 1.4–4.8 | said "Example Domain" (the page's title; see below) |
| Same | Sonnet 5.5 | 16.1 | 4 | 2.0–2.2 | 1.2–4.5 | quoted the page's only paragraph |

**Correction about the "wrong heading":** I first reported Sonnet's answer as wrong. A direct fetch of example.com shows the page has **no heading element at all**: only the title "Example Domain" (shown on the tab) and one paragraph. So Sonnet quoted the most heading-like text on the page, and Haiku's "Example Domain" was most likely read off the tab. In a later run Haiku said exactly that: "example.com has no separate heading". That was a bad test, not a bad model.

Second batch, after the changes in section 3 (glide before naming, a settle pause between actions in a batch, waits capped at 2 s, acting time broken down by part):

| Task | Model | Total | Turns | Seconds per model turn | Where acting time went | Result |
|---|---|---|---|---|---|---|
| Chrome heading | Sonnet 5.5 | 18.1 | 4 | 1.6–2.1 | wait 6.4, settle 1.8, hands 1.3, screenshot 0.4, lookup + gate ~0 | quoted the paragraph, closed the tab |
| Chrome heading | Haiku 5.5 | 16.9 | 4 | 1.5–1.6 | wait 5.1, settle 2.3, hands 1.9, screenshot 1.1 | "no separate heading", quoted the paragraph, closed the tab |
| TextEdit, then quit TextEdit | Sonnet 5.5 | 16.1 | 3 | 2.7–2.8 | wait 4.3, screenshot 1.2, settle 1.0, hands 0.5 | **stopped by the hands**: "Something is blocking my pointer" (see open risks) |
| TextEdit, then quit TextEdit | Sonnet 5.5 | 90.3 | 15 | 2.8–5.0 | wait 22.6, settle 4.6, screenshot 4.4, hands 2.3 | ran out of steps |

What the numbers say:

- **Turns matter more than seconds per turn.** Haiku is about twice as fast per turn. In the first batch it took 8 turns where Sonnet took 4 or 5, so Sonnet finished first. In the second batch both took 4 turns on the Chrome task, and Haiku was a little faster.
- **The biggest single cost is waiting Claude asks for.** It requested 5–23 s of `wait` per task to let pages load. Waits are now capped at 2 s each, and the prompt says they are rarely needed. Two of the second-batch runs were made before the cap, so that saving is not measured yet.
- **The rest of acting time is small.**
  - Screenshots took 0.1–0.3 s each, and naming a target plus the CLI's instant "gate" about 0 s (the eyes measured 2.5–7 ms per lookup).
  - Gliding and typing took 0.3–2.3 s per task.
  - The settle pause costs 0.2 s per extra action in a batch. That is the price of not opening Calculator.
- **Batching works.** For example: 21 actions over 8 turns (Haiku), 10 over 4 (Sonnet).
- **Caching works.** Over 99% of input tokens were cache reads (for example 91,358 cached against 18 uncached).
- **Still single runs per setting.** The comparison is not settled.

**The demo's first task, for real [ran, under the live-run lock]:** "WhatsApp <test contact>: running late, ten minutes" (`hf-agent --test-contact`, Sonnet 5.5). `--never-send` refused the send, and `--decline-words` played the person saying "No, don't send it. Clear the message box and stop."

| Time | Step | What happened |
|---|---|---|
| 0–2.2 s | | Web content switched on in the browsers and Electron apps, then a 2 s wait for it to take effect |
| 5.0 s | 1 | "Opening WhatsApp": cmd+space, "WhatsApp", Return. Checked as `Press Return in search field "Spotlight Search" in Spotlight, window "Spotlight"` and allowed |
| 10.9 s | 2 | `Click text area "Compose message" in WhatsApp, window "WhatsApp"`, checked and allowed; then the message was typed |
| 14.8 s | 3 | **Held:** `Press Return in text area "Compose message" in WhatsApp, window "WhatsApp"`. The user would hear `Send "running late, ten minutes" to <the contact's number>?`. Declined |
| 17.4 s | 5 | Box cleared with cmd+a and Delete, then `task_finished(success: false, "As you asked, I didn't send the message and cleared the box.")` |

- **Totals:** 17.0 s from the first step, 5 model turns of 1.8–2.5 s each, and 8 actions.
- **Acting time:** hands 2.0 s, wait 2.0 s, settle 1.6 s, screenshots 0.7 s, lookups 0.1 s.
- **Checked afterwards, read-only:** the message box is empty (WhatsApp shows the voice-message button again, not Send), and the only click in the run was on the message box.
- **Not tested here:** the test chat was already open when the run began, so finding the contact by search was not exercised.
- **The recipient** in the spoken question is the contact's number, because that chat is named by its number.

**A race found on the real Mac [ran]:** cmd+space, the typed name and Return, sent back to back in one turn, made Spotlight open **Calculator**. Return arrived before Spotlight had updated its top hit. The agent now pauses `settleSeconds` (0.2 s) before each action that follows another in the same turn. The Calculator it opened was closed afterwards.

**Recommendation [design]:** `claude-sonnet-5-5` as the default (the lead has chosen it; it stays configurable through `Settings.taskModel`), effort `low`, `thinking: between_tools`, 1280-pixel screenshots, several actions per turn. Haiku 5.5 is the speed fallback: it matched Sonnet's turn count on the Chrome task and was quicker per turn. Opus 5.5 was the slowest per turn, with no accuracy gain on these tasks.

### Ways we cut time

1. **The first screenshot goes in the opening message,** so the first turn does not spend a round trip asking for one.
2. **Several sure actions per turn,** each checked in order. If a turn acted but did not end with a screenshot, one is attached to its last result, which saves the extra round trip the toolset documentation allows us to skip.
3. **Prompt caching** on the system prompt and tools (about 4,500 tokens for the toolset definition alone) and on the two newest turns.
4. **Small images:** 1280x800 for a 16:10 display, under every image limit. Claude can `zoom` to read small text instead of every screenshot being large.
5. **Old screenshots are kept** until there are 30 of them, then replaced by a note in one batch, down to the last three. Pruning one per turn would break the cache every turn, and Anthropic warns that editing history can invalidate thinking blocks. A 25-step task never reaches 30 images, so this normally never happens.
6. **One long-lived `URLSession`,** so connections are reused between turns.
7. **Waits are capped at 2 s,** and the prompt says the system already pauses after each action. Waits Claude asked for were the largest acting cost measured.
8. **A 0.2 s settle pause** goes before each action that follows another in the same turn, and before the screenshot that shows the turn's result. It costs a little time per action but avoids a stale screenshot or a race (Spotlight opening Calculator), either of which costs a whole extra turn.

## 5. Stopping, failures and results

- **Cancelling the Swift task:**
  - calls `hands.halt()` at once, through `withTaskCancellationHandler`, so a glide or a half-typed word freezes;
  - cancels the HTTP request in flight (`URLSession.data(for:)` honours task cancellation);
  - leaves the hands halted. Only the task runner releases them after a stop (`docs/ARCHITECTURE.md`), so a stop cannot be undone by the task unwinding.
  - Measured in unit tests: under 1 s, both while Claude is deciding and while the pointer is mid-glide, and under 0.5 s while holding for speech. When the runner revokes the context, `askUser`, `confirm` and `step` throw, and the agent unwinds the same way.
- **`StepLimitReached` is rethrown.** The runner words the summary from its own progress log.
- **Failures become one short speakable sentence (`SpeakableError`):**

| What went wrong | What the user hears |
|---|---|
| Claude rejected the key | "Claude rejected my key. Please check the Anthropic key in settings." |
| Overloaded after retries | "Claude is busy right now. Please try again in a moment." |
| No network | "I can't reach Claude. Please check the internet connection." |
| Hands error | "The pointer or keyboard stopped responding, so I stopped." A `SpeakableError` from the hands (such as Secure Input) is passed on word for word |
| Screenshot error | "I couldn't see the screen. Screen Recording permission may be missing." |
| Claude refused | "Claude declined to help with that, so I stopped." |

  Overload and server errors (429, 5xx, 529) and dropped connections are retried twice before giving up. The API's own error text is logged, never spoken, and the key is never logged.

- **The result** is the first sentence of `task_finished`'s summary, at most 200 characters.
- **Only `task_finished` succeeds.** When a reply has no tool call, the agent handles it by `stop_reason`:
  - `pause_turn`: the conversation is sent back so Claude carries on.
  - `max_tokens` (cut off): Claude is nudged once to continue with shorter actions.
  - Any other reply with no tool call, such as "I couldn't find Priya.": Claude is nudged once to call `task_finished`, `ask_user` or the next action.
  - A second reply without a tool call fails the task, with what Claude said as the spoken message.

## 6. ClaudeClient for the rest of the app

`ClaudeClient` also conforms to `StructuredLanguageModel`, for memory. `extract(instructions:input:schema:)` sends the schema as structured outputs:

```json
"output_config": {"format": {"type": "json_schema", "schema": {...}}}
```

It reads the first `text` block as JSON. It does **not** use a forced `tool_choice`, because Sonnet 5.5 and Opus 5.5 reject that with a 400 [docs; the 400 seen on this Mac through browser-use]. It uses `Settings.smallModel` (Haiku 5.5). It was measured live at 1.5 s for a small schema [ran].

## 7. Running and testing it

- `cd Packages/HFScreenAgent && swift build && swift test` runs the unit tests, with Claude, the hands, the eyes and the labels all faked. They cover:
  - a risky click held, then confirmed or declined, with the glide before the lookup, and a name that changes as the pointer arrives (Voice message, then Send) checked by its new name;
  - typing refused when focus is not a text box;
  - keys refused when focus is in a window the agent did not bring forward (with a fresh screenshot to Claude), while Spotlight launching an app is accepted;
  - typing after cmd+space waiting for Spotlight, and refused if it never opens;
  - an installer in front, or a protected updater taking focus, stopping the task;
  - our own overlay never clicked;
  - phone numbers matched by their digits;
  - a reply with no tool call never counted as success (nudge once, fail on the second; max_tokens and pause_turn handled);
  - Return held in a message field, and each repeated press confirmed;
  - Space on a focused button checked;
  - no typing into a password field;
  - the wrong chat blocking a send without asking;
  - typed text never reaching the gate;
  - holding while the user speaks, releasing when they stop, cancelling during a hold, and the bound;
  - questions reaching the user;
  - steps and the step limit;
  - cancellation;
  - every failure mapping;
  - the request shape;
  - structured extraction.
- `HF_LIVE=1 swift test --filter Live` makes one cheap call, one structured extraction, and the drawn-screen run for three models (a few cents in total).
- `cd Packages/HFAgentCLI && swift run hf-agent "<goal>"` **moves the real pointer**. Questions and checks are asked on the terminal, and Ctrl+C halts.
  - `--model`, `--effort`, `--long-edge`, `--settle` and `--steps` change the settings.
  - `--allow-in TextEdit,Spotlight` and `--answer "..."` make it unattended: only checks naming those apps are allowed.
  - `--never-send` refuses anything that could send (see section 3). When it refuses a send, the `--answer` text becomes the person's words.
  - `--test-contact` runs the demo's first task, aimed only at `TEST_WHATSAPP_CONTACT` from `.env`, with `--never-send` switched on.
  - Web content in browsers and Electron apps is switched on at start, without waiting: the first model turn (2 to 3 s) covers the 2 s it needs to take effect. A click on a web page that is not yet readable has an unknown target, which the gate treats as a reason to ask. The switches are restored on exit and on Ctrl+C.
  - At the end it prints the acting breakdown: lookup, confirm, hands, screenshot, settle, hold, wait.
  - Close whatever a run opened when it is done.
