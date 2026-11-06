# Not used: superseded by the screen executor

Spike notes on browser-use 0.13.14 as the web executor. On 5 Nov 2026 the user chose person-like control (the agent moves the real pointer in the user's own apps), so browser-use was dropped while this spike was running. The code it produced is in `legacy_python/src/voicelaptop/tasks/web.py` and `legacy_python/scripts/spikes/web/`, for reference only. These notes are kept because several findings apply to any approach that drives Chrome, and because they record why browser-use would have been hard to make safe and fast.

Each claim is marked **[ran]** (seen on this Mac), **[source]** (read in the installed browser-use code) or **[inferred]** (not tested).

Setup: Chrome 156.0.8078.80, macOS 26.3.1, browser-use 0.13.14, profile `Default` (signed in to Google), the user's own Chrome open the whole time (pid 42535, untouched throughout).

## 1. A signed-in Chrome while the user's Chrome stays open

| Option | What happened |
|---|---|
| `BrowserSession.from_system_chrome(profile_directory="Default")` | **[ran]** Works, but badly. browser-use copies the *whole* profile (1.3 GB: extensions, service-worker caches, open tabs) to a temp folder every run: 6.1 s copy, 11.7 s first launch. The copy includes `Sessions`, so the agent's Chrome reopened all the user's tabs, and on the second run start-up hung for 30 s and failed (`TIMEOUT ERROR ... on_BrowserStartEvent`). **[source]** browser-use never deletes this copy (it only cleans folders named `browseruse-tmp-*`), so each run leaves 1.3 GB of the user's live cookies in `$TMPDIR`. |
| Connect over CDP to the user's running Chrome | **[ran]** Not possible without restarting it: it was not started with a debugging port and has no `DevToolsActivePort` file. **[inferred, from Chrome's documented policy]** Chrome 136+ refuses `--remote-debugging-port` on the default user data folder, and Chrome's newer "allow remote debugging" switch asks for a click on every connection, which a hands-free user cannot give. |
| A dedicated automation profile folder (sign in once) | **[ran]** browser-use silently copies *any* Chrome user data folder to temp before launching (`BrowserProfile._copy_profile`, which runs whenever the executable is Chrome). The original folder stayed empty, so a one-time sign-in there would be thrown away after each run. It only persists if the folder name contains `browser-use-user-data-dir-`, or if we launch Chrome ourselves and connect with `cdp_url`. Either way the user must sign in once, which they cannot do without hands. |
| **Lean copy (what we built)** | **[ran]** Copy only the sign-in state (`Cookies`, `Device Bound Sessions`, `Preferences`, `Secure Preferences`, `Accounts`, `Local Storage`, `TransportSecurity`, `Network Persistent State`, `Trust Tokens`, `Web Data`, `Account Web Data`, plus the root `Local State`) into a 0700 temp folder named `browser-use-user-data-dir-voicelaptop-*`, so browser-use does not copy it again. Copy: under 0.1 s. Launch: 1.0 to 3.0 s. No passwords, history, tabs or extensions. Deleted in `finally`. |

What the lean-copy experiments showed:

- **Without `Web Data` the copy is signed out every time [ran, 3 of 3]**, even though the Google cookies are present. Presumably Chrome's account reconciler sees "signed in to Chrome" with no token and clears the Google web cookies. Adding `Web Data` fixed it.
- **Google sometimes refuses the first page load and accepts the next one [ran].** Separate probes: 17 of 20 signed in on the first load. The one refusal that was retried signed in on a reload 3 s later, and in another probe `myaccount.google.com` came back signed out while Calendar, loaded straight after, was signed in. Inside the executor one refusal was logged and the retry fixed it; the long sign-in check times in other runs (4.5 to 5.6 s) suggest more, but those were not logged. In a refused run all 19 `.google.com` cookies were present, so the refusal is on Google's side. A warm-up request to `www.google.com/robots.txt` first did not help (still refused 1 of 4). The fix that worked was to load Calendar, and if it lands on `accounts.google.com`, load it again (at most 3 tries).
- **The user's real Chrome stayed signed in [ran].** After all runs its `Cookies` database still had `SID`, `__Secure-1PSID` and the rest, and `__Secure-3PSIDCC` was refreshed at 19:24, after the experiments. Chrome binds Google sessions to the device (`Device Bound Sessions` exists in the profile). Copying that state to a second browser on the same Mac worked, but Google could treat it as cookie theft at any time. That is a fragile thing to build a demo on **[inferred]**.

**Recommendation at the time:** the lean copy, with no one-time setup. It is moot now.

## 2. Speed

All runs used `use_vision=False`, `max_actions_per_step=5`, `use_judge=False`, effort `low`, and a visible window. Times are wall-clock seconds for the whole `WebExecutor.run`.

**Blocking finding [ran]: `claude-sonnet-5-5` does not work with browser-use 0.13.14 as shipped.** Every step failed with `400 tool_choice: type "tool" and "any" are not supported for this model`. browser-use's `ChatAnthropic` forces a tool unless `thinking` is set, and it only knows the Fable and Mythos names need `auto`. Fix: `ChatAnthropic(thinking={"type": "between_tools"}, output_config={"effort": "low"})` for Sonnet 5.5 (thinking off, `tool_choice=auto`). Haiku 5.5 worked with `{"type": "disabled"}`.

"Open meet.new and tell me the meeting link" (one LLM step; the sign-in check runs because the goal mentions Meet):

| Model, mode | Total | LLM step | Phases (launch / sign-in check / agent / cleanup) |
|---|---|---|---|
| Sonnet 5.5, flash | 13.4, 15.0, 14.4, 13.5 | 2.7 to 3.1 | 1.2-3.0 / 2.3-5.6 / 7.3-7.9 / 0.2-0.3 |
| Sonnet 5.5, thinking fields on | 15.5 | 4.1 | 1.3 / 4.6 / 9.3 / 0.3 |
| Haiku 5.5, flash | 17.4 | 2.1 | 3.1 / 4.5 / 9.4 / 0.3 |

Every run's answer contained a meeting link, for example "The meeting link is meet.google.com/jke-gajr-rnz." It was read from the page URL by the agent and not checked separately. The agent never joined a meeting.

"Search YouTube for lo-fi music and start playing the first video result" (no sign-in check):

| Model, mode | Total | Steps | Seconds per step |
|---|---|---|---|
| Sonnet 5.5, flash | 29.3, 22.0, 19.8 | 5, 4, 3 | 4.2-7.0 (mean 4.8-5.8) |
| Haiku 5.5, flash | 17.3, 11.7 | 3, 3 | 2.7-6.0 (mean 3.2-4.5) |
| Sonnet 5.5, thinking fields on | failed after 16.4 s | 6 | 1.6-2.8; it reported "the browser stayed on a blank page" |
| Sonnet 5.5, vision on; Sonnet 5.5, effort medium | no result | | runs died while the repo was being restructured; not repeated |

What the numbers say:

- **Reading the page, not the model, dominates a step on heavy pages [ran].** YouTube results have 2,000+ indexed elements, and steps took 3 to 6 s even on Haiku, whose LLM call is about 1 to 2 s.
- **browser-use's `navigate` action sleeps a fixed 3 s** whenever a single-page app has not rendered yet ("Empty DOM detected ... waiting 3s") **[ran + source]**. It hit meet.new on every run and would hit Calendar and Gmail too. It accounts for most of the gap between "agent 7.5 s" and "LLM step 3 s".
- Overhead outside the agent: Chrome launch 1 to 3 s, sign-in check 1.7 s (or about 3 s when the first load is refused), cleanup 0.2 to 0.4 s.
- **Recommended configuration at the time:** Haiku 5.5, flash mode, vision off, effort low, with Sonnet 5.5 (`between_tools`) for anything that fails on Haiku. Expect about 12 to 30 s for a 3 to 5 step task. Two repeats per cell is not enough to separate the models reliably.

## 3. Asking the user mid-task

**[source, plus the schema checked by running]** A custom action registered with `@tools.action(...)` whose function `await`s `ctx.ask_user(question, options)` simply suspends the agent's step until the answer arrives. The registry built the expected schema (`question: str`, `options: list[str] | None`). Two caps would cut a slow speaker off and must be raised: `Agent(step_timeout=...)` (default 180 s) and the per-action timeout (`BROWSER_USE_ACTION_TIMEOUT_S`, default 180 s; the code passed `action_timeout=3600` for this action). **Not verified live:** no run in this spike reached an ambiguous question.

## 4. A hard safety backstop

**[source]** Every action the agent chooses goes through `Tools.act(action, browser_session, ...)` (called from `Agent.multi_act`). Subclassing `Tools` and overriding `act` gives one choke point the model cannot route around. The version built (`GuardedTools`):

- **Clicks:** it looks up the target with `browser_session.get_element_by_index(index)`, the same call the click itself uses, so it checks exactly the element that will be clicked. It reads the element's text, `aria-label`, `data-tooltip`, `title`, `value` and accessibility name, plus those of two parents. If any word matches (send, submit, save, delete, remove, discard, trash, pay, buy, purchase, order, checkout, book, reserve, post, publish, share, invite, confirm, transfer, subscribe, unsubscribe, upload), it awaits `ctx.confirm('Click "Save" on calendar.google.com. Filled in: Title: "..."')` first. On a no, the click is skipped and the run ends with `ActionResult(is_done=True, success=False)`.
- **Keys:** Ctrl/Cmd+Enter and Ctrl/Cmd+S are always held. A plain Enter is held unless the focused element looks like a search box, because Enter in a form field can submit it (Calendar's quick-create saves this way).
- **Uploads** are always held.
- **Closed bypasses:** the `evaluate` action (arbitrary JavaScript, which could click Send unseen) is removed, and coordinate clicks are switched off so every click names a known element. **[source]** browser-use turns coordinate clicking on by itself for `claude-sonnet-4*`, `claude-opus-4*` and `claude-fable-5*`.

Honest limits:

- The word list is a heuristic. An unlabelled icon button, a non-English label, or "Done" or "Next" on a page that commits something would pass without a question. Navigating to a URL that performs an action on load (a one-click unsubscribe link) is not checked.
- `ctx.confirm` runs the project's gate, which may judge an action safe. The gate's keyword fallback lacked "save", "book" and "checkout", so a held "Save" click could have been waved through if Jev was down.
- **Not verified:** the unit tests and the live "risky click is held" test were not written before the project changed direction. The backstop exists only as code that has never been exercised.

## 5. Stopping

**[source]** `agent.stop()` only sets a flag that is checked between steps and actions, so a step that is waiting on the LLM (2 to 6 s here) runs to its end first. Cancelling the asyncio task interrupts the pending LLM or CDP call at once, and `Agent.run`'s `finally` still awaits its event-bus shutdown (up to 3 s) and `close()`. The executor therefore owned the browser itself (`keep_alive=True`) and, in its own `finally`, ran `session.kill()` with a 5 s cap. It then killed any process whose command line contains `--user-data-dir=<our temp folder>`, which the user's Chrome never has, and deleted the copy. **[ran]** Normal-completion cleanup took 0.2 to 0.4 s, and no Chrome or temp copy was ever left behind. **Not measured:** time-to-stop after a cancel. `enable_signal_handler=False` is needed when the agent runs off the main thread.

## 6. Summary and progress lines

**[source + ran]**

- **Summary:** `history.final_result()` is the agent's `done` text. With a prompt rule ("one short plain sentence, under 25 words"), every successful run produced a speakable sentence, for example "I searched YouTube for lo-fi music and started playing the first result, a live lofi hip hop radio stream." `history.is_done()` and `history.is_successful()` tell success from failure.
- **Progress:** `register_new_step_callback(state, model_output, step)` fires after the model decides and before the actions run. Without flash mode, `model_output.next_goal` is a ready-made line. In flash mode there is no `next_goal`, so the line is built from the first action ("Opening www.youtube.com", "Clicking").
- **Timing:** `history.history[i].metadata.duration_seconds` gives seconds per step.

## Other findings worth keeping

- **Privacy [source]:** browser-use's telemetry is on by default and its `AgentTelemetryEvent` includes the task text, action history, visited URLs and final result. `ANONYMIZED_TELEMETRY=false` (which also turns off `BROWSER_USE_CLOUD_SYNC`) must be set before import.
- `use_judge=True` (the default) adds an extra LLM call after every task.
- browser-use downloads three extensions on the first launch (uBlock Origin Lite, "I still don't care about cookies", Force Background Tab) into `~/.config/browseruse/` (49 MB on this Mac, left in place).
