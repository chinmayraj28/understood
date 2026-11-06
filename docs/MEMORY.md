# Memory: how the agent learns the user's preferences and how to use their Mac

This document is the complete, language-neutral specification of the memory module. Part A explains the design in plain words. Part B is precise enough to reimplement it in any language. The data the app loads lives in its own files:

| File | What it holds |
|------|---------------|
| `Fixtures/recipes.json` | Built-in starter recipes (how to do common tasks on this Mac) |
| `Fixtures/memory_tools.json` | The six voice tools: names, descriptions, parameter schemas |
| `docs/prompts/memory_learning.md` | The learning prompts, their call settings and output schemas |
| `Fixtures/memory_cases.jsonl` | Labelled test cases shared by every implementation (section 13) |

The Swift implementation is the package `Packages/HFMemory` (section 15). A Python prototype of everything except the recipe changes of 5 Nov evening is kept for reference in `legacy_python/src/voicelaptop/memory/`; it passed 137 unit tests and 16 live tests before it was retired. Where this spec differs from the prototype, it says **(new)**.

---

# Part A: the design in plain words

## A1. Why it exists

The user can only speak to the computer, and every question the agent asks costs them effort. Voice fatigue is real. The first time, the agent asks "Priya Shah or Priya Patel?"; by the third time it should not need to. The opposite risk matters just as much: a wrong memory acted on silently is worse than a question. So memory learns slowly, can show its working, and can always be corrected or wiped by voice.

Memory also makes the screen agent faster. The agent operates the Mac like a person (it looks at the screen, moves the pointer, clicks and types), and each step takes several seconds. A short **recipe** ("to message someone on WhatsApp: open it with Spotlight, click the search field, type the name...") lets it go straight to the right place instead of exploring. Saving three or four exploratory steps is the difference between a task that feels usable and one that does not.

## A2. What is remembered

Each memory is a **fact**: a kind, a key (the words the user says), a value, and optionally the app it applies to (its *scope*).

| Kind | Example | Who uses it |
|------|---------|-------------|
| alias | "Mum" means Amma (on WhatsApp) | screen agent hints, voice agent |
| preference | google account: work; music app: Spotify | screen agent hints, voice agent |
| style | confirmations: brief; speech speed: slower | voice agent only |
| routine | "morning routine" means open mail, calendar and the news | both |
| recipe | how to send a WhatsApp message (steps) | screen agent only |
| note | anything else the user asks to keep | both |

Keys are normalised, so "Mum", "mum", "my mum" and "Mum's" all find the same fact.

There is also an **episode log**, one row per finished task, so the agent can answer "what did you just do?". Message wording is replaced by `[message]` before it is saved.

## A3. How a fact becomes trusted

- **Told explicitly → trusted at once.** "Remember that Mum is Amma on WhatsApp" is stored as ACTIVE.
- **Inferred → candidate first.** Something learned from an answer starts as a CANDIDATE. It is never applied silently.
- **A candidate is offered as a check.** Next time, the screen agent is told *Last time "Priya" meant Priya Shah (not yet confirmed: ask "Priya Shah, like last time?")*. So one answer already helps: the agent asks a yes-or-no question instead of an open one, which is less effort for someone who can only speak, and nothing is assumed without the user's say.
- **A yes, or the same answer again → trusted.** A yes to that check, or the same answer to the open question, makes it ACTIVE. A no retires it, and the agent asks the open question instead.
- **Explicit beats learned.** A learned value never overrides something the user said explicitly.
- **One live fact per key.** A new value retires the old one instead of deleting it, so there is an audit trail.
- **Use raises trust, a correction lowers it.** Too many corrections demote a fact back to candidate, then retire it.

## A4. Recipes

A recipe is advice about operating an app, for example: *"Open WhatsApp with Spotlight. Click the search field above the chat list, type the name, click the matching chat and check the name in the header. Click the message box and type the message. Return sends, so press it only after the user confirms."* The screen agent still checks every step on screen. Every click on Send, and every Return that would send, still goes through the safety gate.

- **Built-in recipes** ship in `Fixtures/recipes.json` for the demo tasks and common needs: WhatsApp message, Calendar event with Meet and guest, instant Meet, YouTube, Spotify, Gmail reply, Apple Notes, and web look-up. They are marked built in, are not removed by "forget", and come back if memory is wiped.
- **Learned recipes** come from experience. After a task succeeds, a short reflection writes the route that worked. If an existing recipe already says it, nothing new is stored. Otherwise a learned recipe is stored, or an earlier learned one is improved. After a task fails with no recipe, the reflection may leave a candidate recipe holding the route that got furthest and a pitfall, so even a failure teaches something; it is offered as "not yet confirmed; check it" and a failure never promotes it.
- **Outcomes adjust trust.** A recipe that was given to the agent and the task succeeded gains confidence. If the task failed, it loses confidence, and the reflection can attach a short **pitfall** ("Cmd+F did nothing; click the search field instead"). A learned recipe that keeps failing is retired. A built-in one is never retired, but is flagged for checking.
- **Retrieval stays short.** For each goal, memory picks at most two recipes (the second only for a different app) plus the few names and preferences that matter. The block is capped at about 700 characters, because the screen agent reads it on every step.

## A5. How learning decides what to keep

After a task asks the user something, learning decides in the background whether the answer is a lasting preference. It never slows or breaks a task: every failure is logged and swallowed. The layers, cheapest first:

1. **Hard rules, no model.** It never learns from a yes/no answer, a permission question ("Send it?"), a risky pick ("post it or save a draft?" → "post"), a question about message wording, or anything that looks like a secret.
2. **A rule for name choices.** "Priya Shah or Priya Patel?" answered "Shah" teaches `priya → Priya Shah` without a model.
3. **Claude for the rest,** with structured output, so the answer is a typed object. If Jev is available it first answers "is this lasting?" in about 200 ms, and clear one-offs skip Claude.
4. **A second check in code.** The model may only propose words that were actually said, never message text, and never anything the hard rules refuse.

## A6. What is never stored

- **Secrets:** passwords, PINs, one-time codes, card numbers, sort codes, IBANs, bank details, API keys and tokens.
- **Permission to skip a confirmation:** "confirmations off", "don't ask before sending", "auto-send", "just send it". The safety gate never reads memory. A remembered alias is still read back in the confirmation ("Send to Amma?").
- **Message content:** only the preference behind it (who "Mum" is), never what was said to her.

These rules apply to explicit "remember" requests, to learned facts, to recipes and to the built-in recipe file. Task text that is not a fact (the goal, the summary and the steps of a finished task) is also cleaned before it is written to the episode log or sent to a model: message wording becomes `[message]`, and any clause that looks like a secret becomes `[private]`. "Type my PIN 4821 into the bank app" is logged as `[private]`, and a code named in one place ("the verification code 482913") is also removed where it appears on its own ("Typed 482913").

## A7. Correcting and deleting by voice

| The user says | Tool | Effect |
|---------------|------|--------|
| "Remember that Mum is Amma on WhatsApp" | `remember` | Trusted at once; says what it replaced, if anything |
| "What do you know about me?" / "Who is Mum?" | `recall` | Up to five facts, spoken, plus how many are still unconfirmed |
| "No, I meant the other Priya" | `correct_memory` | Lowers trust in the fact just used, and uses the right value now |
| "Forget what I said about Priya" | `forget` | Retired, with the value and evidence wiped from disk; episodes that mention Priya are deleted |
| "Forget everything" | `forget_everything` | Asks first; the wipe needs a second call at least 2 seconds and at most 2 minutes later; built-in recipes are restored |
| "What did you just do?" | `recent_tasks` | The last few episodes, with message wording redacted |

## A8. Worked example: Priya

1. **First time.** "Set up a Google Meet with Priya tomorrow at 3." Memory hands the screen agent the Calendar recipe. In Calendar the agent finds two Priyas and asks "Priya Shah or Priya Patel?"; the user says "Shah". The task passed the options it offered, so the name-choice rule stores `alias priya → Priya Shah` as a CANDIDATE (0.5) in the background, without any model. The task succeeds, so the Calendar recipe gains a little confidence.
2. **Second time: a yes-or-no question instead of an open one.** "WhatsApp Priya: see you at 6." A candidate is never relied on silently, but it is offered: the hints say *Last time "Priya" meant Priya Shah (not yet confirmed: ask "Priya Shah, like last time?")*. The agent asks exactly that, the user says "yes", and memory, which remembers that it offered this suggestion for this goal, promotes the alias to ACTIVE (0.7). A "no" would have retired it, and the agent would then ask "Which Priya?".
3. **Third time: no question at all.** "Email Priya about lunch." The hints now say `Names: "Priya" is Priya Shah`, so the agent goes straight to her. The confirmation still reads the full name back ("Send to Priya Shah?"): memory never skips a confirmation.
4. **Correction.** "No, I meant the other Priya." The agent calls `correct_memory(about="Priya", right_value="Priya Patel")`. Shah loses 0.3, falls below the trust line, and is replaced by `Priya Patel` as a new CANDIDATE, which next time is offered as "Priya Patel, like last time?". The old row stays as RETIRED. Had Priya been an explicit memory, it would only lose some trust, and the agent would say "say 'remember' if you want to change that".
5. **Forgetting.** "Forget what I said about Priya." Every Priya fact is retired and its value and evidence are overwritten on disk.

So the user answers one open question, one yes, and then nothing, instead of the same open question twice.

---

# Part B: specification

Conventions: "lower" means Unicode lower-casing. `\w` means a Unicode letter, digit or underscore. Regular expressions are written so that both ICU (`NSRegularExpression`) and Python `re` accept them; "(i)" after a pattern means case-insensitive. Times are seconds since the Unix epoch, from an injectable clock (tests need one).

## 1. Data model

```
enum FactKind   { alias, preference, style, routine, recipe, note }
enum FactStatus { candidate, active, retired }
enum Source     { explicit, learned, builtIn }          // builtIn is (new); stored as the text "builtIn"

struct Fact {
  id: Int
  kind: FactKind
  key: String            // normalised (section 3), e.g. "mum", "google_account", "send_a_whatsapp_message"
  value: String          // for a recipe: the "how" text
  scope: String          // normalised app name, "" = everywhere; for a recipe: its app ("whatsapp", "chrome")
  status: FactStatus
  source: Source
  confidence: Double     // 0...1
  evidence: String       // the exchange it came from, e.g. "Asked: ... Answered: ..."
  uses: Int
  sightings: Int         // times the same value was seen (starts at 1)
  corrections: Int
  successes: Int         // recipes: tasks that succeeded while it was offered   (new)
  failures: Int          // recipes: tasks that failed while it was offered      (new)
  createdAt, updatedAt, lastUsedAt: Double
  retiredAt: Double?, retiredReason: String?   // "replaced" | "corrected" | "forgotten" | "failed" | "removed"
  extra: JSON object     // see below
}
```

`extra` keys:

| Key | Meaning |
|-----|---------|
| `label` | the key as the user said it ("Mum"), for speech |
| `scope_label` | the app as the user said it ("WhatsApp") |
| `builtin_id`, `version` | built-in recipes only: the fixture `id` and `version` |
| `match_any`, `app_names`, `not_if` | built-in recipes: the selection phrases from the fixture |
| `pitfalls` | recipes: up to 2 strings, newest first, each at most 120 characters |
| `needs_review` | built-in recipes: true when confidence fell below 0.5 |

## 2. Storage

SQLite file `<data_dir>/memory.db`. `data_dir` defaults to `~/.voicelaptop` (or the app's Application Support folder), always outside the repo.

- Create the file yourself, with mode 0600, before SQLite opens it, and `chmod` it to 0600 at every open. Create the folder with mode 0700 if it does not exist. Never change the mode of a folder that already exists: it may not be ours (the app's own data folder is one we create, so it is 0700).
- `PRAGMA secure_delete = ON`, so that deleted or overwritten text is zeroed on disk. Default (rollback) journal. `PRAGMA user_version = 1`.
- One connection, guarded by one lock. Every public method holds the lock for its whole duration, and every write runs in `BEGIN IMMEDIATE … COMMIT`, with `ROLLBACK` on error. The voice tools thread, the task runner and the learning queue all share it.

```sql
CREATE TABLE facts (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
  scope TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL, source TEXT NOT NULL,
  confidence REAL NOT NULL, evidence TEXT NOT NULL DEFAULT '',
  uses INTEGER NOT NULL DEFAULT 0, sightings INTEGER NOT NULL DEFAULT 1,
  corrections INTEGER NOT NULL DEFAULT 0,
  successes INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL NOT NULL DEFAULT 0,
  retired_at REAL, retired_reason TEXT,
  extra TEXT NOT NULL DEFAULT '{}'
);
-- At most one live fact per kind, key and scope, counted separately for built-in
-- and non-built-in rows (so a learned improvement can sit beside a built-in recipe).
CREATE UNIQUE INDEX facts_one_live ON facts (kind, key, scope, source = 'builtIn')
  WHERE status != 'retired';
CREATE INDEX facts_key ON facts (key);
CREATE TABLE episodes (
  id INTEGER PRIMARY KEY, goal TEXT NOT NULL, executor TEXT NOT NULL, status TEXT NOT NULL,
  summary TEXT NOT NULL, steps INTEGER NOT NULL, seconds REAL NOT NULL, created_at REAL NOT NULL
);
```

## 3. Normalising and matching text

**normalise_key(text)** (also used for scope):
1. Lower-case; replace `’` with `'`; trim.
2. Remove `'s` at a word end (regex `'s\b`).
3. Replace every match of `[^\w\s]` with a space, then replace `_` with a space.
4. Split on whitespace. While more than one word remains and the first word is a filler, drop it. If the single remaining word is a filler, the result is empty.
5. Join with `_` and cut to 80 characters.

Filler words: `my the our your a an`.

**tokens(text)**: lower-case, replace `_` with a space, and take every `\w+`. Drop stopwords and words shorter than 2 characters. If a word is longer than 3 characters, ends in `s` and does not end in `ss`, drop the final `s`. The result is a set.

Stopwords: the filler words plus `to of and or in on at for with is are be it me i please can you set up open this that what who about from by as do does tomorrow today now then just`.

**clean_value(text, limit)**: replace runs of control characters `[\x00-\x1f\x7f]+` with a space, collapse whitespace, trim, and cut to `limit`. Facts end up in prompts, so they are always one line.

**same_value(kind, a, b)**: true when `a` and `b` are equal after trimming and lower-casing. For recipes it is also true when the Jaccard overlap of `tokens(a)` and `tokens(b)` is at least 0.5.

**phrase_match(phrase, text)** (new, used by recipe selection): case-insensitive regex `(?<!\w)` + escaped phrase + `(?!\w)`. Two placeholders:
- `{day}` = `(?<!\w)(today|tonight|tomorrow|next week|this week|this weekend|(mon|tues|wednes|thurs|fri|satur|sun)day|\d{1,2}(st|nd|rd|th))(?!\w)` (i)
- `{time}` = `(?<!\w)(\d{1,2}(:\d{2})?\s?(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|at \d{1,2}|noon|midday|midnight|o'clock)(?!\w)` (i)

## 4. Constants

| Name | Value | Meaning |
|------|-------|---------|
| EXPLICIT_CONFIDENCE | 0.9 | the user said "remember" |
| LEARNED_CONFIDENCE | 0.5 | inferred once |
| PROMOTED_CONFIDENCE | 0.7 | minimum after promotion |
| BUILTIN_CONFIDENCE | 0.8 | a fresh built-in recipe (new) |
| BUILTIN_FLOOR | 0.3 | a built-in recipe never drops below this (new) |
| TRUST_THRESHOLD | 0.5 | an active non-built-in fact below this is demoted to candidate |
| RETIRE_THRESHOLD | 0.25 | a non-built-in fact at or below this is retired |
| USE_STEP | 0.1 | `c += (1 - c) * 0.1` per use, or per extra sighting of an active fact |
| CORRECTION_STEP | 0.3 | `c -= 0.3` per correction |
| RECIPE_SUCCESS_STEP | 0.15 | `c += (1 - c) * 0.15` per success (new) |
| RECIPE_FAILURE_STEP | 0.15 | `c -= 0.15` per failure (new) |
| MAX_KEY / VALUE / EVIDENCE | 80 / 300 / 300 characters | built-in recipe `how` may be up to 450 |
| MAX_EPISODES | 500 | older episodes are pruned |
| RECENT_WINDOW | 900 s | "the fact you just used" |
| WIPE_MIN_WAIT / WIPE_MAX_WAIT | 2 s / 120 s | for "forget everything" |
| HINTS_MAX_CHARS | 700 | the screen agent's memory block (new) |
| SUMMARY_MAX_CHARS | 1200 | the voice agent's memory block |

## 5. Hard rules

### 5.1 looks_secret(text)

True if any of these match:

1. `\b(pass ?words?|passcodes?|passwd|pass ?phrases?|one[- ]time (?:pass)?codes?|otps?|verification codes?|security codes?|2fa|two[- ]factor|auth(?:entication)? codes?|login codes?|cvv|cvc|card numbers?|credit cards?|debit cards?|card details|bank details|bank account|account numbers?|sort codes?|iban|routing numbers?|social security|ssn|national insurance|api keys?|secret keys?|private keys?|access tokens?|seed phrases?|recovery (?:phrases?|codes?|keys?)|mnemonic|security (?:questions?|answers?)|maiden name|login details|credentials?)\b` (i)
2. `\bPINs?\b` (case-sensitive), or `\b(?:my|the|card|bank|phone|sim)\s+pin\b|\bpin\s*(?:code|number|is\b|:)` (i). So "pin this tab" is fine.
3. `\b(?:code|pin)\b\D{0,15}\d{4,8}\b` (i)
4. Sort code `\b\d{2}-\d{2}-\d{2}\b`, or IBAN `\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b` (case-sensitive, tested with spaces removed).
5. Card: any run matching `(?:\d[ -]?){13,19}` whose digits (13 to 19 of them) pass the Luhn check.
6. Token: any `\b[A-Za-z0-9_\-]{24,}\b` that contains both a digit and a letter.
7. The trimmed, lower-cased text starts with `sk-`.

Phone numbers ("+44 7700 900123") are not secrets.

### 5.2 grants_permission(key, value)

Let `text = key + " " + value`, with `_` replaced by a space. True if any of these match:

1. `\b(?:don'?t|do not|never|no need to|stop|without|skip|no more)\s+(?:ever\s+)?(?:\w+\s+)?(?:ask|asking|confirm|confirming|confirmations?|check|checking|double[- ]check)` (i)
2. `\bauto(?:matically)?[- ]?(?:RISKY)` (i)
3. `\bjust (?:RISKY) it\b` (i)
4. The key matches `\b(?:RISKY|confirm\w*)\b` (i), and the value (trimmed, lower-cased, trailing `.` or `!` removed) is a consent word or an off word.

RISKY = `send|pay|buy|purchase|order|delete|remove|submit|post|invite|share|publish|transfer|accept`

Consent words: `yes yeah yep y sure ok okay "go ahead" "do it" send "send it" confirm confirmed approve approved allow allowed granted true`

Off words: `off never none no skip disabled disable false 0 nothing`

"confirmations: brief" and "always send invites from my work account" are allowed. "Return sends, so press it only after the user confirms" is allowed.

### 5.3 check_allowed(key, value) → reason or nil

- If `looks_secret(key)` or `looks_secret(value)`: "I never store passwords, codes, PINs, or card and bank details."
- If `grants_permission(key, value)`: "I can't remember that. I always check with you before sending, paying or deleting."

This check runs inside `remember` (so it covers every source), on every learned proposal, and on every built-in recipe at load time. A built-in recipe that fails it is skipped and logged.

### 5.4 Message content

Four patterns, applied in this order to redact text (episode log, model prompts) and to find dictated wording:

- **R1 quoted:** `"[^"]{2,}"|“[^”]{2,}”|‘[^’]{2,}’` → replace with `[message]`.
- **R2 after a colon:** `(?<!\d):\s+\S.*$` → replace with `: [message]`. A colon after a digit, as in "15:00", is untouched.
- **R3 saying:** `\b(?P<lead>saying|say|says|that says|reply(?:ing)? with|tell (?!me\b)\w+(?: that)?|text(?:ing)? \w+ that|message(?: \w+)? that|ask (?!me\b)\w+(?: if| whether| to)?)\s+(?P<body>\S.*)$` (i) → replace with `lead + " [message]"`.
- **R4 chat verb + name + text (new):** `^(?P<lead>\s*(?:whatsapp|text|message|imessage)\s+(?:my\s+)?\w+)\s+(?!(?:(?:on|in|via|using)\s+(?:whatsapp|imessage|messages|telegram|signal|slack)|about)\b)(?P<body>\S.*)$` (i) → replace with `lead + " [message]"`. "WhatsApp Mum I'm running late" becomes "WhatsApp Mum [message]"; "Message Mum on WhatsApp" is untouched.

**message_content(goal)** returns the dictated parts: the inside of each R1 match, the text after R2's colon, R3's body, and R4's body. Each is trimmed of ` "'.`, and only parts of 3 or more characters are kept.

**contains_message_content(value, goal)**: take `v` = the lower-cased words of `value` joined by single spaces. For each part (as lower-cased words): if it has fewer than 3 words and its joined text has at least 6 characters, return true when that text is a substring of `v`. Otherwise return true when any 3 consecutive words of the part appear in `v`.

### 5.5 redact_secrets(texts) → texts (new)

For text that is stored or sent to a model but is not itself a fact: a finished task's goal, summary and steps, and the goal in a learning prompt. Facts are refused outright (5.3); this is the softer rule for task text.

1. Split each text into clauses after each `,` `;` `.` `!` `?` or newline. Replace every clause for which `looks_secret` is true with `[private]`, keeping its leading whitespace and its closing punctuation. If the result still looks secret (a secret split across clauses), the whole text becomes `[private]`.
2. Texts from one task are cleaned together. Every run of 4 or more digits (`\d(?:[ -]?\d){3,}`) inside a secret clause of any of them is a secret number, and it is replaced by `[private]` wherever it appears in any of them, even spaced or dashed differently. So the step "Typed 482913" loses its number when the summary says "Entered the verification code 482913".

Message wording (5.4) is removed first, then secrets. "Type my PIN 4821 into the bank app, then open Notes" becomes "[private], then open Notes".

## 6. Retrieval

### 6.1 search(text, limit = 8, include_candidates = false) → [Fact]

Non-recipe facts only (new: recipes go through 6.3). `goal = tokens(text)`; if it is empty, return `[]`. For each live fact, skipping candidates unless `include_candidates`:

```
key_words = tokens(key) or tokens(label)
overlap   = |key_words ∩ goal| / |key_words|
score     = 3 if overlap == 1 else 1.5 * overlap
if scope != "" and tokens(scope) ⊆ goal: score += 1
score    += 0.5 * min(2, |tokens(value) ∩ goal|)
keep if score > 0; rank by score + confidence (desc), then uses (desc), then id (asc)
```

"WhatsApp Mum: running late" finds `mum` (score 3 + 1 for the app). "Set up a Google Meet with Priya" finds `priya` (3) and `google_account` (0.75).

### 6.2 summary_for_prompt(max_chars = 1200) → String

For the voice agent's system prompt. Active facts of kinds style, alias, preference, routine and note (no recipes, no candidates).

- usefulness = `weight × confidence + 0.3 × ln(1 + uses) + (0.5 if used in the last 7 days)`, with weights style 3, alias 2.5, preference 2.5, routine 2, note 1. Sort by usefulness (desc), then id.
- The first line is `What you know about the user (they told you, or it held up before):`. Each fact is then `- ` + `clean_value(describe(fact), 160)`.
- Before adding a line, check that the line, plus (if other facts remain after it) the tail `- (N more; use the recall tool)`, still fits in `max_chars`, where N counts the remaining facts including this one. If it doesn't fit, add the tail if the tail alone fits, then stop.
- Return `""` if no fact line fits.

The block is fixed when a voice session starts. To make a newly learned fact count in the same session, the voice layer must push it as a contextual update.

### 6.3 select_recipes(goal, hint_facts) → [Recipe] (new)

Candidates are all live recipes. Built-in recipes use the `match_any`, `app_names` and `not_if` phrases from their fixture entry. A learned recipe has `match_any = tokens(task name)` minus the words of its app, `app_names = [its scope with "_" replaced by a space]` and `not_if = []`. A learned recipe that shares key and scope with a built-in one inherits the built-in's three lists.

**One per task.** When a built-in and a learned recipe share key and scope, consider the learned one only if it is ACTIVE and its confidence is at least the built-in's; otherwise consider the built-in.

**Scoring:**

```
skip if any not_if phrase matches the goal
hits  = min(3, number of match_any phrases that match the goal)
app   = 2 if any app_names phrase matches the goal, else 0
bonus = 1 if app == 0 and some alias in hint_facts has scope == recipe.scope and its key matches the goal
base  = hits + app + bonus;  skip if base < 2
score = base + confidence
```

Sort by score (desc), then uses (desc), then fixture order or id. Take the first. Take a second only if it is for a different app ("look up the weather and add it to my notes" gets the Notes recipe and the web look-up recipe). At most 2.

### 6.4 memory_hints(goal, max_chars = 700) → { text, fact_ids, recipe_ids, suggested_ids } (new shape)

This is what the task runner puts in `ctx.memory_hints`. The text is read by the screen agent on every step, so it stays short.

1. `found` = `search(goal, limit = 8, include_candidates = true)`, keeping kinds alias, preference, routine and note (no style: style is for the voice agent). `facts` = its ACTIVE members, at most 4. `suggestions` = its CANDIDATE aliases and preferences, at most 2.
2. `recipes` = `select_recipes(goal, facts + suggestions)`.
3. Build lines in this order, skipping any line that would push the total past `max_chars` (lines are never cut mid-way):

```
Advice from memory (check each step on screen; it never replaces asking before sending):
How to {task label}: {how}                ← recipe 1; add " (not yet confirmed; check it)" if it is a candidate
  Watch out: {newest pitfall}             ← only if recipe 1 has one
Names: "Mum" is Amma (WhatsApp); "Priya" is Priya Shah.          ← alias facts, joined by "; "
Preferences: google account: work; music app: Spotify.           ← preference facts, as describe()
Last time "Priya" meant Priya Shah (not yet confirmed: ask "Priya Shah, like last time?").   ← each suggested alias
Last time music app was Spotify (not yet confirmed: ask "Spotify, like last time?").          ← each suggested preference
"morning routine" means: open mail, calendar and the news        ← one line per routine or note
How to {task label}: {how}                ← recipe 2
  Watch out: {newest pitfall}
```

4. If only the header would remain, return `text = ""` and empty id lists.
5. Call `note_offered(fact_ids + recipe_ids + suggested_ids)` (section 7.7) and return the ids of what made it into the text.

A suggestion is never relied on silently: it tells the agent to ask a yes-or-no question (the text in quotes is exactly `{value}, like last time?`), so one earlier answer already saves the user an open question. What a yes or a no does is in 7.13.

The runner keeps `recipe_ids` and passes them to `reflect_on_task` when the task ends (section 8.3).

### 6.5 describe(fact) → String

Used for speech and prompts. `label` = `extra.label`, or the key with `_` replaced by a space. `where` = `" on " + (extra.scope_label or scope with "_" replaced by a space)` when there is a scope, else `""`.

| Kind | Template |
|------|----------|
| alias | `"{label}" means {value}{where}` |
| preference | `{label}{where}: {value}` |
| style | `preferred {label}: {value}` |
| routine | `"{label}" means: {value}` |
| recipe | `to {label}{where}: {value}` |
| note | `{value}` if label is "" or "note", else `{label}: {value}` |

In the `Names:` line of 6.4, an alias is written as `"{label}" is {value}`, followed by ` ({scope_label})` when it has a scope.

## 7. Lifecycle (store operations)

### 7.1 remember(kind, key, value, scope = "", source = learned, evidence = "", confidence = nil) → Fact

1. `label = clean_value(key, 80)`, `k = normalise_key(key)`, `s = normalise_key(scope)`, `v = clean_value(value, 300)` (450 for built-in recipes).
2. If `k` or `v` is empty, refuse with "I need both what to remember and what it means."
3. If `check_allowed(label, v)` gives a reason, refuse with it. The refusal is an error the caller catches, whose message can be read aloud.
4. `evidence = clean_value(evidence, 300)`. If it looks secret, set it to `""` (keep the fact, drop the context).
5. Under the lock, in one transaction, find the live fact for `(kind, k, s)` in the same built-in or non-built-in namespace:
   - **Same value** (`same_value`): reinforce it (7.2) and return it.
   - **Different value, source is learned, existing fact is explicit:** return the existing fact unchanged. Explicit beats learned, and the caller sees `result.value != value`.
   - **Different value, otherwise:** retire the existing fact with reason `replaced`, then insert the new fact.
   - **No live fact:** insert.
6. Insert with: status ACTIVE if explicit or built-in, else CANDIDATE; confidence from the argument, or 0.9 explicit, 0.8 built-in, 0.5 learned; `sightings = 1`; `extra = {label, scope_label if scope given}`.

### 7.2 reinforce(fact, explicit, newValue, evidence)

- `sightings += 1`.
- If the call is explicit: status ACTIVE, source explicit, confidence `max(c, 0.9)`.
- Else, if the fact is a candidate: status ACTIVE, confidence `max(c + 0.2, 0.7)`. This is the promotion on the second sighting.
- Else: `c += (1 - c) * 0.1`.
- A recipe takes `newValue` (its newest wording); other kinds keep their stored value.
- Replace `evidence` only when the new evidence is not empty.

### 7.3 record_use(id)

Only for a fact that is not retired: `c += (1 - c) * 0.1`, `uses += 1`, `lastUsedAt = now`, and add `(id, now)` to the recent list (7.7).

### 7.4 record_correction(id) → Fact?

For a fact that is not retired:
- `c = max(0, c - 0.3)` and `corrections += 1`.
- If `c ≤ 0.25`: retire it with reason `corrected`.
- Else, if it is active and `c < 0.5`: status CANDIDATE.

Return the fact as it is now. Built-in recipes are not corrected by voice; recipe trust moves through outcomes (7.5).

### 7.5 record_recipe_outcome(recipe_ids, status) (new)

`status` is the task's final status.
- **done:** for each recipe: `successes += 1`, `c += (1 - c) * 0.15`. A learned CANDIDATE recipe becomes ACTIVE, because it was offered and it worked, which counts as its second sighting. A built-in recipe gets `needs_review = (c < 0.5)`.
- **failed:** for each recipe: `failures += 1`, `c -= 0.15`. A built-in recipe is held at 0.3 at least and gets `needs_review = (c < 0.5)`; it is never retired. A learned recipe is retired with reason `failed` at `c ≤ 0.25`, and demoted to CANDIDATE if it is active with `c < 0.5`.
- **cancelled** or anything else: no change. A cancel is the user's choice, not the recipe's fault.

### 7.6 add_pitfall(recipe_id, text) (new)

`text = clean_value(text)`; if it is longer than 120 characters, cut it at the last whole word that fits and end it with `…`, so a note read on every step never stops mid-word. It must pass `check_allowed("pitfall", text)` and must not look secret; otherwise it is dropped. Skip it if it is the same as an existing pitfall (Jaccard of tokens ≥ 0.5). Otherwise put it first, and keep the newest 2.

### 7.7 recently_used(within = 900 s) and note_offered(ids)

An in-memory list (about 50 entries) of `(id, time)`, filled by `record_use` and `note_offered`. `recently_used` returns live facts from that list, most recent first, without duplicates. Offering a fact does not change its confidence; the list exists so that "no, the other one" can find what was just used.

### 7.8 forget(text) → [Fact]

1. `wanted = tokens(text)`; if it is empty, return `[]`.
2. For every live, non-built-in fact where `wanted` intersects `tokens(key) ∪ tokens(value) ∪ tokens(scope) ∪ tokens(label)`: set value `""`, evidence `""`, extra `{}`, status retired, reason `forgotten`.
3. Delete every episode whose goal and summary tokens intersect `wanted ∪ tokens(key of each forgotten fact)`.
4. Return copies of the matched facts, with their old values, so the caller can say what went. On disk the values are gone.

Built-in recipes are never matched. They hold nothing about the user.

### 7.9 request_forget_all() and forget_all(confirmed) → Int

`request_forget_all` records `now` as the time the question was asked. `forget_all` succeeds only if `confirmed` is true and `WIPE_MIN_WAIT ≤ now - askedAt < WIPE_MAX_WAIT`; otherwise it returns -1.

On success:
1. Clear `askedAt`.
2. Count the non-built-in facts.
3. Delete all facts and all episodes, and clear the recent list.
4. Run `VACUUM`.
5. Re-seed the built-in recipes (7.10).
6. Return the count.

### 7.10 seed_builtin_recipes(fixture) (new)

Run at every open and after `forget_all`. For each fixture recipe that passes `check_allowed(task, how)`, has a `how` of at most 450 characters, and has a unique `id`:

- **No built-in row with this `builtin_id`:** insert it with kind recipe, source builtIn, status ACTIVE, confidence 0.8, `key = normalise_key(task)`, `scope = normalise_key(app)`, `value = how`, and `extra = {label: task, builtin_id, version, match_any, app_names, not_if}`.
- **Row exists with a lower `version`:** replace the text and lists, and reset confidence to 0.8, successes and failures to 0, `pitfalls` to empty, and `needs_review` to false.
- **Row exists with the same version:** leave it alone. It keeps its learned confidence and pitfalls.

Built-in rows whose `builtin_id` is no longer in the fixture are retired with reason `removed`.

### 7.11 Episodes

`log_episode(goal, executor, status, summary, steps, seconds) → id`:
- `goal` and `summary` have message wording removed (5.4), then secrets, together (5.5), and are passed through `clean_value(·, 300)`.
- `executor` and `status` are cut to 20 characters.
- Rows beyond the newest 500 are pruned.

`recent_episodes(limit = 5)` returns, newest first, `{goal, executor, status, summary, steps, seconds (1 decimal), at}`.

### 7.12 Other reads

- `lookup(kind, key, scope)`: the ACTIVE fact or nil.
- `lookup_live`: candidates count too.
- `all_active`, `all_live`.
- `history(key)`: every row for the key, newest first, retired ones included.
- `get(id)`.

### 7.13 Confirming or rejecting a suggestion (new)

Memory keeps, per goal, what `memory_hints` handed out, including `suggested_ids` (one task runs at a time, so this is a tiny in-memory record, dropped when the task ends). When the task then hands over a question and answer for the same goal:

- The question must not be about a risky step: `never_learn_reason(question, "x")` must be nil (so "Send it to Priya Shah?" never counts, and nor does anything the task marks as a confirmation).
- The question must contain the value of one of this goal's suggestions, ignoring case ("Priya Shah, like last time?").
- A clear yes (`^\s*(yes|yeah|yep|yup|sure|correct|right|exactly|ok(ay)?|that's (right|her|him|it|the one)|that is right)\b` (i), with no `\b(no|not|nope|wrong|other)\b`) → `confirm_candidate`: the candidate counts as seen again and is promoted (7.2).
- A clear no (`^\s*(no|nope|nah|not)\b` (i)) → `reject_candidate`: `corrections += 1`, retired with reason `corrected`. The agent then asks the open question, whose answer is learned as usual.
- Anything else falls through to ordinary learning (8.1), where a bare yes or no is never learned.

A yes is only ever accepted for a suggestion memory itself offered for this goal; on its own a yes is never learned.

## 8. Learning

All learning runs on one background serial queue. Every entry point returns at once and never throws, and every failure is logged without secrets.

### 8.1 learn_from_exchange(question, answer, goal, options = [], is_confirmation = false) → Fact?

Steps, in order:

1. `reason = never_learn_reason(question, answer, is_confirmation)`. If there is a reason, return nil.
2. `proposal = name_choice(question, answer, goal, options)`.
3. If there is no proposal and a model is available:
   - If Jev is available and `p(lasting) < 0.15` (prompt 3 in `docs/prompts/memory_learning.md`), return nil.
   - Otherwise send prompt 1. Accept the reply only if `lasting` is true and `kind` is in `alias preference style routine note` (the word `default` is also accepted, as `preference`). The proposal is `{kind, key, value, scope}`.
4. If there is still no proposal, return nil.
5. If `grounded(proposal, said = question + answer + options + goal, goal)` is false, return nil.
6. `remember(kind, key, value, scope, source = learned, evidence = "Asked: {question} Answered: {answer}")`. A refusal means nil.

**never_learn_reason**. Checks run in this order and the first match wins:

1. Question or answer blank → `empty`.
2. `is_confirmation`, or `is_confirmation_question(question)` → `confirmation`.
3. Question and answer both match RISKY_Q → `confirmation`.
4. The answer matches `^\s*(stop|cancel|abort|never ?mind|forget it|leave it)\b` (i) → `cancel`.
5. `is_bare_yes_no(answer)` → `yes/no answer`.
6. The question matches CONTENT_Q → `message wording`.
7. `looks_secret(question)` or `looks_secret(answer)` → `secret`.

The patterns:

- RISKY_Q = `\b(send|pay|buy|purchase|order|delete|remove|submit|post|invite|share|publish|transfer|confirm|accept)\b` (i)
- CONTENT_Q = `\b(what should (it|the message|the email|the reply|the text|i|we) (say|write)|what (do you want|would you like) (me )?to (say|write|reply)|what('s| is) the message|message (text|body|wording)|subject line|what should i write|how should i word|wording|what do you want to tell)\b` (i)

**is_confirmation_question(q):**
1. False if `q` has no RISKY_Q word.
2. `last` = the last piece after splitting on `(?<=[.!?])\s+`.
3. False if `last` matches `\bor\b(?! not\b)` (i). A question that offers a choice is not asking permission.
4. False if `last` starts with `which|who|whom|whose|what|where|when|how` (i): "Which Priya do you want to invite?" asks who, not whether. A yes or a risky pick is still never learned from it (steps 3 and 5 of never_learn_reason), and the step itself still goes through the safety gate.
5. True if `last` matches `^\s*(do|does|did|is|are|was|were|should|shall|can|could|would|will|may|want|ready|ok|okay|send|post|pay|buy|delete|submit|share|invite|confirm|go ahead)\b` (i), or `q` ends with `?`.

**is_bare_yes_no(a):**
1. `words` = the lower-cased matches of `[\w']+`. True if there are none.
2. True if every word is in the yes/no list below.
3. True if `a` matches the consent-start pattern below and has at most 6 words.

Yes/no words: `yes yeah yep yup y no nope nah n sure ok okay fine please correct right go ahead do it send don't dont not cancel stop confirm confirmed absolutely definitely thanks thank you that's thats that is alright never mind`

Consent-start pattern: `^\s*(yes|yeah|yep|yup|no|nope|nah|sure|ok(ay)?|go ahead|do it|don'?t|please do|absolutely|definitely|correct|right|confirm(ed)?|cancel|stop|never ?mind)\b` (i)

**name_choice(question, answer, goal, options):**
1. `opts = options` when the task passed any (they win: questions are worded in many ways). Otherwise `opts = options_from_question(question)`, and if steps 2 to 5 fail with 3 or more pieces, drop the first piece and try again ("Which Priya do you want to invite, Priya Shah or Priya Patel?" parses as `["to invite", "Priya Shah", "Priya Patel"]`). Fewer than 2 → nil.
2. `chosen = pick_option(answer, opts)`. Nil → nil.
3. `common` = the leading words shared by every option (compared case-insensitively). Nil if `common` is empty, or if every option is exactly `common`.
4. `key = common` joined by spaces. Nil unless `tokens(key) ⊆ tokens(goal) ∪ tokens(question)`.
5. Return `{alias, key, chosen, scope ""}`.

**options_from_question(q):**
1. `last` = the last piece after splitting `q` on `(?<=[.!])\s+`, with trailing `?` removed and trimmed.
2. If `last` starts with `did|do|which|would|should` (i), remove everything up to and including the first `\b(mean|want|prefer|like|choose|pick|use|it)\b\s*` (shortest match).
3. Keep the text after the last `:`.
4. Split on `,\s*(?:or\s+)?|\s+or\s+` and trim ` ,`.
5. Return the pieces if there are at least 2, else `[]`.

**pick_option(answer, opts):**
1. `a` = the lower-cased, trimmed answer, without a trailing `.!` and without a leading `the |i meant |i mean |it's |its |it is `.
2. If `a` equals an option exactly (ignoring case), return it.
3. For each word of `a` that is an ordinal (`first/1st/one→0, second/2nd/two→1, third/3rd/three→2, last→-1`), and if `a` contains "one" or has at most 2 words, return `opts[index]` when it is in range. A negative index counts from the end.
4. Let `w = tokens(a)`. If it is not empty and exactly one option has `w ⊆ tokens(option)`, return that option.
5. Otherwise nil.

**grounded(p, said, goal):** all of these must hold:
- key and value are not empty, and `tokens(key) ≠ tokens(value)`;
- `contains_message_content(value, goal)` is false;
- for alias and preference: `tokens(value) ⊆ tokens(said)` (no invented names);
- `check_allowed(key, value)` gives no reason.

### 8.2 Calling the model

See `docs/prompts/memory_learning.md` for the exact settings: `small_model`, `max_tokens` 2000, effort low, a JSON-schema output format, 30 s timeout, 1 retry. Only a `stop_reason` of `end_turn` whose first text block parses as a JSON object counts as an answer. Anything else is "no answer" and must never throw out of the learning queue. Never log the API key or the prompt text.

### 8.3 reflect_on_task(goal, status, summary, steps = [], recipe_ids = []) → [Fact] (changed)

1. `record_recipe_outcome(recipe_ids, status)` (7.5). This needs no model.
2. If the status is not `done` or `failed`, or no model is available, or the goal is blank, stop here.
3. Send prompt 2, giving it:
   - the redacted goal and summary;
   - the last 20 steps, each cut to 200 characters;
   - the given recipes as `{task, how}`;
   - the names of the live recipes (at most 40).
4. **On done**, if `save_recipe` is true and `task` and `how` are not empty:
   - Drop it if `contains_message_content(task + " " + how, goal)`.
   - `key = normalise_key(task)`, `scope = normalise_key(app)`.
   - If a built-in recipe with the same key and scope exists and `same_value(recipe, builtin.how, how)` is true, the built-in already says it, so store nothing.
   - Otherwise `remember(recipe, task cut to 60, how cut to 300, scope, source = learned, evidence = "From the task: " + redacted goal)`.
5. **On failed**, if `pitfall` is not empty and does not repeat message content:
   - if a recipe was given: `add_pitfall(recipe_ids[0], pitfall)`, which attaches it to the top recipe that was given;
   - otherwise, if `task` is set: attach it to a live recipe with the same key and scope if one exists (a failure never counts as a sighting, so it is never promoted); else, if `save_recipe` is true and `how` is set and does not repeat message content, store a new learned CANDIDATE recipe from `task`, `app` and `how` and attach the pitfall to it. So a failure with no recipe still teaches something, as an unconfirmed suggestion.
6. **Preferences**, only if the goal matches `\b(always|usually|normally|by default|from now on|every time|each time|in future|i prefer|i'd rather|i would rather|i like (it|my|to)|i always)\b` (i): for each preference whose kind is not recipe and which passes `grounded(p, goal, goal)`, call `remember(..., source = learned)`.
7. Return the facts stored.

Which recipes were offered comes from memory's own per-goal record of `memory_hints` (7.13), so the task runner passes nothing extra.

### 8.4 What the rest of the app calls

| When | Call |
|------|------|
| startup | `open(data_dir)`, then `seed_builtin_recipes(Fixtures/recipes.json)` |
| voice session start | `summary_for_prompt()` into the system prompt |
| registering tools | the six tools of section 9 |
| task start | `memory_hints(goal)`, then text into `ctx.memory_hints` (memory records what it handed out for this goal) |
| the user answers a task question | `learn(question, options offered, answer, goal)`, in the background; a yes or no to a suggestion is handled first (7.13) |
| task end | `log_episode(...)` and `reflect_on_task(goal, status, summary, steps, recipe_ids from the record)`, in the background; the record is then dropped |
| optional | `resolve_alias(name, app) → String?`: an ACTIVE alias in that app, else a global one; calls `record_use` |

## 9. Voice tools

The exact names, descriptions and parameter schemas are in `Fixtures/memory_tools.json` (tier 0, timeout 10 s). Every handler takes a dictionary and returns a JSON-safe dictionary with `ok`. On failure it returns `{"ok": false, "error": "<one short spoken sentence>"}`. A handler never throws; any unexpected error becomes `"Sorry, something went wrong with my memory."`. A non-dictionary input is treated as `{}`.

`join(items)`: for one item, the item itself; otherwise `"a; b; and c"`. `spoken(fact)` = `describe(fact)` + `" (I think; not sure yet)"` for a candidate.

**remember {kind, key, value, app?}**
- Kind words are mapped: `alias|name|contact|person → alias`; `preference|default|choice|account|app → preference`; `style|behaviour|behavior → style`; `routine → routine`; anything else → `note`.
- Blank key or value → error "Tell me what to remember and what it means."
- Call `remember(..., source = explicit, evidence = "The user asked me to remember this.")`. A refusal becomes `error = reason`.
- Returns `{ok, saved: describe(fact), replaced: describe(previous live fact) or null, fact_id, say}`, where `say` = `Got it. I'll remember {saved}.`, plus ` That replaces {replaced}.` when something was replaced.

**recall {about?}** (recipes are never listed: they are about apps, not the user)
- With `about`: `search(about, limit = 5, include_candidates = true)`.
  - No results → `say` = `I don't have anything saved about {about}.`
  - Otherwise `say` = `join(spoken) + "."`, plus `count` and `facts`.
- Without `about`:
  - `active` = the active non-recipe facts, sorted by kind order alias, preference, style, routine, note, then uses (desc), confidence (desc), id.
  - `learning` = the number of live non-recipe candidates.
  - Nothing at all → `I don't remember anything about you yet.`
  - Otherwise `say` = `I know {n} thing(s): {join(first 5 spoken)}`, then `, and {n-5} more` if `n > 5`, then `.`, then ` I'm also still checking {m} thing(s) I've noticed.` if `m > 0`.
  - Returns `{ok, count, learning, facts, say}`.

**forget {about}**
- Blank → error "What should I forget?".
- `about` is one of `everything`, `all`, `it all`, `everything about me` → error "To forget everything, use forget_everything and ask the user first."
- Otherwise call `forget(about)`.
  - Nothing matched → `I didn't have anything saved about {about}.`
  - Otherwise `Done. I've forgotten {join(describe of first 5)}.`, with `forgotten` and `items`.

**forget_everything {confirmed?}**
- If `confirmed` is not exactly boolean true: call `request_forget_all()` and return `{ok: true, done: false, needs_confirmation: true, say: "Do you want me to forget everything I know about you? This can't be undone."}`.
- If it is true and `forget_all(true)` returns -1: call `request_forget_all()` and return `{ok: false, needs_confirmation: true, error: "I need to ask you first. " + that question}`.
- Otherwise `{ok, done: true, forgotten, say: "Done. I've forgotten everything I knew about you."}`.

**correct_memory {about?, right_value?}**
- **Target:** the first `recently_used()` fact whose key, value or label tokens intersect `tokens(about)`; otherwise `search(about, 1, include_candidates = true)`. With no `about`, the most recent `recently_used()` fact.
- No target → error "I'm not sure which memory you mean. What should I correct?"
- Call `record_correction(target)`. `wrong = describe(target)`.
- With `right_value`: `remember(target.kind, label, right_value, target.scope, source = learned, evidence = "The user corrected '{old}' to '{right}'.")`, and set `use_now = right_value`.
  - If the stored value now equals `right_value` (ignoring case): `Sorry about that. I'll use {right}, and I've stopped assuming {wrong}. If it's always {right}, tell me to remember it.`
  - Otherwise, because an explicit fact won: `Sorry. I'll use {right} this time. You told me earlier that {wrong}; say 'remember' if you want to change that.`
- Without `right_value`:
  - retired → `Sorry. I've dropped {wrong}.`
  - candidate → `Sorry. I won't rely on {wrong} any more without checking.`
  - otherwise → `Sorry. I'll be more careful with {wrong}.`
- Returns `{ok, corrected: wrong, fact_id, use_now?, say}`.

**recent_tasks {count?}**
- `count` is clamped to 1…5, with a default of 3 when it is missing or not a number.
- No episodes → `I haven't done any tasks yet.`
- Otherwise `say` = `join("{status}: {summary or goal}") + "."`, with `tasks` (the episode dictionaries).

## 10. Privacy summary

- Stored only on this Mac, in a 0700 folder and a 0600 file, with `secure_delete` on.
- `forget` wipes values and evidence. `forget_all` deletes every row and runs VACUUM.
- No secrets, no permission to skip a confirmation, no message wording (section 5).
- The safety gate never reads memory.

## 11. API summary (language-neutral)

```
Store
  init(path, clock)                                   seed_builtin_recipes(fixture)
  remember(kind, key, value, scope, source, evidence, confidence?) -> Fact   throws Refused(reason)
  lookup(kind, key, scope) -> Fact?    lookup_live(...) -> Fact?    get(id) -> Fact?
  all_active() -> [Fact]   all_live() -> [Fact]   history(key) -> [Fact]
  search(text, limit = 8, include_candidates = false) -> [Fact]          non-recipe facts
  select_recipes(goal, hint_facts) -> [Fact]                             at most 2
  memory_hints(goal, max_chars = 700) -> {text, fact_ids, recipe_ids}
  summary_for_prompt(max_chars = 1200) -> String
  record_use(id)   record_correction(id) -> Fact?
  record_recipe_outcome(recipe_ids, status)   add_pitfall(recipe_id, text)
  note_offered(ids)   recently_used(within = 900) -> [Fact]
  forget(text) -> [Fact]   request_forget_all()   forget_all(confirmed) -> Int (-1 = refused)
  log_episode(goal, executor, status, summary, steps, seconds) -> Int   recent_episodes(limit = 5) -> [Episode]
Rules (pure functions)
  normalise_key, tokens, clean_value, same_value, phrase_match
  looks_secret, grants_permission, check_allowed
  redact_message_content, message_content, contains_message_content
Learning (background, never throws)
  learn_from_exchange(question, answer, goal, options, is_confirmation) -> Fact?
  reflect_on_task(goal, status, summary, steps, recipe_ids) -> [Fact]
  never_learn_reason, is_bare_yes_no, is_confirmation_question, options_from_question, pick_option, name_choice, grounded
Tools
  build_tools(store) -> [ToolSpec]   six tools, section 9
```

## 12. Built-in recipe file format

`Fixtures/recipes.json`: `{format: 1, about, recipes: [...]}`. Each recipe has:

| Field | Meaning |
|-------|---------|
| `id` | stable and unique, e.g. `whatsapp.send_message` |
| `version` | an integer; bump it when the text changes, so installed copies are refreshed (7.10) |
| `task` | the generic name, which becomes the key, e.g. "send a whatsapp message" |
| `app` | the scope: `whatsapp`, `chrome`, `spotify`, `notes` |
| `app_names`, `match_any`, `not_if` | phrase lists for 6.3; `{day}` and `{time}` are allowed |
| `how` | at most 450 characters, written as advice to check on screen; any sending step says "only after the user confirms" |

The recipes have not yet been checked against the real apps. That check is the lead's to-do.

## 13. Shared test cases

`Fixtures/memory_cases.jsonl` holds one JSON object per line, with a `type`, the inputs, `expect`, and `verified`:

- `python`: checked against the Python prototype.
- `swift`: added with the Swift package (6 Nov) and checked against it.
- `spec`: checked against a throwaway simulation of this document. These cover the new recipe selection and redaction rule R4.
- `live`: needs the real model, so run it in the live suite only.

Counts: 144 cases, of which 100 are `python`, 20 are `spec`, 13 are `swift` and 11 are `live`. The Swift package runs all 133 non-live cases as unit tests and the 11 live ones in its live suite (section 15); all of them pass.

| type | Fields | Expect |
|------|--------|--------|
| `normalise_key` | `input` | the key |
| `secret` | `text` | bool from `looks_secret` |
| `permission` | `key`, `value` | bool from `grants_permission` |
| `redact` | `input` | the redacted text (R1 to R4) |
| `message_content` | `value`, `goal` | bool |
| `options_from_question` | `question` | list |
| `pick_option` | `answer`, `options` | option or null |
| `confirmation_question` | `question` | bool |
| `bare_yes_no` | `answer` | bool |
| `redact_secrets` | `input` | the text after 5.5 |
| `exchange` | `question`, `answer`, `goal`, `options?`, `is_confirmation?` | `never` with a `reason` (the never_learn_reason); `learn_by_rule` with a `fact` (kind, key, value, scope, status); `not_by_rule` (no rule fires, so a model would decide); `learn_by_model` with `fact_kind` and `value_contains`; or `none` (nothing stored) |
| `recipe_select` | `goal`, `aliases` (alias facts in the hints) | `expect_ids`, the built-in ids in order, with every recipe at confidence 0.8 |
| `builtin_recipe_safe` | `file` | every built-in recipe passes `check_allowed`, every `how` is at most 450 characters, and the ids are unique |

The native suites also test behaviours that are not in the file: thread safety (8 threads × 40 writes, never two live rows for a key), the prompt budget at 80, 200, 500 and 1200 characters, file modes, forgotten text absent from the raw database file, and the timing rule for "forget everything". The Swift package has all of them (section 15).

## 14. Open questions

**Unverified, to be checked once the screen agent and the hands exist:**

1. **UNVERIFIED: recipe text.** Most of it is written from general knowledge. Checked on this Mac so far (5 Nov): in WhatsApp the control at the send position reads button "Voice message" until text is typed and button "Send" afterwards, and the message box is text area "Compose message"; Spotlight has no window when closed, and one Escape only collapses it to the search field while a second closes it. Still to check: everything else, in particular whether Spotify's Cmd+K opens search, where WhatsApp's chat search field is, and the Calendar and Gmail button names. Each recipe's `checked` field in `Fixtures/recipes.json` records what has been confirmed.
2. **UNVERIFIED: the reflect prompt.** It has had a few live runs against `claude-haiku-5-5` (a generic recipe after a success; a pitfall after a failure, with no message text). The pitfall sometimes runs past 120 characters and is cut at a whole word. The failure-without-recipe path (8.3 step 5) is tested with a fake model; in its one live run (6 Nov) the model chose to store nothing, which is allowed, so the path is not yet proven live. A few runs are not an evaluation.

**Known limits:**

3. **Redaction is heuristic.** R1 to R4 cover the common phrasings of message wording, but an unusual one ("Ping Mum running late") would reach the episode log word for word. The secrets rules (5.5) catch named secrets and the numbers they name, but a bare code typed with no secret word anywhere in the task ("Typed 482913") is indistinguishable from any other number.
4. **The name-choice rule can over-learn.** Any shared-first-word choice is learned ("Google Docs or Google Sheets?"). This is harmless while it is a candidate; it is now offered as a check, so the user's yes or no decides.
5. **The Jev threshold of 0.15 is set from a single sample.**
6. **The voice summary is fixed when the session starts.** Facts learned mid-session need a contextual-update push from the voice layer.
7. **Forget keeps the key.** A forgotten row keeps its key (for example `priya`) as an audit marker; only the value and evidence are wiped.
8. **Matching by goal.** Memory's per-goal record matches answers and the end of a task to the hints by goal text, falling back to the latest offer of the last hour. That relies on one task at a time, which the task runner guarantees.

## 15. The Swift implementation (`Packages/HFMemory`)

Build and test: `cd Packages/HFMemory && swift build && swift test`. Live check of the prompts against Claude: `HF_LIVE=1 swift test --filter Live` (uses `ANTHROPIC_API_KEY` and `SMALL_MODEL` from `Settings.load()`; the key is only ever put in a request header).

| Spec | Swift |
|------|-------|
| Store (sections 2, 4, 7) | `MemoryStore` (`MemoryStore.swift`, `SQLiteDatabase.swift`): the system SQLite3 library, one connection behind one `NSRecursiveLock`, every write in `BEGIN IMMEDIATE`. Throws `SpeakableError` for refusals. |
| Fact with bookkeeping | `StoredFact`: the shared `HFCore.Fact` plus sightings, corrections, successes, failures, label, pitfalls, built-in id and version. |
| Rules (sections 3, 5) | `TextRules`, `HardRules` (including `redactSecrets`), `MessageContent`: the ICU patterns of this document, used as written through `NSRegularExpression`. |
| Retrieval (section 6) | `MemoryStore.search`, `selectRecipes(forGoal:hintFacts:)`, `memoryHints(forGoal:maxCharacters:) -> MemoryHints {text, factIDs, recipeIDs, suggestedIDs}`, `summaryForPrompt(maxCharacters:)`, `FactWording.describe`. |
| Learning (section 8) | `ExchangeRules` (the rules), `Learner` (`learn` and `reflect`, never throw), `LearningPrompts` (the prompts and schemas, read at runtime from the bundled copy of `docs/prompts/memory_learning.md`). The model is any `HFCore.StructuredLanguageModel` the app passes in. The optional Jev check is a closure, `LastingPreFilter = (question, answer, goal) async -> Double?`, returning p(lasting) or nil; below 0.15 the model is skipped. The question to ask it is `LearningPrompts.bundled?.lastingQuestion`. |
| The app's view | `Memory: MemoryProviding`. `hints(forGoal:)` returns the hints text and records, per goal, what it handed out (`hintDetails(forGoal:)` returns the full `MemoryHints` for tests and the memory panel). `learn(fromQuestion:options:answer:goal:)` handles a yes or no to an offered suggestion (7.13), else learns as in 8.1. `taskEnded` logs the episode (executor `"screen"`), reflects with the recipes recorded for that goal, and drops the record. Work goes on one background worker: the hand-off is synchronous, so `waitForBackgroundWork()` always covers a call that has returned. |
| Voice tools (section 9) | `MemoryTools.make(memory:) -> [ToolSpec]`, tier `.meta`; names, descriptions and schemas come from the bundled copy of `Fixtures/memory_tools.json`. |
| Built-in recipes (7.10, 12) | `BuiltInRecipe.bundled()` reads the bundled copy of `Fixtures/recipes.json`; `MemoryStore.openDefault(settings:)` seeds them, and `forgetAll` re-seeds them. |

**Differences from the language-neutral text.**
- The standing-choice kind is called `preference` (the prototype called it `default`). The model and the voice agent may still say `default`.
- `Source.builtIn` is stored as the text `builtIn`.
- Without a model, the rules still learn: a name choice such as "Priya Shah or Priya Patel?" → "Shah" needs no model. Everything else that needs a model is skipped.
- Pitfalls longer than 120 characters are cut at a whole word (section 7.6). The first live run showed a model writing past the limit.
- `forget_everything` is its own tool, with a `confirmed` flag, rather than a flag on `forget`. A separate tool with its own description is easier for the voice model to use correctly, and the two-step rule (ask, wait at least 2 seconds, then confirm) lives in it.

**Keeping the copies in step.** The masters are `Fixtures/recipes.json`, `Fixtures/memory_tools.json` and `docs/prompts/memory_learning.md`; edit those. `Packages/HFMemory/sync-resources.sh` copies them into `Sources/HFMemory/Resources/`. A test (`ResourceCopyTests`) fails if a copy differs from its master, so a forgotten sync cannot ship. The prompt file is parsed by its markers (`=== system ===` / `=== end ===` and the first ```` ```json ```` block under each "Output schema" heading), and a test checks that it parses.

**What the tests cover** (117 unit tests, no network, plus 4 live tests that are skipped unless HF_LIVE=1; Thread Sanitizer clean):
- the lifecycle: explicit beats learned, promotion on a second sighting, retirement with an audit trail, corrections, scopes;
- the hard rules: secrets refused, yes never learned, permission refused, message wording never stored;
- forgetting: values wiped on disk (the raw file is checked), the two-step forget-everything, built-in recipes restored;
- retrieval: search, the summary budget at 80, 200, 500 and 1200 characters, the hints block;
- recipes: seeding and version bumps, outcomes, pitfalls, a trusted learned recipe replacing a built-in one;
- suggestions: a candidate offered as a yes-or-no check, a yes promotes, a no retires, an unclear answer or a risky question changes nothing, the record dropped when the task ends;
- secrets in task text: the episode log, the reflection input and the exchange prompt never carry one;
- the hand-off: 50 rounds of learn-then-drain, and a drain that waits for jobs queued while draining;
- a failure with no recipe leaving a candidate recipe and its pitfall, and never promoting an existing one;
- infrastructure: episodes, file modes (a folder we create is 0700, an existing folder is left alone, the file is always 0600), 8 threads × 40 writes;
- every non-live line of `Fixtures/memory_cases.jsonl`, and the resource copies.
