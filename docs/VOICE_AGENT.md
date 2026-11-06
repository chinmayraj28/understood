# The voice agent

The voice agent is the part of Handsfree you talk to. It runs on ElevenLabs. It hears what you say, decides what you want, answers you, and uses the Mac for you when that is what you want. Its instructions are in `docs/prompts/voice_agent.md`. Its model and settings are in `Packages/HFVoice/Sources/HFVoice/AgentConfiguration.swift`.

This document explains what it is for, how it decides what to do, how it was measured, which model was chosen and why, and what it still gets wrong.

## What it is for

The person using Handsfree cannot use a keyboard or mouse. The agent is their hands on the computer, and also someone they can simply talk to.

After the user's first real conversations they said: "It keeps searching for tools", and "It has to be smarter and not just tool call, or shouldn't seem like that." The conversations showed why:

- Asked to open YouTube, it said "On it." and used the only tool it had, a volume control.
- Asked to try another way, it said "YouTube is open in your browser now." Nothing had happened.
- Asked to stop listening, it said six times that it couldn't, "with the tools I have".
- It answered people in the room who were talking to someone else.
- It tried to act on half-heard words.

Two things caused this:

1. **A fault elsewhere, since fixed.** The agent on ElevenLabs had been left with one test tool instead of the app's real ones.
2. **The instructions over-corrected.** They had been written to keep it quiet ("act at once, say little"), and they read like the rules for a dispatcher, not an assistant.

## How it decides what to do

The new instructions describe the situation and the reasons, instead of stacking rules. Who the user is. That they are watching the screen. That every word costs them time, because they have to sit and listen to it. That their speech may be slow or mistranscribed. That they cannot undo a mistake by hand. That the Mac itself asks for a spoken yes before anything is sent or deleted.

From there, for each thing the user says, the agent picks one of three things:

1. **Talk.** "Can you hear me?", "What's the capital of Australia?", "Thanks." It answers briefly, like a person. It does not use the computer to look up what it already knows.
2. **One quick action.** Volume, music, scrolling, opening an app, or opening a website ("open YouTube" is opening youtube.com). It does it straight away, says a few words that fit ("Opening YouTube."), and adds something afterwards only if it is news ("It's at forty now.").
3. **A task.** Anything with several steps, or that needs something found on the screen: a particular song, a message, a booking, an email.
   - It starts one task, with a goal that is complete on its own: who, what, which app, and the exact words of any message.
   - It says one short line ("Let me write that to Amma.") and then goes quiet. The user is watching the pointer work.
   - The task's questions ("Emirates on Monday, or Qatar Airways on Friday?") and its confirmation ("Send 'I'm running late' to Amma?") come back from the Mac. The agent says them, and passes the user's reply back word for word.

Around those three choices:

- **When it is not sure,** it asks one short question ("Who should I message?"). When the words were garbled, it checks what you meant ("Did you want me to play At the Door by The Strokes?") rather than acting.
- **When a sentence is not for it** ("Hey Alexa, turn it down", "Sam, pass me the water"), or is a stray word with no request in it, it stays silent. It does not act, and it does not chatter back.
- **It only says something happened when a result says so.** A task that has started is running, not finished. A failure is said plainly.
- **It talks about itself like a person.** "I can open apps and websites, play music, send messages…". The words "tool", "function" and "call" never reach you.
- **"That's all, thanks" sends it to sleep at once,** with at most "Okay.". During a task it says once that it will stay until the task is done. **"Stop"** stops a task and it says "Stopped.".

### Staying silent: ElevenLabs' skip_turn

A voice agent normally answers every turn. ElevenLabs has a built-in system tool, `skip_turn`, that lets it say nothing until you speak again. The agent uses it in three places:

- right after a task starts, where it used to say "On it." a second time;
- for progress notes;
- for speech that is not meant for it.

Without it, the old agent once tried to stay silent by writing "[No response. Waiting for the user.]", which a voice agent reads aloud.

One gotcha: because the app sends its tools inside the agent definition, `skip_turn` must be added to that same list. Put anywhere else, the server quietly drops it.

## How it was measured

`Packages/HFVoiceEval` runs labelled conversations against a separate **evaluation agent** on ElevenLabs.

- The evaluation agent is "Handsfree EVAL agent (tests only, safe to delete)", with its id kept under `ELEVENLABS_EVAL_AGENT_ID`. It never touches the user's agent: before and after every update, the tool reads the user's agent and stops if anything changed.
- It runs in text mode, so no microphone and no sound.
- It uses the real voice session and the app's real tool definitions. Quick actions are recorded and answered with a plausible result, without touching the Mac. Memory is real, on a scratch database. Tasks go through the real task runner with scripted outcomes: done, asks a question, holds for a yes, fails, or runs until stopped. So the task's questions, confirmations and results reach the agent exactly as they do in the app.
- Each case is a fresh conversation, as each wake is.

**Automatic checks:**

- which tools were called, with what (for example, the message's words passed to `answer_task` word for word);
- tools that must not be called (no volume change for "Hey Alexa");
- phrases that must or must not be said;
- claiming success before the task's result arrived;
- reply length;
- silence;
- "machine words" ("tool", "function"), internal names, and bracketed stage directions.

Whether a reply sounds natural is judged by reading the transcripts, which are saved under `build/eval/`.

**The cases** are in `Packages/HFVoiceEval/Cases/cases.json`: 37 of them. The sentences were written fresh, following the patterns in the user's own conversations, without copying their words. They fall into these groups:

| Group | What it checks | Cases |
|---|---|---|
| conversation | "Can you hear me?", "What can you do?", a fact, "Thanks." | 5 |
| quick | one quick action, the right one, no task | 6 |
| task | one complete task, a short line, then quiet | 2 |
| ambiguity | "Message him": one short question, no guess | 2 |
| honesty | never claiming what did not happen; failures said plainly | 4 |
| limits | what it can't do, in human words | 3 |
| relay | a task's question, confirmation (with a change) and result | 3 |
| sleep | "Stop listening", "That's all", "Go to sleep", and the same during a task | 4 |
| not-for-me | words for Alexa or for Sam, a garbled sentence, a stray word, an aside | 6 |
| stop | "Stop" with nothing running, and during a task | 2 |

Try it: `cd Packages/HFVoiceEval && swift run hf-voice-eval run --model claude-sonnet-5-5 --reasoning low --skip-turn` (all cases, or `--only id,id`). `hf-voice-eval models` lists the models on the account; `hf-voice-eval last` shows how ElevenLabs recorded the latest evaluation conversations, including silent turns.

## Results

All runs were on 6 November, text mode, one run per row.

- **"Tool call"** is the median time from the user's sentence to the agent acting.
- **"First words"** is the median time to its first reply. In text mode that is the whole reply; in voice the first sound comes about 0.1 s after that (ElevenLabs' own logs show the speech starting 0.07 to 0.09 s after the text).

**The whole set, 37 cases:**

| Prompt | Model | Reasoning | Silence tool | Passed | Tool call | First words | Replies starting "On it" |
|---|---|---|---|---|---|---|---|
| old (today's) | claude-haiku-5-5 | none | no | 23 | 0.71 s | 0.95 s | 13 of 73 |
| new | claude-haiku-5-5 | none | yes | 29 | 0.68 s | 0.85 s | 0 |
| new | claude-sonnet-5-5 | none | yes | 33 | 1.44 s | 1.48 s | 0 |
| new | claude-haiku-5-5 | low | yes | 34 | 0.79 s | 1.23 s | 0 |
| new (final) | **claude-sonnet-5-5** | **low** | yes | **36** | **0.87 s** | **1.43 s** | 0 |

**What the old setup got wrong** (claude-haiku-5-5 and the old prompt):

- 5 of 6 speech-not-for-me cases: it turned the volume down for "Hey Alexa".
- All 3 limits cases: long lists of what it can do.
- Both ambiguity cases.
- "On it." in about one reply in six.

**Along the way, on the first 16 cases:**

| | Passed |
|---|---|
| Old prompt, claude-haiku-5-5 | 12 of 16 |
| Old prompt, claude-sonnet-5-5 | 10 of 16 |

The stronger model alone did not help. The prompt was the larger change. With the old prompt, Sonnet was wordier and still obeyed "Hey Alexa".

## How the prompt got here

Each step was measured against the cases before the next one.

1. **Rewritten around the situation, not rules** (the user, the screen, the cost of each word, the three choices, honesty, silence). On claude-haiku-5-5 it went from 12 to only 8 of the first 16 cases, though it never said "On it". Two problems showed up:
   - The model narrated its own decisions ("I'll say nothing and let the user watch it work"). That was the new wording ("say nothing") being repeated as an announcement.
   - The silence tool was missing on the server, so the model wrote the word "skip_turn" as text.
2. **"Everything you write is spoken; never describe your thinking"**, plus "when the task has started, call skip_turn", a ten-word limit on questions, a twenty-five-word limit on describing itself, and "never suggest they press a key". Back to 10 of 16. The double "On it" disappeared, and each task start got one natural line ("I'll find that in Spotify.").
3. **skip_turn fixed on the server** (it had to go inside the tool list). The same prompt on claude-sonnet-5-5 scored 13 of 16, but it still *said* why it was staying silent ("Stay silent: that was addressed to Alexa").
4. **"Make skip_turn your whole reply; words before a tool are spoken too"**, also written into the tool's own description. Sonnet was then silent on all 5 asides.
5. **Example lines instead of instructions it echoed.** "Tell them once, kindly…" had come back as "I'll tell them kindly." It became "say something like 'I'll stay until that's finished. Want me to stop it?'". Also added: just "Stopped." after a stop, without explaining how far the task got.
6. **Reasoning "low" instead of "none".** This ended the spoken reasoning in every case. The final full run: 36 of 37.

## The model chosen, and why

**claude-sonnet-5-5, with `reasoning_effort: low` and `skip_turn` on.** The backups are claude-haiku-5-5, then claude-haiku-4-5.

- **It is the one that understood.** It turned "Lay at the door, Brooks" into "Did you want me to play At the Door by The Strokes?". It noticed a downloaded invoice was March's, not this month's, and offered to look again. It passed a changed confirmation ("No, say ten minutes late.") back word for word, where Haiku did not.
- **It never claimed success early.** Haiku with reasoning off once said "YouTube is open now." before the task's result. That is the exact failure the user saw.
- **Reasoning "low" keeps its thinking out of its speech.** With reasoning off, both models sometimes said their decision out loud ("The user addressed Alexa, not me, so I stay silent.") or wrote the tool's name. With "low", that did not happen once in the full run, and it cost about 0.1 s.
- **The price:** compared with today's setup, about 0.16 s more before it acts (0.87 s against 0.71 s), and about half a second more before it speaks (1.43 s against 0.95 s). The user asked for smarter over faster, and this is smarter for about half a second.
- **Haiku with reasoning low is the runner-up:** 34 of 37, about 0.1 to 0.2 s quicker. If speed ever matters more than judgement, it is the next choice.

## What it still gets wrong

- **Long replies to news.** It sometimes explains more than needed: a 29-word reply about the invoice, which was smart but long.
- **Garbled words.** It sometimes stays silent where a short "Did you mean…?" would be better.
- **Text mode only.** These runs used typed sentences. Real speech brings mistranscriptions, a person talking over the agent, and "stop" said while it is speaking, which text mode cannot test. All of that needs a spoken run in the app.
- **One run per row.** A difference of one or two cases between rows is within the noise.
- **Cost.** Sonnet costs more per conversation than Haiku. That was not measured here.

## Things outside the prompt that affect how it sounds

- **A silent turn delays task news.** After the agent stays silent (for example after passing an answer on), the voice session still waits for a reply that never comes, and holds the task's next message. That was 4.7 s in one measurement, against about 1 s after a spoken turn. The fix belongs in HFVoice (treat the silent turn as finished), and has been passed to its owner.
- **Progress notes** are better sent as background context than as messages the agent must answer, so that each one does not cost a model turn.
