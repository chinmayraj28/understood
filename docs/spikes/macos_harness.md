# Spike: macos-harness on this Mac (5 Nov 2026)

## Not used to act: superseded by real pointer control

macos-harness acts in the background without moving the pointer, which is the opposite of what the
user wants, so it is not part of the product. The findings below are kept because they describe
macOS, WhatsApp and Chrome, not the harness. The Swift follow-up is `docs/spikes/screen_eyes.md`.

Run by the native/WhatsApp engineer, 19:12 to 19:42 on 5 Nov 2026, against macos-harness 0.2.1,
WhatsApp Desktop 2.26.41.74 (the native Mac app), Chrome and Spotify, on macOS 26.3.1.

**Status.** Part way through this spike the product changed direction (see `DECISIONS.md`,
"the agent acts like a person at the laptop"): macos-harness is no longer how the agent acts,
and the Python code was retired to `legacy_python/`. The measurements below are still true, and
the section "What carries over to the Swift app" lists the findings that matter for the new design.

"Verified" means I ran it and saw the result. "Inferred" means I read it in the harness source
or reasoned from what I saw, without a direct test.

---

## 1. Permissions (verified)

```
$ uv run macos-harness telemetry disable     -> "enabled": false, "disabled_by_config": true
$ uv run macos-harness doctor
{ "ready": true, "app": "the app that started macos-harness",
  "granted": { "accessibility": true, "screen_recording": true,
               "post_events": true, "input_monitoring": true },
  "missing": {} }
```

All four permissions were already granted to Orca. Nothing was blocked by permissions.

## 2. How Python should call it, latency, and stopping (verified)

**What it is.** `macos-harness` is a thin command-line client (`cli.py`). Each call sends its
arguments as one JSON message over a Unix socket (`~/Library/Application Support/macos-harness/helper.sock`)
to a long-lived helper process (`python -m macos_harness.helper`), which does the work and sends back
the text. The client starts the helper on first use; the helper exits after 15 idle minutes.
There is no supported in-process API: the tools live inside the helper. The socket protocol is
private (`protocol.py`, versioned `MacosHarnessIPC-1`, and the helper refuses a client whose
package path or version differs).

**Latency, measured** (`legacy_python/scripts/spikes/native/latency.py`, 5 runs each, warm helper):

| Call | Through the CLI (child process) | Raw socket from asyncio |
|------|---------------------------------|-------------------------|
| `doctor` (no real work: pure overhead) | 33 ms | 12 ms |
| `get_app_state` Finder, full tree | 400 ms | 389 ms |
| `get_app_state` Finder, "what changed" | 412 ms | 374 ms |

Helper-side time per command over the whole spike (from `helper.log`, 70+ calls):

| Command | Median | Range | Notes |
|---------|--------|-------|-------|
| `get_app_state` | 410 ms | 200 ms to 9.0 s | 0.7 to 1.2 s right after an action (it waits for the UI to settle). 2.1 s for the first read of an app in a new session. 9.0 s when it had to launch WhatsApp. |
| `click` | 29 ms | 16 to 190 ms | |
| `set_value` | 84 ms | | |
| `type_text` | 65 ms for 63 characters | 21 ms to 1.4 s | slow cases are the "settle before keys" wait |
| `press_key` | 88 ms | 4 to 504 ms | |
| `scroll` | 48 ms | | |
| `list_apps` | 30 ms | | |

So the CLI costs about 20 to 35 ms more per call than the raw socket, against 400 ms or more for any
read. **Recommendation (for the Python path):** run the CLI as an asyncio child process with
`--json`, one per call. It is the supported interface and cancellation is trivial.

**Stopping an action in flight, measured** (`legacy_python/scripts/spikes/native/cancel.py`): a 5-second
`press_key --key Escape --duration 5` in Finder, client killed after 0.5 s. The helper logged the
call as ending at 504 ms instead of 5,000 ms. The helper polls the client's socket before every
event and stops when it closes. So: kill the child process, then reap it. The shared helper stays up
(that is by design) and exits by itself; it had exited at 19:42:26 after the spike.

**Sessions.** Element numbers belong to a helper "session". By default the session is the first
parent of the CLI process that is not a shell (`helper.py`, `_agent_process`), so all calls from one
Python process share numbers. `MACOS_HARNESS_SESSION=<name>` overrides this.

**Errors.** With `--json` a failure prints `{"error": {"code", "name", "message", "cancelled", "tag"}}`
and exits 1; a successful action prints `null`. Useful names: `permissions_missing` (122),
`mac_locked` (134), `app_not_responding` (132, retry the read), `app_not_running` (131),
`no_such_app` (130), `user_took_over` (110), `no_session` (112), and `server_error` with tag
`invalid_element_id` (a number from an older read). The full list is in the package's `errors.py`.

## 3. What `get_app_state` returns per app (verified)

Each read is: an optional `<app_notes>` block (tips the harness ships for some apps), a
`Window: "...", App: ...` line, one line per element (`<tabs><number> <role> <attributes>`), an
optional `The focused UI element is N ...` line, and the path of a JPEG screenshot of the window.
Attributes are `Description:`, `Value:`, `ID:`, `Help:`, `Secondary Actions:`, `URL:`,
`Placeholder:`. A value can contain real line breaks (chat message previews do), so a parser must
treat a line whose number does not follow on from the previous element as a continuation.

| App | What the tree shows | Size (full read) |
|-----|---------------------|------------------|
| **WhatsApp** (native app) | Everything needed: sidebar, search box, chat list rows with name, unread count and the last message, the open chat's messages, the message box and its buttons. Stable `ID:` names (below). | 5,970 chars, 53 elements (chat list only); about 6,100 chars with a chat open |
| **Finder** | Sidebar rows, list view rows with name, date, size, kind, and file URLs. | 10,816 chars |
| **Google Chrome** | **The whole web page**, not just the browser frame. See below. | 7,092 chars, 156 elements (a settings page) |
| **Spotify** | **Almost nothing**: four empty containers, the window buttons and the menu bar (Spotify, File, Edit, View, Playback, Window, Help). The screenshot showed the full player. Three reads over about 10 seconds gave the same. | 552 chars (1,488 on the first read, which included the harness's Spotify notes) |

**Chrome in detail.** The tree had the toolbar (Back, Forward, Reload, the address bar as a
settable text field with its URL, extension buttons), the bookmarks bar, the tab strip (each tab
with its title and a Close button), and under an `HTML content` element the page itself: 23
`link` elements with their URLs, `button`s, `heading`s, plain `text`, a `switch`, and a `table`
with rows and cells. So the native path **can** read and drive web pages in Chrome. Two cautions
from the harness source (inferred, not tested): `set_value` on a browser's address field also
presses Return, and the harness switches Chromium's accessibility on at the first read of a
session, which takes a few hundred milliseconds.

## 4. How big a read is (verified)

A full read is 5,000 to 11,000 characters for an ordinary window (roughly 1,500 to 3,000 tokens).
The "what changed" read after an action is much smaller: 255 characters when nothing changed in
Finder. Every read also writes a 2940x1668 JPEG screenshot (about 250 KB) to
`~/Library/Caches/macos-harness/screenshots/`, cleaned up after an hour.

## 5. WhatsApp: the reliable sequence (verified unless marked)

WhatsApp was logged in (chat list visible). It was not running at the start; the first read launched
it in the background.

**Element names that do not change between reads:**

| What | Role and `ID:` | Notes |
|------|----------------|-------|
| Search box | `text`, `TokenizedSearchBar_TextView` | `set_value` is refused ("cannot be set"): you must type. |
| Clear search | `button`, `TokenizedSearchBar_DeleteButton` | Only present while the box has text. Clicking it empties the box and takes the focus out of it. |
| Search results | `container` with `Description: Search results` | Rows sit under headings `Chats`, `Contacts`, `Not in your contacts`, `Media`, `Starred`, `Messages`. |
| Result rows | `ChatListSearchView_ChatResult` (existing chats and groups), `..._ContactResult` (saved contacts with no chat), `..._NonContactResult` (a phone number that is not a contact) | Each row appears twice (a container and a button) with the same description. |
| Open chat | `container`, `ChatMessagesTableView`, `Description: Messages in chat with <name>` | The name is wrapped in invisible direction marks (U+202A ... U+202C). |
| Message box | `text entry area`, `ChatBar_ComposerTextView` | Empty box: no `Value:` and no `(settable)` flag. |
| Send | `button`, `ChatBar_SendButton`, `Description: Send` | **Only appears after real typing.** In the same place, when the box is empty, is `ChatBar_VoiceMessageButton` ("Voice message"; its help text says "hold to record, release to send"). |

**(a) Search for a contact.** Focus the search box, type the name. The results first show an
`In progress` spinner element; read again until it is gone (about 1 second).

**(b) Read the matches.** Take the rows with the three result IDs under the `Search results`
container. A row's name is its `Description:` up to the first `", "` followed by U+200E (that is where
WhatsApp's own additions start, such as "3 unread messages"). Names can contain commas, emoji
and a trailing space. The list is virtualised: only rows on screen appear, about 11 at a time.

**(c) Open the chat.** Click the result row (a plain click works). The first read after opening a
chat sometimes fails with `app_not_responding` (twice in the spike, once taking 5.3 s); reading
again works. Check the chat by the `Messages in chat with <name>` description.

**(d) Put a draft in the box without sending.** Click the message box, then `type_text` the text.
Measured: 63 characters in 111 ms, including emoji, accents and an en dash. `set_value` also puts
the text in the box (verified: it reads back), **but WhatsApp does not notice**: the microphone
button stays and the Send button never appears. Never let a line break reach `type_text`: it presses
Return, which sends.

**(e) Read the draft back.** The message box line becomes
`text entry area (settable) Description: Compose message, Value: <the text>, ID: ChatBar_ComposerTextView`,
and `ChatBar_SendButton` appears. Both checked in the live test.

**(f) Send as a separate step.** Click `ChatBar_SendButton` by its ID rather than pressing Return.
*Not run*: I did not send the one allowed test message. The send path was ready but the Python code
was retired before I ran it, and the retired code must not be run.

**(g) Clear a draft.** Click the message box, `press_key "super+a BackSpace"`, read back: the
`Value:` is gone. Verified several times.

**Fragile things found:**

1. **Element numbers shift between reads.** A transient "Updating chats..." line came and went,
   moving every number by one. A click with an old number failed with `invalid_element_id`. Always
   read, find by `ID:`, then act.
2. **The tree's "focused element" can be wrong about where typing goes.** This was the most important
   finding. With a chat open, a plain (accessibility) click on the search box made the tree report the
   search box as focused, but the keyboard stayed in the message box: typed text landed in the chat's
   message box (reproduced twice, `focus_probe`). A simulated mouse click
   (`MACOS_HARNESS_ALWAYS_SIMULATE_CLICK=1`) moved the keyboard correctly in a warm session but not
   always in a brand-new session. **Cmd+F** (WhatsApp's own search shortcut) put the keyboard in the
   search box in both fresh-session runs where it was tried. In every case nothing was sent (no
   Return, no line breaks); the stray text was caught by reading back and removed.
3. **Never trust focus; check after typing.** The rule that worked: type only into an empty field,
   then read and check that the field holds exactly what was typed and that no other field changed.
4. **`no_session` right after a good read** when a previous process that used WhatsApp had just exited
   (the helper tidies up the old session). The action was refused before anything happened, so one
   re-read and retry is safe.
5. **Phone numbers** come back formatted (`+44 7700 900123`, with no-break spaces and direction marks):
   compare digits only.
6. **Draft speed.** The full draft flow (search, wait for results, open chat, type, read back) took
   4.4 to 11.5 s, mostly in the 7 to 10 reads at 0.4 to 1.2 s each.

## What carries over to the Swift app

These do not depend on macos-harness:

- **WhatsApp element IDs** above are WhatsApp's own accessibility identifiers, so the Swift safety
  check and the WhatsApp recipe can use them (for example: the control under the pointer is
  `ChatBar_SendButton` means "this click sends").
- **The microphone trap:** where Send appears, an empty box shows "Voice message" instead, whose help
  says "release to send". The safety check should treat a click there as risky too.
- **Typing must be real key events.** Setting the box's accessibility value does not make WhatsApp
  see the text, so its Send button never appears.
- **Do not decide where keys will land from the accessibility "focused element".** Verify after
  typing. Real pointer clicks (the new design) are more likely to move the keyboard than accessibility
  presses, but this was not tested with real clicks.
- **Cmd+F** focuses WhatsApp's search box.
- **Chrome exposes the whole page through accessibility** (links, buttons, fields, tables), so the
  safety check can name the web control under the pointer. Electron/CEF apps may not: Spotify showed
  nothing. (Inferred: Chrome only fills its tree once an accessibility client asks for it; the
  harness does this on its first read. A Swift reader will need the same; I did not verify which
  attribute the harness sets.)
- **Sizes:** 5 to 11 thousand characters per full window tree, if the screen agent is ever given the
  tree as text.

## Files from this spike

All moved to `legacy_python/` by the restructure (reference only, not to be run):

- `legacy_python/scripts/spikes/native/latency.py`: CLI against raw socket timing.
- `legacy_python/scripts/spikes/native/cancel.py`: killing the client stops a held key.
- `legacy_python/scripts/spikes/native/draft_timing.py`: repeated live draft-and-clear runs (never sends).
- The retired wrapper and shortcut, with 51 unit tests and one live test, are in `legacy_python/`
  (`src/voicelaptop/harness.py`, `src/voicelaptop/tools/apps/whatsapp.py`, `tests/test_harness.py`,
  `tests/test_whatsapp.py`, `tests/live/test_whatsapp_live.py`).
