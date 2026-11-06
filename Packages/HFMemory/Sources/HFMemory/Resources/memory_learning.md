# Memory learning prompts

Loaded as data by the memory module. Each prompt has a **system** text, a **user** template (with `{placeholders}`), and an **output schema**. The schema is sent as structured output, so the reply is always JSON that matches it. See `docs/MEMORY.md` Part B section 8 for when each prompt is used and how its output is checked.

Call settings for both Claude prompts:

| Setting | Value |
|---------|-------|
| model | `settings.small_model` (currently `claude-haiku-5-5`) |
| max_tokens | 2000 |
| effort | `low` (inside `output_config`) |
| output | `output_config.format = {"type": "json_schema", "schema": <schema below>}` |
| timeout | 30 s, 1 retry |
| accept | only `stop_reason == "end_turn"`, with the first text block parsed as a JSON object; anything else counts as "no answer" |

Text between the `=== system ===` and `=== end ===` markers is used exactly as written, line breaks included. The Swift package `HFMemory` reads this file at runtime (a copy is bundled as a resource): the text between the markers, and the first ```` ```json ```` block under each "Output schema" heading. Keep those markers and headings when editing.

---

## 1. Exchange: is this answer a lasting preference?

### System

=== system ===
You help a voice assistant for a person who cannot use their hands. Every question the assistant asks costs the user effort, so it should not ask the same thing twice. During a task the assistant asked the user a question and got an answer. Decide whether the answer reveals a LASTING preference that will apply to future requests, or a ONE-OFF choice for this task only.

Lasting (worth remembering):
- which real person or contact a name means ("Priya" -> "Priya Shah") -> kind "alias"
- a standing choice: which account, app, browser, device, calendar -> kind "preference"
- how the user likes the assistant to behave (speech speed, shorter replies) -> kind "style"
- what a named routine means -> kind "routine"

One-off (do NOT remember): times, dates, durations, which file or email or message this time, the wording of any message, yes/no answers, anything that depends on the situation. When unsure, it is a one-off.

Never remember: passwords, codes, PINs, card or bank details, addresses of other people, health details, or anything that would let the assistant skip asking before it sends, pays, deletes, posts or submits. If the answer is any of these, lasting is false.

Fields:
- key: the words the user would say next time (the name or thing being resolved), e.g. "Priya", "google account", "music app". Never the answer itself.
- value: the full resolved choice, using the option's exact text when options are given.
- scope: the app it only applies to, lower case ("whatsapp"), or "" if it applies everywhere.
- If lasting is false, set kind "none" and key, value and scope to "".

Examples:
Q "Which account should I use, personal or work?" A "work, it's always work" -> lasting, preference, key "google account", value "work".
Q "I found two Priyas. Priya Shah or Priya Patel?" A "Shah" -> lasting, alias, key "Priya", value "Priya Shah".
Q "What time should the meeting start?" A "3pm" -> one-off.
Q "Which of these three files?" A "the budget one" -> one-off.
Q "Should I read messages back in full or just summarise?" A "always in full" -> lasting, style, key "message read-back", value "in full".
=== end ===

### User template

Lines in square brackets appear only when they apply. `{goal_redacted}` is the goal with message wording replaced by `[message]` (MEMORY.md section 5.4).

```
The user's goal: {goal_redacted}
The assistant asked: {question}
[Options offered: {options_as_json_array}]
The user answered: {answer}
```

### Output schema

```json
{
  "type": "object",
  "properties": {
    "lasting": {"type": "boolean"},
    "kind": {"type": "string", "enum": ["alias", "preference", "style", "routine", "note", "none"]},
    "key": {"type": "string"},
    "value": {"type": "string"},
    "scope": {"type": "string"},
    "reason": {"type": "string"}
  },
  "required": ["lasting", "kind", "key", "value", "scope", "reason"],
  "additionalProperties": false
}
```

---

## 2. Reflect: what did this task teach about operating the Mac?

Used after a task ends as `done` or `failed`, never after `cancelled`. Updated for the screen agent: on success it writes or improves a recipe, and on failure it notes what went wrong.

### System

=== system ===
You help a screen agent that operates a Mac the way a person does: it looks at the screen, moves the pointer, clicks and types. Every step takes several seconds, so a short RECIPE that sends it straight to the right place next time saves the user a lot of waiting. A task has just ended. You are given the user's goal, whether it succeeded, the steps the agent took, and any recipes it was given as advice.

If the task SUCCEEDED, write a recipe for this kind of task:
- task: a short generic name for the kind of task, lower case, under 10 words, with no personal names or message text, e.g. "send a whatsapp message", "start an instant google meet". If one of the existing recipe names describes the same kind of task, reuse that name exactly.
- app: the app the steps happen in, lower case: "chrome" for anything done in a website, otherwise the Mac app ("whatsapp", "spotify", "notes").
- how: two to four short sentences, under 300 characters, saying where to go and what to click or press, in order, as advice to check on screen. Include the shortcut or route that worked, and leave out detours and mistakes. Generic: never include the wording of a message or email, names of people, passwords, codes or anything private. If a step sends, pays, deletes, posts, invites or submits, write it as "only after the user confirms" (never as a step to just do).
- save_recipe false if the task was trivial (one obvious step), if the given recipe already describes what worked, or if nothing reusable was learned.

If the task FAILED, fill pitfall: one short sentence of at most 15 words (under 120 characters) saying what did not work and what to try instead; lead with what to try, e.g. "Click the search field under the chat list title; Cmd+F did nothing." Generic and private-free, as above. Leave pitfall "" if the failure had nothing to do with how the app was operated (for example the user said no, or the network was down). If the agent was given no recipe ("Recipes the agent was given: []"), you may also fill task, app and how with the route that got furthest plus what to try next, and set save_recipe true; it is kept only as an unconfirmed suggestion. Otherwise set save_recipe false.

Preferences: only ones the user stated as standing in their goal ("always", "usually", "by default", "from now on", "I prefer"). A choice made for this task only is not a preference. Never include anything that lets the assistant skip asking before it sends, pays, deletes, posts or submits. Usually this list is empty.
=== end ===

### User template

```
Goal (the user's words): {goal_redacted}
Outcome: {"succeeded" | "failed"}
Result: {summary_redacted}
Steps taken:
{steps: one "- " line each, the last 20, each cut to 200 characters; or "(not recorded)"}
Recipes the agent was given: {given_recipes_as_json_array_of {"task","how"} or "[]"}
Existing recipe names: {existing_recipe_task_names_as_json_array, at most 40}
```

### Output schema

```json
{
  "type": "object",
  "properties": {
    "save_recipe": {"type": "boolean"},
    "task": {"type": "string"},
    "app": {"type": "string"},
    "how": {"type": "string"},
    "pitfall": {"type": "string"},
    "preferences": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind": {"type": "string", "enum": ["alias", "preference", "style", "routine", "note"]},
          "key": {"type": "string"},
          "value": {"type": "string"},
          "scope": {"type": "string"}
        },
        "required": ["kind", "key", "value", "scope"],
        "additionalProperties": false
      }
    }
  },
  "required": ["save_recipe", "task", "app", "how", "pitfall", "preferences"],
  "additionalProperties": false
}
```

Changes from the Python prototype, so they can be tested again: the `app` and `pitfall` fields and the "Recipes the agent was given" line are new, and the prompt now also runs after failures (where, if no recipe was given, it may suggest a route that is kept only as a candidate). The prototype's prompt (success only, `task`/`how`/`preferences`) passed the live tests on 5 Nov. The new wording has not been run yet.

---

## 3. Jev gate: is this obviously a one-off? (optional)

Sent before prompt 1 only when Jev is available. It is a single `noul` question. A probability below **0.15** means "clearly one-off" and skips the Claude call. Any error, timeout or missing answer means "not sure", and prompt 1 runs.

State:

```json
{"task": "{goal}", "assistant_asked": "{question}", "user_answered": "{answer}"}
```

Question id `lasting`:

```json
{
  "type": "noul",
  "instructions": "Does the user's answer reveal a lasting personal preference that would apply to future requests too (which person a name means, which account or app they use, how they like the assistant to behave), rather than a choice that only matters for this one task (a time, a date, a file, message wording, yes/no)?"
}
```

Measured on 5 Nov: the answer "3pm" gave p = 0.05, in 201 ms.
