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
3. **A task.** This is the default for anything on the Mac that is not an obvious one-step action: a particular song, a message, a booking, an email, a folder ("Sort out my downloads folder"), or two things at once ("Open Spotify and play something calm").
   - It starts one task straight away, without asking how to do it: the task works that out on the screen, and asks for a yes before deleting or sending anything.
   - The goal is one or two sentences, in the user's words plus what the agent knows: who, what, which app, and the exact words of any message. It contains no step-by-step instructions, because writing those only makes the user wait.
   - It says three or four words at most ("Writing to Amma.") and then goes quiet. The user is watching the pointer work. It never says what is on the screen unless a result said so.
   - The task's questions ("Emirates on Monday, or Qatar Airways on Friday?") and its confirmation ("Send 'I'm running late' to Amma?") come back from the Mac. The agent says them, and passes the user's reply back word for word.

Around those three choices:

- **When it is not sure,** it asks one short question ("Who should I message?"). When the words were garbled, it checks what you meant ("Did you want me to play At the Door by The Strokes?") rather than acting.
- **When a sentence is not for it** ("Hey Alexa, turn it down", "Sam, pass me the water"), or is a stray word with no request in it, it stays silent. It does not act, and it does not chatter back.
- **It only says something happened when a result says so.** A task that has started is running, not finished. A failure is said plainly.
- **It talks about itself like a person.** "I can open apps and websites, play music, send messages…". The words "tool", "function" and "call" never reach you.
- **"That's all, thanks" sends it to sleep at once,** with at most "Okay.". During a task it says once that it will stay until the task is done. **"Stop"** stops a task and it says "Stopped.".

### Staying silent: ElevenLabs' skip_turn

A voice agent normally answers every turn. ElevenLabs has a built-in system tool, `skip_turn`, that lets it say nothing until you speak again. The agent uses it in two places:

- right after a task starts, where it used to say "On it." a second time;
- for speech that is not meant for it, or a stray word with no request in it.

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

**The cases** are in `Packages/HFVoiceEval/Cases/cases.json`: 47 of them. The sentences were written fresh, following the patterns in the user's own conversations. Before the package was committed they were checked against those recordings:

- No case contains anything another person said, a real contact's name, the test contact or test email, a phone number or an address.
- The only lines that match the recordings word for word are a few of the user's own short requests ("Play At the Door by The Strokes.", "Can you open YouTube?", "Stop listening.", "Wait."), and the recogniser's mishearing of one of them ("Lay at the door, Brooks.").
- Two lines whose speaker could not be told were replaced with fresh ones. They fall into these groups:

| Group | What it checks | Cases |
|---|---|---|
| conversation | "Can you hear me?", "What can you do?", a fact, "Thanks." | 5 |
| quick | one quick action, the right one, no task | 6 |
| task | one complete task, a short line, then quiet | 2 |
| ambiguity | "Message him": one short question, no guess | 2 |
| honesty | never claiming what did not happen; failures said plainly; "What did you just do?" answered from the conversation | 5 |
| limits | what it can't do, in human words; a locked Mac (no offer to unlock, no password taken) | 4 |
| relay | a task's question, confirmation (with a change) and result | 3 |
| sleep | "Stop listening", "That's all", "Go to sleep", and the same during a task | 4 |
| not-for-me | words for Alexa, Siri or Sam, a television-like sentence, a garbled sentence, a stray word, an aside, and one meant for it without its name ("turn it down a bit"), which must still act | 9 |
| stop | "Stop" with nothing running, and during a task | 2 |
| default-task | anything on the Mac that is not one step goes straight to a task, with at most a few words first | 5 |

Try it: `cd Packages/HFVoiceEval && swift run hf-voice-eval run --model claude-sonnet-5-5 --reasoning low --skip-turn` (all cases, or `--only id,id`). `hf-voice-eval models` lists the models on the account; `hf-voice-eval last` shows how ElevenLabs recorded the latest evaluation conversations, including silent turns.

## Results

All runs were on 6 November, text mode, one run per row.

- **"Tool call"** is the median time from the user's sentence to the agent acting.
- **"First words"** is the median time to its first reply. In text mode that is the whole reply; in voice the first sound comes about 0.1 s after that (ElevenLabs' own logs show the speech starting 0.07 to 0.09 s after the text).

**The final configuration, three runs of the full 47 cases** (claude-sonnet-5-5, reasoning low, skip_turn, the final prompt):

| Run | Passed | Time to act (median) | First words (median) |
|---|---|---|---|
| 1 | 47 of 47 | 0.89 s | 1.57 s |
| 2 | 46 of 47 | 0.92 s | 1.57 s |
| 3 | 47 of 47 | 0.87 s | 1.61 s |

The one failure in 141 conversations was a 21-word reply after "Stop" ("The task has stopped. I can't say how many screenshots were moved…") where "Stopped." was wanted. So the run-to-run noise is about one case in 47.

**The set of 45 cases, before the last two cases and the last prompt pass.** These add eight cases to the first 37. Five prove the default ("Sort out my downloads folder", "Open Spotify and play something calm", an email reply, "Do I have anything on tomorrow afternoon?", a flight search). Two more are not meant for it (Siri, a television-like sentence). One is the counter-case that must still act ("It's a bit loud, turn it down a bit").

| Prompt | Model | Reasoning | Passed | Tool call (all) | Quick actions | Task starts | First words |
|---|---|---|---|---|---|---|---|
| final | **claude-sonnet-5-5** | **low** | **44 of 45** | **0.91 s** | 0.92 s | **0.99 s** (worst 1.25 s) | 1.59 s |
| one step earlier* | claude-haiku-5-5 | low | 41 of 45 | 0.84 s | 0.62 s | 1.24 s | 1.47 s |

*Before the last two prompt lines (shorter task goals; speak, never type, a task's question).

Haiku's failures on this set include the most worrying thing seen in any run. Relaying a task's confirmation, it called the typing action and **typed the question into whatever field had focus**, then apologised. In the app that field could have been the WhatsApp message box. Sonnet never did anything like it.

**The first 37 cases, as the prompt developed:**

| Prompt | Model | Reasoning | Silence tool | Passed | Tool call | First words | Replies starting "On it" |
|---|---|---|---|---|---|---|---|
| old (today's) | claude-haiku-5-5 | none | no | 23 | 0.71 s | 0.95 s | 13 of 73 |
| new | claude-haiku-5-5 | none | yes | 29 | 0.68 s | 0.85 s | 0 |
| new | claude-sonnet-5-5 | none | yes | 33 | 1.44 s | 1.48 s | 0 |
| new | claude-haiku-5-5 | low | yes | 34 | 0.79 s | 1.23 s | 0 |
| new | claude-sonnet-5-5 | low | yes | 36 | 0.87 s | 1.43 s | 0 |

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
6. **Reasoning "low" instead of "none".** This ended the spoken reasoning in every case: 36 of 37.
7. **Progress removed from the prompt.** The voice session now sends task progress only as background context, so there is nothing to answer.
8. **"A task is the default".** Anything on the Mac that is not an obvious one-step action becomes a task straight away. The agent says three or four words at most ("Sorting it now."), does not ask how, and never says what is on the screen unless a result said so. Sonnet had been asking "Do you want the files grouped by type, or old ones deleted?" for "Sort out my downloads folder". With this, and the reminder that the task asks for a yes before deleting anything, it starts the task. All 5 default cases passed.
9. **"Speak a task's question; never type it"**, after Haiku typed one into the focused field.
10. **"Keep the goal to one or two sentences, with no steps"**. Sonnet's goals had been long how-to paragraphs, and writing them made the user wait. Task starts went from a median 1.59 s to 0.99 s. The full run: 44 of 45.
11. **Three lines from the first runs through the built app.**
    - "To say what you just did, answer from this conversation". Asked "What did you just do?", it had been looking up past tasks.
    - "If a result says the Mac is locked, say so once and stop: never offer to unlock it, never ask for or accept a password". The app now answers every action this way while the screen is locked.
    - "Words said before a result say what you are doing, never that it is done", because its words are spoken before the action has answered.
12. **The two weak spots.**
    - A task's result is now one sentence of about fifteen words, plus one short next step if it is not what was asked. The invoice reply went from 29 words to 13: "That's March's invoice, not this month's. Shall I look again for November's?"
    - A garbled sentence that sounds like a request gets its best guess checked ("Did you want At the Door by The Strokes?") rather than silence.

## The model chosen, and why

**claude-sonnet-5-5, with `reasoning_effort: low` and `skip_turn` on.** The backups are claude-haiku-5-5, then claude-haiku-4-5.

The rule set beforehand was: choose Sonnet only if its median time to act stays under about 1.5 s and it clearly wins on the cases that matter; otherwise keep Haiku with the new prompt. Sonnet meets both. Its median time to act is 0.91 s, and its task starts are 0.99 s at the median and 1.25 s at worst. It wins on the cases that matter:

- **It never did anything unsafe or untrue.**
  - Haiku typed a task's question into the focused field.
  - Haiku with reasoning off said "YouTube is open now." before the task's result, the exact failure the user saw.
  - Sonnet never claimed success early in any run.
- **It is the one that understood.**
  - It turned "Lay at the door, Brooks" into "Did you want me to play At the Door by The Strokes?".
  - It noticed a downloaded invoice was March's, not this month's, and offered to look again.
  - When the scripted task asked about the old wording after the user had said "No, say ten minutes late.", Sonnet noticed and asked whether to cancel.
- **Reasoning "low" keeps its thinking out of its speech.** With reasoning off, both models sometimes said their decision out loud ("The user addressed Alexa, not me, so I stay silent.") or wrote the tool's name. With "low", that never happened in either full run.
- **The price:**
  - Quick commands are about 0.3 s slower than Haiku's (0.92 s against 0.62 s).
  - First words come about 0.1 s later (1.59 s against 1.47 s).
  - Task starts are faster than Haiku's measured ones (0.99 s against 1.24 s), but Haiku's figure is from the prompt before goals were shortened, so it probably overstates the gap.

  The user asked for smarter over faster, and this is smarter for about a third of a second on a volume change.
- **Haiku with reasoning low is the runner-up.** If speed ever matters more than judgement, it is the next choice, and it would need its own run on the final prompt first.

## What it still gets wrong

- **Long replies to news.** It sometimes explains more than needed: a 29-word reply about the invoice, which was smart but long.
- **Garbled words.** It sometimes stays silent where a short "Did you mean…?" would be better.
- **Text mode only.** These runs used typed sentences. Real speech brings mistranscriptions, a person talking over the agent, and "stop" said while it is speaking, which text mode cannot test. All of that needs a spoken run in the app.
- **One run per row.** A difference of one or two cases between rows is within the noise.
- **Cost: not measured.** Sonnet's tokens cost more than Haiku's, and reasoning "low" adds hidden thinking tokens, so a conversation costs more than it did. How much more was not measured: the evaluation did not read ElevenLabs' charges for its conversations. One of the user's recorded voice conversations, 91 seconds on Haiku, shows the call charge (560 credits) far larger than the language model's (89 credits). That suggests the model's share is small, but it is one example on a different model, not a measurement.

## Things outside the prompt that affect how it sounds

- **A silent turn delays task news.** After the agent stays silent (for example after passing an answer on), the voice session still waits for a reply that never comes, and holds the task's next message. That was 4.7 s in one measurement, against about 1 s after a spoken turn. The fix belongs in HFVoice (treat the silent turn as finished), and has been passed to its owner.
- **Progress notes** now go only as background context (changed in HFVoice on 6 November), so they no longer make the agent say "Nothing to add yet."
- **The evaluation's scripted tasks are simple.** A task's question does not change when the goal changes, so a corrected message is asked about with the old words. Sonnet noticed and asked whether to cancel, which is right. But the case cannot test a task that really uses the correction.
