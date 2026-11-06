# The task runner (Tier 3): specification

This document defines the Tier 3 task runner completely enough to rebuild it in any language. It describes behaviour and guarantees, not one language's mechanics. It reflects the direction change of 5 November: there is **one screen executor** that looks at the screen and drives the real pointer and keyboard.

**The implementation is the Swift package `Packages/HFTasks`.** It provides `TaskRunner`, `RunnerTaskContext`, `TaskTools` and `ReplyJudge`, and every scenario in section 14 is a test in `Packages/HFTasks/Tests/HFTasksTests`. It implements everything here, including the items marked **[new]**. Section 16 says where the Swift version makes a choice the language-neutral wording leaves open, and why. The earlier Python prototype (`legacy_python/src/voicelaptop/tasks/`, read-only reference that cannot be run) is superseded: it predates the single executor and does not have the [new] items. Where code and document disagree, fix one of them; do not leave the gap.

---

## 1. What the runner is for

A Tier 3 task is a goal that takes many steps, such as "set up a Google Meet with Priya tomorrow at 3 and send her an invite". It runs in the background while the spoken conversation carries on. While it runs, the task can:

- pause to ask the user a question ("Priya Shah or Priya Patel?"),
- pause to get a spoken yes before anything risky ("Send the invite to Priya Shah?"),
- report what it is doing, so silence never feels broken,
- be stopped within about a second when the user says "stop".

For a user who cannot reach a keyboard, "stop" is the only brake. A cancel that is late, or that leaves the pointer moving, is the worst bug this component can have.

## 2. Words used here

| Word | Meaning |
|------|---------|
| **runner** | The component specified here. It holds at most one current task. |
| **executor** | The thing that does the work: the screen executor (Claude looks at screenshots and acts through the pointer and keyboard). It gets a **context** object and talks to the outside only through it. |
| **context** | The object the runner gives the executor: `ask_user`, `confirm`, `report`, `step`, `memory_hints`, `last_answer`. |
| **sink** | Where events go: the voice session, which turns them into speech or background context. |
| **gate** | The safety gate. Given an action description, it answers SAFE or NEEDS_CONFIRMATION. It never fails open. |
| **running time** | Time the task has spent in `running`. Time in `needs_input` is not counted. |
| **grace period** | How long a stopped executor gets to unwind before it is abandoned. Default 2 s. |

## 3. Collaborators (all injected)

| Collaborator | Required | Shape | Notes |
|--------------|----------|-------|-------|
| `executor` | yes | `run(goal, context) async -> String` (a one-sentence spoken summary) | **[new]** A single executor. The old dictionary of executors and the web-or-native chooser are gone. |
| `gate` | yes | `check(action_description) async -> Decision` (label `safe` or `needs_confirmation`) | Any label other than exactly `safe`, an error, or no answer within 3 s means "ask the user". |
| `sink` | yes | `(TaskEvent) -> Void` | See section 11 for delivery guarantees. |
| `classify_answer` | no | `(answer, question) async -> Decision` (label `yes`, `no` or `unclear`) | **[new]** Jev's reply reader. Section 7. Swift: `AnswerClassifying`. |
| `memory` | no | `hints(goal) -> String`, `learn(question, answer, goal)`, `task_ended(goal, status, summary, steps, seconds)` | Section 10. Swift: `MemoryProviding`. Learning and reflection live inside memory, so there are no separate `learn` or `reflect` callbacks. |
| `on_cancel` (halt hook) | no | `() -> Void`, must return immediately | **[new]** Freezes the real pointer and keyboard (`input.halt()`). Section 8. |
| `on_task_end` (resume hook) | no | `(task_id, status) -> Void` | **[new]** Clears the stop flag (`input.resume()`) once the hands are safe to use again. Section 8. |
| `clock` | no | `() -> seconds` (monotonic) | Injected so tests can drive time. |

Settings and their defaults:

| Setting | Default | Meaning |
|---------|---------|---------|
| `max_steps` | 25 | Successful `context.step()` calls allowed |
| `max_seconds` | 180 | Running time allowed |
| `question_timeout` | 120 s | How long one question or confirmation waits for an answer |
| `cancel_grace` | 2 s | How long a stopped executor gets to unwind before it is abandoned. It is also how long a new task waits for an old executor to end. |
| `progress_interval` | 4 s | Minimum gap between progress events from `report` |
| `tick` | 0.1 s | How often the supervisor checks limits and a cancel. This bounds how fast a cancel reaches the executor. |
| `gate_timeout` | 3 s | No gate answer in this time means "ask" |
| `classify_timeout` | 1.5 s | No classifier answer in this time means "use the word list" |
| `memory_timeout` | 1 s | No memory answer in this time means "no hints" |

## 4. Public operations

All of them can be called from any thread or task concurrently, and all of them return quickly. None of them waits for the executor. `start` returns as soon as the task is scheduled. Every result is a JSON-safe dictionary with an `ok` field.

### `start(goal)`

The goal is cleaned first (section 12).

| Situation | Result | Events |
|-----------|--------|--------|
| The goal is empty | `{"ok": false, "error": "The task needs a goal."}` | none |
| The runner has shut down | `{"ok": false, "error": "The task runner has shut down."}` | none |
| A task is `running` or `needs_input` | `{"ok": false, "status": "busy", "task_id": <current>, "goal": <current goal>, "error": "Another task is still going. Ask whether to cancel it first."}` | none |
| Otherwise | `{"ok": true, "task_id": "t<n>", "status": "running"}` | PROGRESS/running `"Starting: <goal>"` |

Task ids are `t1`, `t2` and so on, counted per runner. The previous executor may still be cleaning up after a cancel. The new task first waits for it for up to 2 × `cancel_grace`, and then starts anyway. This wait counts as running time.

### `answer(answer, task_id?)`

| Situation | Result | Effect |
|-----------|--------|--------|
| No current task, or it is not `needs_input` | `{"ok": false, "error": "No task is waiting for an answer right now.", "status": <status or "idle">}` | nothing |
| `task_id` is given and is not the current id | `{"ok": false, "task_id": <current>, "error": "That answer is for an old task. The waiting task is <current>."}` | nothing |
| The answer is empty after cleaning | `{"ok": false, "task_id": …, "error": "The answer was empty."}` | nothing |
| This question already has an answer that is still being processed | `{"ok": false, "task_id": …, "error": "I already have an answer for that question."}` | nothing |
| Otherwise | `{"ok": true, "task_id": …, "status": "running"}` | The answer is recorded and the waiting executor wakes up |

The answer is recorded and the duplicate check is made in one atomic step. So of N simultaneous answers, exactly one is accepted. The move back to `running` happens when the executor side has judged the answer (section 6). That way the resume event can say what was decided.

### `cancel(task_id?)`

| Situation | Result |
|-----------|--------|
| No live task | `{"ok": true, "status": "not_running", "task_id": <last id or null>, "summary": "There's no task running."}` |
| A live task (`running` or `needs_input`) | `{"ok": true, "task_id": …, "status": "cancelled", "summary": <cancel summary>}` |
| As above, but `task_id` names a different task | The current task is cancelled anyway, and the result also has `"note": "Task <given> was not running; stopped <current> instead."` |

A mismatched id still cancels. "Stop" must never fail on a technicality, and the user has only one task. The steps and their order are in section 8.

### `status()`

With no task ever: `{"ok": true, "status": "idle", "task_id": null, "summary": "No task has run yet."}`.

Otherwise, for the current or last task:

```
{ "ok": true, "task_id", "goal", "status", "executor", "steps",
  "seconds":  running time, 1 decimal place,
  "progress": the last 3 progress lines,
  // only while needs_input:
  "question": the text the user was asked, "options": [...],
  "waiting_for": "answer" | "confirmation",
  "action": the raw action description (confirmations only) [new],
  // only once ended:
  "summary": the final summary,
  // only if the executor would not stop:
  "stuck": true }
```

### `is_running()`

True while the current task is `running` or `needs_input`.

### `shutdown()`

1. Mark the runner closed, so later `start` calls fail.
2. If a task is live, call the halt hook, then end the task as `cancelled` with "Stopped because the assistant is shutting down."
3. Cancel all executor work and allow one grace period.
4. Stop the runner's internal workers. Deliver any queued events, waiting at most about 2 s.

Calling it twice is harmless. Calling it from inside the sink or the executor must not deadlock.

## 5. States, transitions and events

### Allowed transitions (the only ones)

| From | To | Event emitted (kind / status / text) |
|------|----|--------------------------------------|
| (new) | `running` | PROGRESS / running / `"Starting: <goal>"` |
| `running` | `needs_input` | QUESTION / needs_input / question, options **or** CONFIRMATION / needs_input / spoken question, options `["yes", "no"]` |
| `needs_input` | `running` | PROGRESS / running / resume text (section 6) |
| `running` | `done` | RESULT / done / the executor's summary |
| `running` | `failed` | RESULT / failed / failure summary |
| `running` | `cancelled` | RESULT / cancelled / cancel summary |
| `needs_input` | `failed` | RESULT / failed / summary (question timeout) |
| `needs_input` | `cancelled` | RESULT / cancelled / cancel summary |

`done`, `failed` and `cancelled` are final: no transition leaves them.

### Rules

1. **Every status change goes through one function.** It checks this table and the move is atomic. An illegal request is refused and changes nothing. That includes a second "end" after the task has already ended, such as a cancel racing a finish. So **exactly one RESULT event is emitted per task**, whoever wins the race.
2. **Every accepted transition emits exactly one event.** Events that are not transitions are also allowed: rate-limited PROGRESS from `report`, and **[new]** the single re-ask CONFIRMATION (section 7). They always carry the current status.
3. **Events reach the sink in the order the transitions happened.**
4. **When a task ends, it forgets any open question.** A late `answer` is refused.
5. **Banking running time:** on leaving `running`, the time since entering it is added to the total. On entering `running`, the start time is recorded. Running time = the banked total + (now − start) while `running`.
6. **After the supervisor exits, the task is final.** If the executor ends in a way that leaves the task live, the task ends as `failed` with "The task ended unexpectedly." An example is an executor that returns while a parallel sub-task of its own holds a question open.

### Final summaries (exact wording)

- `<so far>` is `"So far: a; b; c."`, built from the last 3 progress lines with trailing full stops removed. With no progress it is `"It had only just started."`
- **done:** the executor's returned string, cleaned and capped at 400 characters. If it is empty, `"Done."`
- **cancelled:** `"Stopped."`, then, if a confirmation was waiting, ` I did not go ahead with "<spoken question>".`, then ` <so far>`.
- **step limit:** `"I stopped because the task used all <N> of its steps without finishing. <so far>"`
- **time limit:** `"I stopped because the task took longer than <D> without finishing. <so far>"`. `<D>` is "3 minutes" for whole minutes, otherwise "<n> seconds".
- **question timeout:** `I stopped waiting for an answer to "<question>", so I ended the task. <so far>`
- **executor raised a spoken failure** (`SpeakableError(message)` in Swift): `"<message> <so far>"`
- **executor raised anything else:** `"Something went wrong and I couldn't finish the task. <so far>"`. The details go to the log only. Never speak exception text or a stack trace.
- **the executor's work was cancelled by something other than the runner:** `"The task stopped unexpectedly."`
- **an internal error in the runner:** `"Something went wrong inside the assistant, so I stopped the task."`
- **shutdown:** `"Stopped because the assistant is shutting down."`

## 6. What the executor can do (the context)

Every context operation first checks that its task is still live. **Once a task has ended, its context is revoked.** `ask_user`, `confirm` and `step` throw a cancellation error, and `report` does nothing. A stopped or abandoned executor can therefore never ask anything, never get a yes, and never count steps.

### `memory_hints: String`

This is filled in before the executor starts (section 10).

### `last_answer: String`

The user's exact words in their most recent answer. It lets an executor act on "wait, change the time to 4" after a confirmation returns false.

### `ask_user(question, options?) async -> String`

1. Clean the question (300 characters; empty becomes "What should I do?"). Keep at most 6 non-empty options of up to 80 characters each.
2. Questions are asked one at a time per task. If the executor asks two in parallel, the second waits for the first.
3. `running → needs_input` with a QUESTION event. Record when it was asked, for the question timeout.
4. Wait for `answer(...)`. If the task is cancelled meanwhile, throw a cancellation error.
5. Store the answer in `last_answer` and add (question, answer) to the task's list of exchanges.
6. `needs_input → running` with PROGRESS `"Got it: <answer>."`
7. Hand (question, answer, goal, options) to `learn` in the background (section 10).
8. Return the answer exactly as given. No judging happens here.

### `confirm(action, spoken_question?) async -> Bool` **[new signature]**

In Swift, `action` is an `HFCore.ScreenAction`: a structured description (kind, target control, app, window) built in code at the moment of the action. The gate judges the structure. Its `description` sentence, built only in HFCore, stands for `action_description` below: it is what `status()` shows as `action` and what the fallback spoken question is made from.

`action_description` is what the gate judges, for example `Click button "Send" in WhatsApp, window "Amma"`. `spoken_question` is what the user hears, for example "Send 'running late' to Amma on WhatsApp?". Calls with only the description keep working.

1. If the task is not live, throw a cancellation error.
2. Ask the gate about `action_description` (cleaned, 300 characters; an empty one becomes "Go ahead with the next step"). An error or no answer within `gate_timeout` counts as NEEDS_CONFIRMATION.
3. If the task stopped while the gate was thinking, throw a cancellation error. A safe verdict must never be returned to a stopped task.
4. **Safe:** return true at once. No event, no state change, and no delay beyond the gate's own call. This is the common path: the screen executor confirms before every click and every Return key press.
5. **Needs confirmation:** the question the user hears is `spoken_question` if given (cleaned, 300 characters). Otherwise it is built from the description: remove trailing punctuation, lower-case the first letter, and wrap it as `Is it OK to <description>?`. For example: `Is it OK to click button "Send" in WhatsApp, window "Amma"?`. Executors should pass a proper `spoken_question`; the fallback is only a safety net.
6. `running → needs_input` with CONFIRMATION, options `["yes", "no"]`. `status()` shows the raw description as `action`.
7. Wait for the answer, judge it (section 7), and resume:
   - **yes:** PROGRESS `"Going ahead."`, then return true.
   - **no:** PROGRESS `"OK, I won't do that."`, then return false.
   - **correction:** PROGRESS `"OK, I haven't done it."`, then return false. The executor reads `last_answer` to see the correction.
   - **unclear** on the first try: re-ask once (section 7). Unclear again: PROGRESS `"I didn't hear a clear yes, so I haven't done it."`, then return false.

### `report(text)`

1. Clean the text (200 characters). Ignore it if empty or if the task is not live.
2. Add it to the task's progress log (the last 12 are kept) unless it repeats the newest line.
3. If it is the same as the last line *emitted*, stop here.
4. Queue it as the pending progress line, replacing any older pending one.
5. Emit the pending line as PROGRESS/running only if the task is `running` and at least `progress_interval` has passed since the last progress emit. The first report is emitted at once.
6. The supervisor retries step 5 on every tick. So the newest held-back line goes out as soon as the interval allows, including after a question has been answered.

### `step()`

If the task is not live, throw a cancellation error. If `max_steps` steps have already been counted, mark the step limit as hit and throw `StepLimitReached`. Otherwise count one step. The supervisor ends the task on its next tick even if the executor catches the error and carries on.

## 7. Reading a spoken reply to a confirmation **[new: classifier and re-ask]**

The verdict is one of **yes**, **no**, **correction** or **unclear**. Only yes lets the action happen.

### Step 1: word list (always runs; deterministic; no network)

Lower-case the reply and turn curly apostrophes into straight ones. Split it into words of letters and apostrophes, then remove the apostrophes ("don't" becomes "dont").

1. No words at all: **unclear**.
2. The reply contains `n't`, or any word in NO = {no, nope, nah, not, never, cancel, stop, negative, nein, dont, wont, cant, isnt, didnt, doesnt, shouldnt, wouldnt, couldnt, arent, wasnt, havent, hasnt, mustnt, neednt}: **no**.
3. Any word in CORRECTION = {wait, hold, hang, change, actually, but, instead, except, unless, later, wrong, different, edit, fix}: **correction**.
4. The reply contains `?`, or any word in HESITATION = {maybe, perhaps, hmm, hm, hmmm, um, umm, uh, er, erm, unsure, what, why, who, which, how}: **unclear**.
5. It has a yes word from YES = {yes, yeah, yep, yup, yea, ya, sure, ok, okay, alright, correct, right, absolutely, definitely, affirmative, confirm, confirmed, proceed, perfect, fine, great, approve, approved, certainly}, or a yes phrase from {"go ahead", "go for it", "do it", "send it", "please do", "sounds good", "of course", "all right"}, **and** every word is in YES or FILLER: **yes**. FILLER = {please, thanks, thank, you, it, that, this, them, now, go, ahead, for, do, send, the, a, is, its, thats, all, just, sounds, good, of, course, invite, message, email, very, much, then, so, oh, well, and, book, post, submit, save, create, delete, pay, share, away, cheers, lets, let, us, really, i, am, im, thing}.
6. Anything else: **unclear**. This includes "yes, to Priya Patel": the extra words might be a correction.

A negative word always wins, so "no problem, go ahead" is not a yes. This is deliberate: a missed yes costs one repeat, but a false yes can send a message the user did not want.

(In the Python prototype, the CORRECTION and HESITATION words form one "hold" group that leads to a decline. The split, and re-asking on hesitation, are new.)

### Step 2: classifier, if one is injected

`classify_answer(answer, spoken_question)` runs with a `classify_timeout` limit. Its label is yes, no or unclear.

- If the word list said **no** or **correction**, that verdict stands and the classifier is not asked. A negative or correcting word is a veto the classifier cannot override.
- Otherwise the classifier's label is used: yes, no or unclear.
- If the classifier fails, times out or returns an unknown label, the word-list verdict is used.

Examples: "ship it" is unclear to the word list and yes to the classifier, so it proceeds. "Yes" that the classifier calls unclear is re-asked. "Wait" is a correction whatever the classifier says.

### Unclear: re-ask once, then give up (decision)

On the first **unclear** verdict, the runner asks once more and does not return false yet:

- The task **stays in `needs_input`**. There is no resume event in between, and the running-time clock stays paused.
- It emits one new CONFIRMATION/needs_input event with plainer words: `Sorry, I didn't catch that. <spoken question> Please say yes or no.`
- The answer slot reopens and the question timeout restarts.
- The second reply is judged the same way. Yes proceeds; no, correction or unclear return false, each with its resume text from section 6.

**Why re-ask?** The user may speak slowly or be misheard. Throwing away a task that took a minute to reach the Send button, over one garbled word, is a real cost. A single re-ask fixes most of these cases. Asking only once means the user is never trapped in a loop.

**Why not re-ask on no or a correction?** "No" is a clear answer. A correction carries meaning ("change the time"), so the executor should handle it, not hear "yes or no?" again.

The action still never proceeds without a clear yes.

## 8. Cancel and stopping the hands **[hooks are new]**

### What `cancel()` does, in order, all without waiting for the executor

1. **Halt the hands:** call `on_cancel()` (sets `input.halt()`) if a task is live. This happens first, so the pointer freezes mid-glide and typing stops mid-word even if the executor is slow to unwind. Errors from the hook are logged and swallowed.
2. **End the task:** move it to `cancelled`, build the cancel summary from the progress log, emit RESULT and revoke the context. From this moment `is_running()` is false and a new `start` is accepted.
3. **Return** the summary to the caller.
4. **Stop the executor**, straight after returning: cancel its task. Any question it is waiting on is also woken with a cancellation error. In Swift, cancellation is sticky: once set, every later `Task.sleep` or other cancellable wait inside the executor, including in its cleanup, ends at once. So cancelling a second time adds nothing, and the runner cancels once.
5. **Watch it for one grace period.** If it has not ended by then, **abandon it**: mark the task `stuck` (shown in `status()`) and log a warning. Its context is already revoked, so it cannot ask, confirm or count steps. The hands stay halted while it lives (below), so it cannot move the pointer either.

Steps 1 to 3 must not depend on the executor or on any shared worker the executor might block. In Swift, `cancel()` is a plain synchronous method that takes the runner's lock on the caller's thread. The runner is not an actor, and the executor runs in its own detached task. A test shows `cancel()` returning in under 0.1 s while the executor blocks its thread for 0.4 s.

### The same stop sequence is used for every forced ending

The halt hook, then the final state, then stopping the executor: this applies to the step limit, the time limit, the question timeout and shutdown. Before stopping a live executor, the runner always halts the hands first.

### `on_task_end(task_id, status)`: when the hands are released

- It is called **exactly once per task**, once three things are true: the task is final, its executor has really ended, and **no executor of any task is still alive**. For a normal `done` or `failed`, that is right after the result. For a stopped executor, it is when the executor has unwound.
- **The runner never launches a new executor while an old one is alive.** A `start` made while the old executor is still unwinding is accepted. The new task then waits up to one grace period for the old executor to end.
  - If the old executor ends in time, the hands are released and the new executor launches.
  - If it does not, it is abandoned, and the new task ends `failed` with: *"The last task hasn't stopped yet, so I can't safely start another one. If this keeps happening, restart Handsfree."*
- While an abandoned executor is alive, `start` refuses straight away with `{"ok": false, "status": "stuck", "task_id": <old id>, "error": <the same sentence>}`.
- When the abandoned executor finally ends, the held `on_task_end` calls are made and tasks work again.
- So **the hands are never released while a runaway executor lives**. This closes, inside the runner, the gap noted in an earlier draft (a runaway moving the pointer after the next task starts), with no change to the `Hands` contract. The cost is that a truly stuck executor blocks new tasks until it ends or the app restarts, and the user is told so.
- Both hooks are called while the runner holds its lock, so a new executor cannot launch before the hands are released. They must return at once, and they may call the runner's read-only methods (the lock is recursive). In Swift the hooks cannot throw.

## 9. Limits and clocks

| Limit | Checked | Outcome |
|-------|---------|---------|
| Steps | On every `step()` call | The (N+1)th call throws `StepLimitReached`. The task ends `failed` with the step-limit summary, and the executor is stopped even if it swallowed the error. `steps` reports N. |
| Running time | Every tick, only while `running` | It becomes `failed` with the time-limit summary once running time reaches `max_seconds`. |
| Question wait | Every tick, while `needs_input` with no answer yet | It becomes `failed` with the question-timeout summary once `question_timeout` passes since the question, or since the re-ask. |

**Why waiting does not count:** a user who speaks slowly must never be timed out by their own pauses. Five minutes spent deciding "Shah or Patel" uses none of the 3-minute budget. The question timeout exists so a forgotten question does not hold the runner forever. When it fires, the task ends cleanly and says so.

Time spent asking the gate and the classifier does count as running time. Both are bounded by their timeouts.

## 10. Memory (optional; must never slow down or break a task)

- **Hints:** before the executor starts, call `memory.hints(forGoal:)` with a `memory_timeout` limit. Memory formats the hints itself. If it is slow, the hints are empty and the task goes on.
- **Learning:** after each answered **question**, call `memory.learn(fromQuestion:answer:goal:)` in a detached task. Confirmations are **never** handed to learning, so memory can never teach the agent to skip asking.
- **After the task:** once it is final, call `memory.taskEnded(goal:status:summary:steps:seconds:)` in a detached task. `steps` is the progress log and `seconds` is the running time. Logging the episode and learning a recipe both happen inside memory.
- The runner never waits for learning or the task log. `MemoryProviding` never throws.

## 11. Concurrency guarantees

1. All public operations are safe to call at the same time from any thread or task. With N simultaneous `start` calls, exactly one runs and the rest get busy. With N simultaneous `answer` calls, exactly one is accepted. With N simultaneous `cancel` calls, exactly one gets `cancelled` and the rest get `not_running`. `status` and `is_running` never fail.
2. Events are delivered in transition order, through a channel that is separate from both the callers and the executor. A sink that throws is logged and the task carries on. A sink that is slow must not delay a cancel or the executor. (In Swift, a private serial dispatch queue does this; see section 16.)
3. The sink is never called synchronously inside a public operation.
4. The executor cannot change runner state except through its context. Every context operation checks liveness atomically with the change it makes.

## 12. Text cleaning

Every text that may be spoken is cleaned: any run of whitespace, including newlines, becomes one space, the ends are trimmed, and the text is capped with a trailing `…`. Caps: goal 2000, answer 500, question 300, action and spoken question 300, option 80 (at most 6), progress 200, summary 400, spoken failure message 200.

## 13. Voice tools

Every handler takes a parameter dictionary and returns a JSON-safe dictionary. A handler never throws. Any failure becomes `{"ok": false, "error": "Something went wrong with the task tool."}`, and internal details are never shown. A non-dictionary parameter value is treated as `{}`. Tier 3, and the default tool timeout (20 s) is fine, because every handler returns at once. Descriptions have been updated for the direction change, so the Python prototype's text mentions app shortcuts that no longer exist.

### `start_task`

Parameters: `{"type":"object","properties":{"goal":{"type":"string","description":"A complete, self-contained instruction with every detail the user gave."}},"required":["goal"]}`

If `goal` is missing, not a string, or blank, the result is `{"ok": false, "error": "I need a goal to start a task."}` without calling the runner. Otherwise it returns `runner.start(goal)`.

Description:

> Start a background task on the user's Mac for anything the quick tools cannot do: multi-step work on the screen, such as creating a calendar event with a Meet link and inviting someone, writing and sending a message in an app, or finding and filling in a form. The user will see the pointer move and the keys land while it works. Do not use it for things a quick tool can do (volume, media keys, scrolling, opening an app). The goal must be one complete, self-contained instruction that includes every detail the user gave: who, what, when, which app or site, and the exact words of any message. The task cannot see this conversation, so never write 'as discussed' or 'what I said'. The tool returns at once with a task_id and status 'running': that only means the task has started. Never tell the user a task is finished, sent or done until a result for it arrives. While it runs you will be told its progress, and it may ask a question or ask for confirmation; say each one to the user and pass their reply to answer_task. Only one task runs at a time: if the status is 'busy', tell the user what is still running and ask whether to cancel it.

### `answer_task`

Parameters: `{"type":"object","properties":{"answer":{"type":"string","description":"The user's reply."},"task_id":{"type":"string","description":"The task_id, if known. Optional."}},"required":["answer"]}`

If `answer` is missing, not a string, or blank, the result is `{"ok": false, "error": "I need the user's answer to pass on."}`. A blank or non-string `task_id` is treated as absent. Otherwise it returns `runner.answer(answer, task_id)`.

Description:

> Pass the user's reply to the question or confirmation the running task just asked, such as 'Priya Shah or Priya Patel?' or 'Send the invite to Priya Shah?'. Use it only when a task is waiting for an answer. For a question you may expand a short reply to the option it clearly means ('Shah' becomes 'Priya Shah'). For a confirmation, pass the user's own words exactly as they said them: never answer yes on the user's behalf, and never turn a hesitant or changed reply ('wait, change the time') into a yes. After answering, the task carries on; it is not finished until a result arrives.

### `cancel_task`

Parameters: `{"type":"object","properties":{"task_id":{"type":"string","description":"The task_id, if known. Optional."}}}`. It returns `runner.cancel(task_id)`.

Description:

> Stop the running background task at once. Use it when the user says stop, cancel, never mind or wait while a task is running, or agrees to cancel a task to start a new one. It returns a short summary of what had been done; tell the user it has stopped and what was done. Do not use it to stop music or close an app.

### `task_status`

Parameters: `{"type":"object","properties":{}}`. It returns `runner.status()`.

Description:

> Check the current or most recent background task: whether it is running, waiting for an answer (with the question), or finished (with its summary). Use it when the user asks how a task is going, or when you are not sure whether a task is waiting for an answer. Do not call it over and over while a task runs; progress is reported to you as it happens.

## 14. Test scenarios

Notation: `P` is PROGRESS, `Q` is QUESTION, `C` is CONFIRMATION, `R` is RESULT. The status is after the slash. Unless stated otherwise, tests use `tick` = 0.01 s, `cancel_grace` = 0.1 s and `progress_interval` = 0. The gate fake says NEEDS_CONFIRMATION for any action containing send, delete or pay, and SAFE otherwise. "Within 1 s" is measured in real time. Every other timed limit is driven by a fake clock. Scenarios marked **[new]** were not written in Python.

### Main flow

1. **The full BUILD_PLAN 4b flow.** The executor reports "Opening Google Calendar", steps, asks "Priya Shah or Priya Patel?" with those two options, steps, then confirms "Send the invite to <who> for tomorrow at 3pm".
   - Actions: `start(goal)` returns `{ok, t1, running}`. Answer "Priya Shah" with id t1. Answer "yes".
   - Events, exactly: `P/running "Starting: …"`, `P/running "Opening Google Calendar"`, `Q/needs_input (options Shah, Patel)`, `P/running "Got it: Priya Shah."`, `C/needs_input (options yes, no)`, `P/running "Going ahead."`, `R/done "Sent the invite to Priya Shah."`.
   - Final status is done with steps = 2. Every event arrived on the delivery channel, not the caller's thread.
2. **Simple task.** The executor reports, steps and returns "Meeting started.". Result: `R/done "Meeting started."`.
3. **Empty goal.** `start("   ")` returns `ok: false`.

### One task at a time

4. **Busy while running.** A second `start` returns busy, with t1 and the first goal. After `cancel()`, the next `start` returns t2.
5. **Busy while waiting for input.** The task is waiting on a question; `start` returns busy.

### Cancel

6. **Cancel while running.** The executor reports "Opening Chrome" and then loops forever, with cleanup in `finally`.
   - `cancel()` returns in under 0.2 s with `{ok, t1, cancelled}`, and the summary contains "Opening Chrome". `is_running()` is false at once.
   - `R/cancelled` arrives within 1 s, and the executor's cleanup has run within 1 s.
7. **Cancel while waiting for an answer.** Cleanup runs within 1 s and the result is `R/cancelled`. A later `answer("work")` returns ok false, and the executor never receives the answer.
8. **Cancel during a confirmation.** The summary contains `did not go ahead`. The executor never sends and `confirm` never returns.
9. **Cancel with nothing running.** It returns `{ok: true, status: not_running}`.
10. **Cancel with a stale id.** `cancel("t99")` cancels t1 and includes a `note`.
11. **Cancel racing a finish.** Twenty times, start an instant-finishing task and cancel at once. There is exactly one RESULT each time.
12. **An executor that ignores cancellation.** It swallows every cancellation, and after the first one it tries `confirm("Send the message to everyone")`.
    - `cancel()` returns in under 0.2 s.
    - Within 1 s, `status().stuck` is true.
    - The late confirm is refused with a cancellation error; zero C events are emitted and the gate was never called.
    - A new task can then start and finish as done.
13. **Cleanup that waits.** After cancellation the executor's cleanup awaits a 100 s cancellable sleep. Because cancellation is sticky, the cleanup ends within 1 s, and the task is not marked stuck.
14. **An executor that blocks the runner's worker.** It blocks synchronously for 0.4 s. `cancel()` still returns in under 0.1 s with cancelled, and the late return value is ignored: exactly one `R/cancelled`.
15. **[new] The halt hook comes first.** In the hook, record `is_running()`, the number of RESULT events, and whether the executor has seen cancellation.
    - The hook is called exactly once, before the RESULT event and before the executor sees cancellation.
    - A hook that throws does not stop the cancel.
    - Cancelling with nothing running does not call the hook.
16. **[new] The resume hook.**
    - A done task calls `on_task_end(t1, done)` once, after the RESULT.
    - A cancelled task calls it once, after the executor's `finally` has run.
    - For an abandoned executor it is not called until that executor finally ends. Meanwhile `start` is refused with `stuck`.
    - A hook that throws is ignored. (Not applicable in Swift: hooks cannot throw.)
16b. **A runaway blocks the next task.** Task 1 won't stop. Task 2 is started in the grace period: it is accepted, its executor never runs, and it ends `R/failed` with the stuck sentence. No `on_task_end` call is made until task 1's executor ends; then both are made.
17. **[new] Limits and shutdown halt too.** The step limit, time limit, question timeout and shutdown each call the halt hook once before the executor sees cancellation.

### Confirmations and reply reading

18. **Word list table.**
    - yes: "yes", "Yes.", "yeah go for it", "send it", "ok send the invite", "sure".
    - no: "no", "nope", "don't", "dont send it", "no problem, go ahead".
    - correction: "wait, change the time", "yes but change the time".
    - unclear: "send it?", "hmm", "maybe", "yes, to Priya Patel", "the blue one", "".
    - (Python returns "hold" for both the correction and hesitation groups.)
19. **Declined.** In the 4b flow, answer "no". You see `P/running "OK, I won't do that."`, then `R/done "I didn't send the invite."`, and nothing is sent.
20. **Correction.** The reply "wait, change the time to 4" returns false with no re-ask, and `last_answer` equals that reply.
21. **[new] Unclear, then yes.** The reply "hmm" leads to one more `C/needs_input "Sorry, I didn't catch that. <q> Please say yes or no."`, with no P event in between and the status still needs_input. Answering "yes" gives `P "Going ahead."` and confirm returns true.
22. **[new] Unclear twice.** "hmm", then "the blue one": `P "I didn't hear a clear yes, so I haven't done it."`, confirm returns false, and there is no third C event.
23. **[new] The re-ask does not use the clock.** With a fake clock and `max_seconds` = 10, advance the clock by 500 s across the first ask and the re-ask; the task is still waiting. The question timeout restarts at the re-ask.
24. **Safe action.** "Open the settings page" returns true, with zero C events and no state change.
25. **The gate fails.** A gate that throws leads to a C event; "yes" returns true.
26. **[new] Spoken wording.** `confirm('Click button "Send" in WhatsApp, window "Amma"', "Send 'running late' to Amma?")`: the gate sees the description and the C event says "Send 'running late' to Amma?". Without the second argument, the C text is `Is it OK to click button "Send" in WhatsApp, window "Amma"?`.
27. **Classifier.**
    - A classifier that says yes (0.97) turns "ship it mate" into true, while "no" and "wait" stay false.
    - A classifier that says unclear on "yes" leads to a re-ask **[new]**. (In Python this returned false.)
    - A classifier that throws means the word list is used, so "yes" returns true.
    - **[new]** A classifier that returns an unknown label means the word list is used.

### Answers at the wrong time

28. **Nothing waiting.** `answer` with no task, or while running without a question, returns ok false and the status is unchanged.
29. **Wrong task id.** It returns ok false with the current id, and the task is still waiting. The right id is then accepted.
30. **A second answer to the same question.** With both answers held so they land before the resume, the first is accepted and the second refused. The executor gets the first.

### Limits

31. **Step limit.** With `max_steps` = 5, the executor steps in a loop: `R/failed` containing "5", steps = 5, and cleanup ran.
32. **Step limit swallowed.** With `max_steps` = 3, the executor catches `StepLimitReached` and keeps going. It still ends failed and is stopped, with steps = 3.
33. **Time limit ignores waiting.** Fake clock, `max_seconds` = 10, question timeout very large. The executor asks, then loops.
    - Advance 500 s while it waits: still needs_input.
    - Answer, then advance 5 s: still running, with `seconds` ≈ 5.
    - Advance 6 s more: `R/failed` containing "longer than 10 seconds" and "Opening Chrome", and cleanup ran.
34. **Question timeout.** Fake clock, question timeout 120. After 119 s the task is still live; after 121 s you get `R/failed` containing "stopped waiting for an answer", and cleanup ran.

### Failures and broken collaborators

35. **Executor throws an ordinary error.** For example KeyError("selector #btn-42 not found"): `R/failed` containing "couldn't finish" and "Opening Chrome", and none of "KeyError", "selector", "Traceback" or a newline.
36. **Spoken failure.** `SpeakableError("Chrome isn't installed.")` gives "Chrome isn't installed. It had only just started."
37. **A sink that throws on every event.** The full 4b flow still completes as done, and the last event delivered is RESULT.
38. **A slow sink** (blocks 2 s per event). Cancel still reaches the executor's cleanup within 1 s.

### Progress

39. **Rate limit.** With a fake clock, a 4 s interval and 50 quick reports:
    - Only "step 0" is emitted (besides "Starting").
    - After advancing 4 s, "step 49" is emitted, for 3 PROGRESS events in total.
    - The cancel summary contains "step 47; step 48; step 49", and `status().progress` equals those 3 lines.

### Memory

40. **Hints, learning and reflection.** Memory returns the fact alias/priya/Priya Shah/calendar.
    - The hints equal `- alias priya: Priya Shah (in calendar)`.
    - `learn` is called once, with ("Priya Shah or Priya Patel?", "Priya Shah", goal, [Shah, Patel]); it is not called for the confirmation.
    - The episode is logged as (goal, executor, "done", …, 2 steps).
    - `reflect` is called once, with (goal, "done", summary, executor, ["Opening Google Calendar"]).
41. **Broken or slow memory.** Memory that throws, or that takes 1 s with a 0.1 s limit, plus a `learn` and `reflect` that throw: the task is still done in under 0.8 s.

### Threads and shutdown

42. **Many callers at once.**
    - 12 simultaneous `start` calls: 1 running and 11 busy.
    - 12 simultaneous `answer` calls, with 4 threads hammering `status` and `is_running`: 1 accepted, no errors.
    - 12 simultaneous `cancel` calls: 1 cancelled and 11 not_running, with exactly one RESULT.
43. **Shutdown with a task running.** It returns in under 1.5 s, cleanup ran, and you get `R/cancelled` containing "shutting down". The internal workers have stopped, `start` afterwards returns ok false, and a second shutdown is harmless.
44. **Shutdown with a stubborn executor.** It returns in under 3 s with `R/cancelled`.

### Voice tools

45. **The four tools exist.** Names start_task, answer_task, cancel_task and task_status, all tier 3, with object schemas, `required` as specified, and descriptions longer than 80 characters.
46. **Descriptions carry the rules.** start_task mentions quick tools, "self-contained", "every detail", "never tell the user a task is finished" and "busy". answer_task contains "never answer yes on the user's behalf". cancel_task mentions stop.
47. **Handlers pass through.** Calls with goal; with answer + task_id; with answer only (task_id is absent); cancel with {}; status with {}. Each call is passed to the runner exactly as given.
48. **Bad parameters.** A missing, empty or non-string goal, or a missing or blank answer, returns ok false without calling the runner.
49. **Handlers never throw.** A runner that throws gives ok false without its internal message. A `null` parameter value still returns a dictionary.
50. **A real runner through the tools.** Start; a second start gives busy; status shows needs_input; answer; answer "yes"; status shows the summary; cancel gives not_running; answer gives ok false. Every result serialises as JSON.

## 15. Open questions and risks

- **An abandoned executor can still act outside its context and the hands,** for example by making a network call. The revoked context and the halted hands cover confirmations, the pointer and the keyboard.
- **A truly stuck executor blocks new tasks** until it ends or Handsfree restarts. This is the price of never releasing the hands while it lives (section 8). The user hears why.
- **Hands are frozen only as reliably as the screen agent uses them.** The halt flag works only because every pointer and key action goes through `Hands`, which checks it. An executor that posted events by another route would escape it.
- **The strict yes rule will sometimes refuse a real yes.** Examples are a bare "Send." or "sure, why not". The classifier and the single re-ask reduce this, but do not remove it.
- **Rate limiting drops intermediate progress lines.** They are only kept for the cancel summary.
- **Cancel speed depends on the tick** (0.1 s), and the hands freeze only as fast as the halt hook's flag is checked.
- **Behaviour against the real screen executor and a live voice conversation is untested.** Every scenario above uses fakes.

## 16. Swift implementation notes

| File | What it holds |
|------|---------------|
| `Sources/HFTasks/TaskRunner.swift` | `TaskRunning` (the protocol the tools use), `TaskRunner` with its `Configuration`, the public operations, the transition table, `finish`, the hooks, event delivery and activity posts |
| `Sources/HFTasks/TaskRunner+Supervision.swift` | Waiting for an old executor, launching the executor in a detached task, the limit and grace watch, and settling the outcome |
| `Sources/HFTasks/TaskRunner+Context.swift` | `RunnerTaskContext` and the context operations: ask, confirm (with the re-ask), report, step, and judging a reply |
| `Sources/HFTasks/TaskRecord.swift` | The per-task state, touched only while holding the lock |
| `Sources/HFTasks/ReplyJudge.swift` | The word list of section 7, as `ReplyJudge.wordList(_:) -> ReplyVerdict` |
| `Sources/HFTasks/SpokenText.swift` | Text cleaning, the "So far" sentence, durations and the fallback question |
| `Sources/HFTasks/Timeout.swift` | `valueWithin(seconds:_:)`, which returns on time even if the operation ignores cancellation |
| `Sources/HFTasks/TaskTools.swift` | `TaskTools.make(runner:) -> [ToolSpec]` and the four descriptions of section 13 |

Where the Swift version makes a choice, and why:

- **A lock-guarded class, not an actor.** Every public operation is synchronous and safe from any thread. It uses one `NSRecursiveLock` (recursive so a hook or the sink may read `status()` without deadlocking). An actor would make `cancel()` wait its turn behind other actor work. Here it runs at once on the caller's thread.
- **The executor runs in `Task.detached`.** It never runs on a shared actor, so an executor that blocks its thread delays nothing but itself.
- **Events go to the sink on a private serial `DispatchQueue`,** queued while holding the lock, so their order matches the transitions. That queue is outside the Swift cooperative thread pool. The sink cannot throw (`TaskEventSink` returns `Void`), so scenario 37 tests a sink that calls back into the runner instead.
- **Activity bus:** `start` posts `.taskStarted`. Every emitted progress line posts `.progress`, except the "Starting:" line. A QUESTION event posts `.waitingForAnswer`, a CONFIRMATION event (including a re-ask) posts `.heldForConfirmation(action: <spoken question>)`, and a RESULT event posts `.taskEnded`. Every halt posts `.halted`, which is always before `.taskEnded`.
- **`isAwaitingAnswer`** is true while the task is `needs_input` and the question has not been answered yet. The stop watcher uses it, so that a bare "no" is read as an answer.
- **Executor failures:** `SpeakableError` takes the place of `TaskFailed`, and its message is spoken. A `CancellationError` or `Halted` the runner did not cause gives "The task stopped unexpectedly."
- **Asking two things at once:** if the executor asks a second question while one is open, the second call throws `SpeakableError("The task tried to ask two things at once.")` instead of waiting. The screen agent is sequential, so this only catches a programming mistake.
- **The classifier has no "unknown label"** (`Answer` is an enum). A classifier that is slower than `classify_timeout` leaves the word-list verdict in place.
- **`lastAnswer`** is on `RunnerTaskContext`, not on the `TaskContext` protocol. See the contract request below.
- **`shutdown()`** blocks its caller for up to one grace period while the executor unwinds. It then waits up to 2 s for queued events to be delivered, unless it was called from the delivery queue itself.
- **Grace periods use real time** (`ContinuousClock`). The limits, the question timeout and the progress interval use the injected clock, so tests can drive them.

Scenario changes in Swift:

- **12:** cancelling twice is meaningless in Swift, so this tests one cancel, abandonment after one grace period, the revoked context, a refused `start` (`stuck`) while the runaway lives, and normal tasks once it ends.
- **13:** cleanup that awaits a cancellable operation ends at once, because cancellation is sticky.
- **15 and 16:** hooks cannot throw, so the "hook that throws" cases do not apply.
- **16b (added):** a task started while an old executor is unwinding never launches its executor, ends `failed` with the stuck sentence, and holds the hands until the old one ends.
- **17:** the step-limit case uses an executor that swallows `StepLimitReached`. An executor that lets it propagate ends by itself, and there is nothing to halt.
- **27:** the unknown-label case is replaced by a classifier slower than its timeout.
- **37:** a sink that calls back into the runner, instead of a sink that throws.
- **Added:** `isAwaitingAnswer`, `.halted` before `.taskEnded` on the activity bus, and two questions at once.

**Contract request to the lead:** add `var lastAnswer: String { get }` to `HFCore.TaskContext`. Then the screen agent can read a correction ("wait, change the time to 4") without casting to `RunnerTaskContext`.
