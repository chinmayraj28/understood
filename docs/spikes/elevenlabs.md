# Spike: the ElevenLabs voice agent

This spike checked, by running them, the things the voice layer depends on: how client tools work, how the Mac can make the agent speak when a task has news, turn-taking for slow speech, injecting memory, which LLM to use, when transcripts arrive, audio and echo, and what happens when the connection drops.

**How it was tested.** Everything was run on 5 Nov 2026 on this Mac, against the real ElevenLabs service, in two rounds.
1. **The platform**, with the Python SDK `elevenlabs` 2.76.0 (sections 1 to 9). Most runs were in text mode: a conversation with no microphone, driven by typed user messages. The audio runs used a fake microphone that streamed synthetic speech in real time, and the real MacBook Air microphone and speakers.
2. **The Swift app's path**, through `Packages/HFVoice` on the ElevenLabs Swift SDK 3.4.0 ([section 10](#10-the-swift-sdk-verified)): a live text conversation, and a live speaker-and-microphone echo test.

**Why the Python results still apply.** Everything about the *agent* and the *server* is the same in both languages: the agent configuration, the tool settings, how the agent reacts to messages, turn-taking, timings and limits. Python-only behaviour is labelled **(Python SDK)**. Section 10 says what the Swift SDK does differently, from its source code and from runs.

**The agent.**
- Name: "Hands-Free Laptop Agent". Id: `agent_4101m6pjbz9zex3sp2dv1fsdb2fp`, stored in `.env` as `ELEVENLABS_AGENT_ID` by `swift run hf-voice setup`.
- `AgentConfiguration` in `Packages/HFVoice` defines it in code ([section 11](#11-the-agent-configuration)). The prompt is `docs/prompts/voice_agent.md`.

**The Python spike scripts are retired.** They are in `legacy_python/scripts/spikes/voice/`, a folder that is ignored by git and will be deleted. They are kept for reading only and must not be run. This document is the lasting record of their numbers. The Swift live tests in `Packages/HFVoice/Tests/HFVoiceTests/LiveVoiceTests.swift` repeat the checks that matter for the app.

---

## Summary

| # | Question | Answer | How sure |
|---|----------|--------|----------|
| 1 | Client tools | They work. The handler is called and its result reaches the agent in about 0.1 s. **The result must be a string.** A JSON object closes the whole conversation. The timeout is 1 to 120 s, or -1 for no limit. In Swift, the SDK's `String` result is used, and the tool call arrives 0.59 to 0.65 s after a typed message. | Ran it (Python and Swift) |
| 2 | Making the agent speak without the user | Send a marked user message (`[APP] ...`). It speaks within about 1.4 s in Python and 0.46 to 0.49 s through `VoiceSession.push`. Send it only when the agent is not talking, because it cuts the agent off; `VoiceSession` queues until then. Contextual updates and `async` tools never make it speak. A blocking `wait_for_task` tool breaks as soon as the user says anything. | Ran it (Python and Swift) |
| 3 | Turn-taking | `turn_eagerness: patient` and `turn_timeout` are saved as set. `turn_timeout: -1` stops the "are you still there?" nagging. A 1.5 s pause inside a sentence is waited out; a 3 s pause is not. | Ran it |
| 4 | Memory in the prompt | `{{user_memory}}` is filled from the dynamic variables sent at session start. If it is missing, the placeholder is used, with no error. | Ran it |
| 5 | LLM | **claude-haiku-5-5 with reasoning off.** Median 0.61 s to the tool call, and 78 of 78 behaviour checks passed. Backups: claude-haiku-4-5, then gpt-4.1-mini. | Ran it |
| 6 | Transcript timing | The final transcript comes about 0.4 to 0.9 s after the user stops speaking, at the same moment as the tool call. It still arrives while a tool is running. Earlier signals: `vad_score` about 0.1 s after speech starts, and `interruption` about 0.37 s after. Both reach Swift as `onVadScore` and `onInterruption`. Tentative transcripts never arrived, and the Swift SDK discards them anyway. | Ran it (Python); Swift from source |
| 7 | Audio and echo | **The Python SDK has no echo handling.** On laptop speakers the agent heard itself and spiralled: 6 self-interruptions in 25 s. **The Swift SDK's audio path uses Apple's voice processing.** With the mic proven live, the agent spoke for 25 s at the same volume with 0 interruptions and 0 echo transcripts. | Ran it (Python and Swift) |
| 8 | Dropped connection | Python reports the drop at once (code 1006), but the session objects cannot be reused. The server ends every session after at most 2 hours (code 1000). A new session remembers nothing, so reconnecting means a fresh session with the context injected again. `VoiceSession` does exactly that, with growing gaps between attempts (unit-tested with a fake SDK). | Ran it (Python); Swift unit-tested |

---

## 1. Client tools

### How a tool is declared

The tool goes in the agent's configuration under `conversation_config.agent.prompt.tools`. This is the JSON the server accepted and saved:

```json
{
  "type": "client",
  "name": "set_volume",
  "description": "Set the Mac's output volume. 'Volume to 30' -> percent 30.",
  "parameters": {
    "type": "object",
    "properties": {"percent": {"type": "integer", "description": "0 to 100"}},
    "required": ["percent"]
  },
  "expects_response": true,
  "response_timeout_secs": 20,
  "interruption_mode": "allow",
  "pre_tool_speech": "off",
  "execution_mode": "immediate"
}
```

The settings mean this:

| Setting | Values (from the SDK's types and checked against the server) | What to use |
|---------|------------------------------|-------------|
| `expects_response` | `true` means the agent waits for our result before it carries on | `true` for every tool |
| `response_timeout_secs` | **1 to 120, or -1 for "wait for ever"** (-1 needs `expects_response`). Default 20 | Take it from `ToolSpec.timeoutSeconds` |
| `interruption_mode` | `allow` (default), `disable_during_tool`, `disable_during_tool_and_turn` | `allow` everywhere, so the user can always talk over the agent |
| `pre_tool_speech` | `auto` (default: the agent decides from recent tool latency), `force`, `off` | `off`, so small commands get no filler ("Let me do that...") |
| `execution_mode` | `immediate` (default), `post_tool_speech`, `async` | `immediate`. `async` is described in [section 2](#2-making-the-agent-speak-without-the-user-speaking) |
| also available | `tool_call_sound`, `tool_call_sound_behavior`, `tool_error_handling_mode` (`auto`, `summarized`, `passthrough`, `hide`), `assignments` (copy a value from the result into a dynamic variable) | not needed |

**Tools listed inside the agent are deprecated, but they still work and stay in sync.**
- The API describes `prompt.tools` as "use `tool_ids` instead".
- When we sent tools inside the agent, the server created a standalone workspace tool for each one and saved their ids under `prompt.tool_ids`.
- Sending the same list again kept the same ids, so nothing was duplicated.
- Changing the list removed the tools that had gone: the 4 spike tools disappeared from the workspace when the real list replaced them. The workspace now holds exactly 9 tools.

So a create-or-update that sends the full tool list each time is idempotent today. The supported route is different:
1. Create or update each tool through `/v1/convai/tools`.
2. Set `prompt.tool_ids` on the agent.

This needs more code, but it will not break when the deprecated field is removed. Either route works this week.

### What happened when the agent called a tool

Command: "Set the volume to 30 percent.", sent as text.

| Time (s) | Event |
|----------|-------|
| 0.601 | We sent the user message |
| 1.119 | `agent_tool_request` and `client_tool_call` arrived, with `{"percent": 30}` |
| 1.120 | Our handler ran |
| 1.232 | `agent_tool_response` arrived, with status `success` |
| 1.643 | The agent replied: "The volume is now set to thirty percent." |

- **The result must be a string.** When the handler returned a Python dict, the server closed the websocket with **1008 "Invalid message received"** and the whole conversation ended. With `json.dumps(...)` it worked.
  - In Swift, `VoiceSession` uses the SDK's `String` overload of `sendToolResult` with JSON text. The SDK's source shows its `Encodable` overload also encodes to a string first ([section 10](#10-the-swift-sdk-verified)).
- **(Python SDK)** The handler's `params` include an extra `tool_call_id` key. Remove it before validating.
- **(Python SDK)** Synchronous handlers run on a thread pool (`ThreadPoolExecutor-0_0`). Handlers registered with `is_async=True` run on the SDK's own event-loop thread (`ClientTools-EventLoop`). Both worked.
- A tool the agent knows about but the app never registered fails with an error. The agent then tells the user "the volume control isn't available". It does not crash.

## 2. Making the agent speak without the user speaking

A task running in the background has to be able to say "Priya Shah or Priya Patel?" or "Done" while the user is silent. Four ways were tested, each in a fresh conversation.

| Option | What happened | Verdict |
|--------|---------------|---------|
| **(a)** `send_user_message("[SYSTEM] Task t1 needs input. Ask the user: Priya Shah or Priya Patel?")` | The agent said "Which Priya do you mean, Priya Shah or Priya Patel?" **1.36 s** after we sent it. | **Works** |
| **(b)** `send_contextual_update("Task t1 finished: ...")` | The agent stayed **silent for 15 s**. When the user then asked "Any news on my task?", it answered from the update. | Silent, but the agent keeps it in context |
| **(c)** A blocking `wait_for_task` tool (`expects_response: true`, `response_timeout_secs: -1`). The handler waits until the task has news | When the handler returned, the agent asked the question **0.71 s** later. But when the user said anything while it was waiting ("what's two plus two?"), the server sent `interruption`, marked the waiting call as failed (`is_called: false`), answered the user, and **never called `wait_for_task` again**. Our handler stayed blocked, holding a thread, and its later result was silently dropped. | **Breaks** on the first thing the user says |
| **(d)** A tool with `execution_mode: "async"` that returns after 10 s | The agent replied at once: "I'll share the result as soon as it comes in." The result arrived at 12.5 s and the agent **said nothing** in the next 18 s. | Silent. It also made a promise it did not keep |

Two more runs tested option (a) under pressure:
- **Pushing while the agent is talking cuts it off.** We pushed a result while the agent was telling a long story. The server sent `interruption`, the story stopped at "...", and the agent announced the result.
- **Two pushes sent back to back are merged into one turn.** The agent said one sentence covering both: "Chrome is open, and I need to know: should I use your work or personal Google account?"
- **A pushed message is not echoed back as a user transcript**, in text mode or audio mode. So the stop watcher never sees our own `[APP]` messages.

### Recommendation: a marked user message, sent only when the agent is listening

`push(_ event: TaskEvent)` should work like this:

1. **Questions, confirmations and results are spoken.** Send each one as a user message that starts with `[APP]` and says what to do with it:
   - A question: `[APP] Task t1 asks: Two contacts match. Priya Shah or Priya Patel? Options: Priya Shah, Priya Patel. Ask the user and pass their reply to answer_task.`
   - A confirmation: `[APP] Task t1 needs a clear yes before it goes ahead: Send the message "..." to Amma on WhatsApp? Read it back to the user and pass their exact reply to answer_task.`
   - A result: `[APP] Task t1 finished: <summary>. Tell the user.` The same form is used for failed and cancelled tasks.
2. **Progress is not spoken.** Send it with `send_contextual_update` as `Task t1 progress: Opening Google Calendar.`. The agent can then answer "how's it going?" without breaking the silence every few seconds.
3. **Wait until the agent is listening.**
   - Keep spoken events in a queue. Send them only when the agent is neither speaking nor working out a reply, and the user has not spoken for about 0.8 s (VAD below 0.5).
   - The Swift SDK reports the agent's state (`listening`, `speaking`, `thinking`) and calls `onVadScore` with the voice-activity score, so both checks are cheap.
   - If several events are waiting, send them as one message.
   - After about 10 s, send anyway: a lost question is worse than cutting the agent off.
4. **The prompt explains `[APP]` messages** (`docs/prompts/voice_agent.md`): they are not the user speaking, they are never a yes, and the agent relays them in its own short words.
   - In the prompt test, the agent never answered a confirmation for the user (checked in all 8 runs, across 4 models).
   - It read back each confirmation and passed the user's exact "Yes, send it." to `answer_task`.

**Built.** `PushQueue` and `VoiceSession.push` in `Packages/HFVoice` implement this, with these ordering rules:
- Questions, confirmations and results are never dropped and never reordered.
- A newer progress line replaces an older one.
- A question, confirmation or result removes any progress line still waiting, and no new progress is queued behind it.
- A progress line that has waited more than 6 s is dropped rather than said late.
- If sending fails, the events go back to the front of the queue and are sent after reconnecting.

**How it can go wrong, and what covers it.**

| What can go wrong | Example | What covers it |
|-------------------|---------|----------------|
| A push arrives while the agent is talking | The agent's sentence is cut off | The listening check in step 3. Without it, this happens every time (seen in the stress test) |
| The user starts talking just as a push goes out | The two turns run together | The agent hears both, which is acceptable. The VAD check makes this rare |
| The agent treats the event as something the user said | It treats "Send the invite?" as the user agreeing | The prompt rule (passed every time in testing), and the task runner's own yes/no classifier, which reads the user's actual reply |
| The connection is down when an event fires | A "Done" is lost | Keep it in the queue and send it after reconnecting ([section 8](#8-dropped-connection-and-reconnecting)) |
| The conversation history shows these as user turns | They look like the user's words in the dashboard | Cosmetic only |

## 3. Turn-taking for slow or paused speech

- **The values are saved as set.**
  - `turn_eagerness: "patient"` read back as patient. The allowed values are `patient`, `normal` and `eager`.
  - `turn_timeout` read back exactly as 10, 20, 30, 31, 60, 300 and -1.
- **`turn_timeout` is how long the agent waits for the user before speaking up itself.** It only matters with a microphone; in text mode the agent never spoke up.
  - **At 5 s** (fake mic, one command, then 22 s of silence), the agent said "Are you still there? Let me know if you need anything else." at 14.4 s, and again at 23.1 s.
  - **At -1** it never spoke unprompted.
  - **Use -1.** This assistant is on all day, and silence is normal. A question the task asked stays open in the task runner until it is answered.
- **Pauses in the middle of a sentence** were tested with "Send a message to" + a gap + "Mum saying I'm running late":
  - **1.5 s gap:** one turn: "Send a message to... Mom's saying I'm running late."
  - **3.0 s gap:** two turns. The agent jumped in after the first half with "Who would you like to message?"
  - A prompt can't fix how long the server waits. What it can do is make the agent answer a cut-off sentence with "Go on." rather than guessing. That passed in every prompt test.
- **Other settings worth knowing**, as read back from the agent:

| Setting | Default seen | Recommendation |
|---------|--------------|----------------|
| `silence_end_call_timeout` | -1 (never hang up) | Keep -1 |
| `conversation.max_duration_seconds` | **600 s**. The server accepts **60 to 7200** | **7200**. With the default, every session ends after 10 minutes |
| `speculative_turn` | true | Keep. The LLM starts while the user may still be finishing, which cuts latency |
| `spelling_patience` | auto | Keep. It waits longer while the user spells names and numbers |
| `turn_model` / `mode` | `turn_v3` / `turn` | Keep |
| `soft_timeout_config` | off (-1) | Keep off. When on, it plays a filler line ("Hhmmmm...yeah.") if the LLM is slow |
| `interruption_ignore_terms` | empty | Leave empty. Words like "okay" can be real answers |
| `retranscribe_on_turn_timeout`, `initial_wait_time`, `noisy_environment_detection` | off / unset / off | Not needed |

The real test of slow speech is a person speaking. The synthetic clips only prove the timing mechanics.

## 4. Memory in the system prompt (dynamic variables)

- **Set-up:**
  - The prompt contains `{{user_memory}}`.
  - The agent declares a default: `conversation_config.agent.dynamic_variables.dynamic_variable_placeholders = {"user_memory": "Nothing yet."}`.
  - At session start we sent `dynamic_variables = {"user_memory": "- Mum is called 'Amma' in WhatsApp.\n- Favourite volume is 40 percent.\n- Pet's name is Biscuit."}`.
- **Result:**
  - We asked "What is my pet called, and what is Mum called in WhatsApp?"
  - The agent replied "Your pet is called Biscuit, and Mum is saved as Amma in WhatsApp." So a multi-line value works.
  - With no value sent, the agent said it did not know. There was no error: the default was used.
- **In Swift** this is `ConversationConfig.dynamicVariables: [String: String]`.
- The `timezone` prompt setting (`Europe/London` here) puts the current time in the prompt, which "tomorrow at three" needs. In Swift, take it from `TimeZone.current`.

## 5. Which LLM

The account offers about 60 current models, including claude-haiku/sonnet/opus 4.x and 5.x, gemini 3.x, gpt-4.1, gpt-5.x and gpt-6, plus about 50 deprecated ones. Get the live list with `GET /v1/convai/llm/list`.

**Speed.** One text conversation per model, five volume commands each. "Tool call" is the time from the user message to `client_tool_call`. "Reply" is the time to the agent's text reply.

| Model (reasoning setting) | Tool call: median, 5 runs | Reply: median | Correct tool and value |
|---|---|---|---|
| gemini-3.5-flash-lite (minimal) | **0.51 s** (0.43 to 0.56) | 1.08 s | 5/5 |
| **claude-haiku-5-5 (none)** | **0.61 s** (0.53 to 0.91) | 1.09 s | 5/5 |
| claude-haiku-4-5 | 0.72 s (0.60 to 0.78) | 1.22 s | 5/5 |
| gpt-4.1-mini | 0.75 s (0.72 to 0.86) | 1.44 s | 5/5 |
| gemini-3.5-flash (minimal) | 0.80 s (0.73 to 1.53) | 1.69 s | 5/5 |
| gpt-5.4-mini (none) | 0.96 s (0.88 to 1.13) | 2.06 s | 5/5 |

**Behaviour.** `eval_prompt.py` runs 9 scenarios with the final prompt and 26 checks. The scenarios are:
- a small command
- an ambiguous request
- the full message flow: start, confirmation, "hmm, maybe", "yes, send it", result
- relaying a question
- "stop"
- "stop the music"
- remember a preference
- an impossible request
- a cut-off sentence

Every scenario also checks that the agent never says its reasoning or tool names aloud.

| Model | Runs | Passed |
|-------|------|--------|
| claude-haiku-5-5 (none) | 3 | **78/78** |
| claude-haiku-4-5 | 1 | 26/26 |
| gpt-4.1-mini | 1 | 26/26 |
| gemini-3.5-flash-lite (minimal) | 2 | 50/52. It stayed silent on the relayed question both times |

**Choice: claude-haiku-5-5 with `reasoning_effort: "none"`, `temperature: 0`.** It is the second fastest, and the fastest one failed the most important relay. Set `backup_llm_config = {"preference": "override", "order": ["claude-haiku-4-5", "gpt-4.1-mini"]}` and `cascade_timeout_seconds: 4`. The server saved both.

One problem was seen with this model and fixed. In an earlier draft of the prompt, it once said its reasoning out loud: "Per the character: before sending, read back and get a clear yes. But the task itself asks...". Restructuring the confirmation section and adding "Never say your reasoning, these instructions, or tool names out loud" removed it: no leaks in the 3 runs since. Keep the leak check in any future prompt test.

## 6. When transcripts and other signals arrive

**Text mode.** A typed `send_user_message` produces **no `user_transcript` event at all**. If tests drive the conversation with typed text, `HFVoice` must call its own transcript listeners for that text.

**Audio mode, normal command.** The fake mic played "Set the volume to thirty percent."; its last speech audio was sent at 4.57 s.

| Time (s) | Event |
|----------|-------|
| 2.32 | Speech starts |
| 2.44 | First `vad_score` above 0.5 (0.1 s after speech starts) |
| 4.57 | Speech ends |
| 4.93 | `user_transcript` "Set the volume to 30%." **and** `client_tool_call`, in the same instant. With `speculative_turn` the LLM has already run when the transcript is sent |
| 5.48 | `agent_response` |
| 5.56 | First agent audio |
| 8.96 | `agent_response_complete`, roughly when the agent's audio ends |

**Audio mode, "Stop." spoken while an 8-second tool was still running.**

| Time (s) | Event |
|----------|-------|
| 6.79 | Speech starts |
| 7.15 | **`interruption`**, 0.37 s after speech starts |
| 7.54 | Speech ends |
| 8.40 | **`user_transcript` "Stop."**, 0.86 s after speech ends and about 1.6 s after it starts |
| 8.96 | The agent says "Okay, I've stopped. **The volume was not changed.**" |
| 12.70 | The tool finishes and returns success. The agent says nothing about it |

What this run shows:
- **Transcripts still arrive while a tool is running**, so the stop watcher works during tasks.
- **The agent's own "I've stopped" does not stop anything.** The server simply drops the pending tool call. The real cancel has to come from the stop watcher (`TaskRunner.cancel`) or from `cancel_task`.
- **The agent claimed something it did not know.** The volume *was* changed. The prompt now says: "If the user interrupted you while a tool was still working, you do not know whether it happened... Never say it did not happen."

**How fast can a spoken "stop" act?**
- The transcript arrives about 0.9 s after the word ends, and Jev takes another 0.2 to 0.3 s. So the stop watcher cancels about **1.1 to 1.2 s after the user finishes saying "stop"**.
- `interruption` arrives within 0.4 s of the user *starting* to speak, if the agent has something in progress to interrupt.
- `vad_score` arrives within about 0.15 s, but on any speech or noise.
- **Built:** the screen agent holds before each new action while `VoiceSession.isUserSpeaking` is true. That signal comes from the voice activity, then the transcript and Jev decide whether to cancel or carry on. The cost is a brief pause whenever the user, or anyone nearby, speaks during a task. Measurements are in [section 10.3](#3-transcripts-replies-state-and-the-earliest-stop-signal).

**Events the server sends that the Python SDK throws away.** Its message handler ends in `else: pass`, so these are dropped:
- `vad_score`
- `agent_tool_request` and `agent_tool_response`
- `agent_response_metadata`
- `agent_response_complete`
- `internal_tentative_agent_response`, the agent's text as it streams
- `client_error`
- `tentative_user_transcript`

The server only sends events that are listed in `conversation_config.conversation.client_events`, so list the ones you want. **`tentative_user_transcript` was enabled and never arrived in any run** (ASR provider `scribe_realtime`), so there is no partial user transcript to work with. The Swift SDK exposes most of these as callbacks ([section 10](#10-the-swift-sdk-verified)).

## 7. Audio and echo

- **The devices work (Python SDK).**
  - `DefaultAudioInterface` opened the "MacBook Air Microphone" and "MacBook Air Speakers".
  - The mic delivered 11 chunks in 3 s, with peak level 820 and average level 205. That is real room sound: macOS gives all-zero audio, not an error, when permission is missing.
  - No permission prompt appeared, because the host app already has Microphone permission.
  - PortAudio 19.7.0 *is* installed (CLAUDE.md said it was not).
- **The Python SDK has no echo handling.** `DefaultAudioInterface` is two plain PyAudio streams, and `interrupt()` only empties the playback queue.
- **Real echo test.** Real mic and speakers, system volume 19%. The agent was asked, by typed message, to describe a beach for 25 s.
  - It was **interrupted 6 times by its own voice**.
  - Its own words came back as 5 user turns ("The sand is g-", "Sorry, I...").
  - It spiralled into "It seems we're talking over each other, so go ahead and finish your thought."
  - **On laptop speakers this blocks the product.** The same echoed words would also reach the stop watcher.
- **macOS's built-in echo canceller fixes it.** A parallel spike built `legacy_python/scripts/spikes/voice/aec/vpio_audio.py` (`VPIOAudioInterface`, about 150 lines). It uses pyobjc's `AVAudioEngine` with voice processing on, a tap on the mic, an `AVAudioPlayerNode` on the same engine for playback, and `AVAudioConverter` to produce 16 kHz.
  - **Offline:** while a clip played, the mic level dropped from 383 (canceller off) to 39 (on), against a noise floor of about 28. How closely the mic matched the played clip fell from 0.29–0.37 to 0.024, which is chance level. That is about 20 to 25 dB less echo.
  - **Live, 4 short conversations:** with it on, 0 to 1 interruptions, and the agent's own words were never transcribed. The interruptions that did happen were caused by a person talking nearby. That same person's voice got through while the agent was speaking, so barge-in works.
  - **Costs:** `start()` takes about 1.8 s. It adds about 0 to 13 ms of delay and about 50 ms of mic chunk regrouping. While it runs, other apps get a quieter mic.
  - **Not handled:** switching device mid-session (for example AirPods) needs a restart handler. A deliberate test with a person speaking over the agent is still to do.
  - Setup order matters: create `mainMixerNode` and `outputNode` *before* enabling voice processing, or the engine fails with error -10875.
- **For Swift: solved.** The SDK's audio path uses the same Apple voice processing, and the same 25-second test passed with 0 interruptions ([section 10](#10-the-swift-sdk-verified)).

## 8. Dropped connection and reconnecting

**What happened.**

| Situation | What happened (Python SDK) |
|-----------|----------------------------|
| The network connection was cut mid-session | `callback_disconnect` fired at once with `reason='error'`, `close_code=1006`, "no close frame received or sent" |
| The server's time limit was reached (temporarily set to 60 s) | `reason='agent'`, `close_code=1000`, `close_reason='Max call duration exceeded'`. The agent said nothing first |
| We sent a tool result that was a JSON object | `close_code=1008`, "Invalid message received" ([section 1](#1-client-tools)) |
| We tried to keep using the old session | `send_user_message` raised `RuntimeError: Session not started or websocket not connected`. Calling `start_session()` again on the same `Conversation` silently did nothing. The `ClientTools` event loop had stopped and its thread pool was shut down for good |
| We opened a fresh session | It connected. Asked "What did I ask you to set the volume to, a moment ago?", it said "I don't have any record of a volume request." **A new session starts with no memory of the old one** |

**What automatic reconnection needs.** This is the same in Swift; the Swift SDK reports `state == .ended(reason: .remoteDisconnected)` and you call `startConversation` again.

1. On any disconnect that the user did not ask for, post `.voiceDisconnected`. Then retry with growing gaps of 1, 2, 4, 8, 16 and 30 s, and keep retrying.
2. **Build every session from scratch.** In Python that means a new `Conversation` *and* a new `ClientTools`, with every tool registered again.
3. **Inject the context again.**
   - Send `user_memory` again.
   - Add a second variable, for example `{{session_context}}`, with a default placeholder. It carries what the user would expect the agent to remember: the task that is running or waiting, its open question, and the last few turns.
   - Turn the greeting off on reconnect. The `first_message` override is allowed by the agent's settings.
4. **Keep the push queue across the gap**, and send what is waiting once the new session is ready.
5. A tool call that was in flight when the connection dropped is lost. That is safe for the task tools, because `start_task` returns at once and the runner keeps going.
6. The 2-hour limit cannot be raised, so the app will reconnect at least every 2 hours. An all-day assistant will do this as a matter of course.

The setup message also carries a `persistent_session_token` field, which was `null` here. It may point to a server-side way to resume a session. That was not explored.

## 9. Where this differs from BUILD_PLAN.md and CLAUDE.md

1. **Tool timeout range.** CLAUDE.md says 5 to 300 s. It is **1 to 120 s, or -1 for no limit.**
2. **The tool result must be a string.** Nothing in the plan says so. A JSON object ends the conversation with code 1008.
3. **Tools listed inside the agent are deprecated**, in favour of standalone tools referenced by `tool_ids`. They still work and the server keeps them in sync.
4. **Pushing events.** The plan's fallback was a `check_task` tool that the agent polls. Not needed: a marked user message works, and the agent is bad at polling (it never called `wait_for_task` again after the user spoke). CLAUDE.md is right that `send_contextual_update` does not make the agent speak. `execution_mode: async` does not either.
5. **Session length.** Sessions end after **10 minutes by default and 2 hours at most.** The plan does not mention it.
6. **The "are you still there?" prompt.** `turn_timeout: -1` turns it off. CLAUDE.md only gives the 7-second default.
7. **PortAudio is installed** (CLAUDE.md said it was not).
8. **Echo.** The plan assumes barge-in just works. Over laptop speakers with the Python SDK it does not, because the agent hears itself.
9. **No tentative transcripts.** The stop watcher only gets final transcripts, about 0.9 s after the word ends.
10. **Sound tags in replies.** The default voice model, `eleven_v4_turbo`, has `expressive_mode` on. That puts tags like `[happy]` and `[slow]` in the agent's text and speech. It is turned off here.
11. **Examples in the prompt leak.** With "Priya Shah or Priya Patel?" as an example in the prompt, the agent asked "Priya Shah or Priya Patel?" when the user had only said "Priya". Examples in the prompt must not use names the agent could repeat as fact.
12. **The agent tells the user to do it themselves.** Without a rule against it, the agent said "you'll need to text Mom yourself". The prompt forbids this now.
13. **The agent claims things it does not know.** After being interrupted, it said "the volume was not changed" when it had been. The prompt now covers this.

## 10. The Swift SDK, verified

Everything below was read in the SDK's source (`elevenlabs-swift-sdk` 3.4.0 and LiveKit `client-sdk-swift` 2.19.0, in `Packages/HFVoice/.build/checkouts/`), or run through `Packages/HFVoice`.

### 1. Does it work on macOS, and what does it bring?

**Yes.** Version 3.4.0 is the latest stable release; 4.0 is still an alpha.

- It declares macOS 10.15 or later, tools version 5.9 and Swift 5 language mode.
- It builds inside our package (tools 6.0, Swift 5 language mode, macOS 14) on Xcode 26 and Swift 6.3.3, with no warnings in our code.
- It pulls in LiveKit `client-sdk-swift` 2.19.0, which brings two binary frameworks: `LiveKitWebRTC` (webrtc-xcframework 150.7871.4) and `RustLiveKitFFI` (0.13.1).
- Together these take about **2.3 GB** in `.build/artifacts`. The whole `.build` folder of `Packages/HFVoice` is 3.1 GB.
- **The first clean build took 2 min 40 s** on this Mac, most of it downloading and unpacking the binaries. Later builds take seconds.
- Every separate build folder downloads them again. That includes the app's build script, which builds each package in its own folder. Plan for it in a clean-clone setup.

**Setup text for the README** (voice layer):

> The voice layer uses the ElevenLabs Swift SDK, which brings LiveKit and WebRTC as prebuilt frameworks. They are about 2.3 GB, and the first build downloads them, taking roughly three minutes on a fast connection; later builds take seconds. Put `ELEVENLABS_API_KEY` in `.env` (the key needs ElevenAgents write and text-to-speech access), then run `cd Packages/HFVoice && swift run hf-voice setup` once. It creates the agent, or updates the existing "Hands-Free Laptop Agent", and writes `ELEVENLABS_AGENT_ID` into `.env`. Running it again is safe. To try the voice on its own: `swift run hf-voice text` (typed) or `swift run hf-voice talk` (spoken; the terminal app needs Microphone permission).

### 2. Client tools

- **Receiving.** Calls arrive through `ConversationConfig.onUnhandledClientToolCall`, and are also added to `conversation.pendingToolCalls`. Each one carries `toolName`, `toolCallId` and `parametersData`, the JSON bytes.
- **Answering.** The answer is a separate call, `sendToolResult(for:result:isError:)`, made whenever the handler finishes, so it can be asynchronous.
- **What goes over the wire.** The `String` overload sends the text exactly as given. The `Encodable` overload encodes the value to a JSON string first, so both arrive as a string, which is what the server needs.
- **What `VoiceSession` does:**
  - It runs each handler off the main actor, so a slow tool never holds up transcripts.
  - It turns the handler's `JSONObject` into compact JSON text, and sends that with `isError` set when `ok` is false.
  - It drops a `tool_call_id` key if one ever appears in the parameters.
- **Live result.** A typed "Set the volume to 30 percent." made the demo tool run with `percent: 30` **0.59 to 0.65 s** later (3 runs). The agent then said "Volume's at thirty."

### 3. Transcripts, replies, state and the earliest "stop" signal

| What | How it arrives in Swift |
|------|-------------------------|
| Final user transcript | `onUserTranscript` |
| Agent reply text | `onAgentResponse` |
| Interruption (the user started talking over the agent or a running tool) | `onInterruption` |
| Voice-activity score, 0 to 1, several times a second | `onVadScore` |
| Tool request and answer | `onAgentToolRequest`, `onAgentToolResponse` |
| Whether the agent is speaking | `conversation.$agentState`: listening, speaking, thinking. In voice mode this comes from LiveKit's "remote participant is speaking" |
| Disconnect | `onDisconnect` with `.agent`, `.user` or `.error`, and `conversation.$state` going to `.ended` |

- **Tentative transcripts are not available.** The SDK discards `tentative_user_transcript` (`case .tentativeUserTranscript: break`), and the server never sent one in the Python runs either. So there is no partial transcript to expose.

**The early "the user is speaking" signal: `VoiceSession.isUserSpeaking`.**
- It is safe to read from any thread. The screen agent checks it before each new action and holds while it is true. That way the pointer stops taking new actions as soon as the user starts to talk, and carries on if what they said was not a stop.
- **It turns true** when a voice-activity score reaches 0.5, or when an interruption arrives.
- **It stays true** for 0.5 s after the last high score, so it does not flicker between words. After that it stays true until the transcript of that utterance has been handed to the transcript listeners, the stop watcher included.
- **It gives up after 3 s with no transcript**, so a cough or a bang cannot hold the screen agent.
- It also posts `.userSpeaking(level:)` to the activity bus.
- `UserSpeechDetector` holds the rule, and its unit tests cover it.

**Why the threshold is 0.5.**

| Sound | Voice-activity score |
|-------|----------------------|
| Speech | jumps from about 0 to 0.93–1.0 within one or two readings |
| Silence | median 0.000, 90th percentile 0.002 |
| The agent's own voice through the speakers, voice processing on, quiet room | at most 0.11 |

Because the score rises so steeply, the exact threshold barely changes the delay.

**Measured delay** (`HF_LIVE_AUDIO=1 swift test --filter LiveSpeechSignalTests`):
- **Method:** speech made by macOS `say` was mixed into the outgoing microphone track at a known moment, with `VoiceDiagnostics.playIntoMicrophone`, and timed from the first loud sample.
- **Start of speech to `isUserSpeaking` true:** **343 to 512 ms, median about 0.42 s**, over 11 utterances in two runs. The signal turned true for every utterance in the second run, 6 of 6. In the first run it missed 1 of 5, before the test waited for the agent to finish speaking between clips.
- **End of speech to the transcript reaching the listeners:** median about 1.0 s, range 0.1 to 1.9 s.
- **So the hold starts roughly 1 to 2 s before a stop could act on the transcript.**
- **Compared with Python:** over the Python websocket the score crossed 0.5 about 0.1 to 0.15 s after speech started. The Swift path goes through LiveKit, which adds about 0.3 s.
- **Caveat:** people were talking in the room during both runs. Muting the room through LiveKit's `micVolume` probably had no effect in normal device mode, and the injected clips came back with cut-off transcripts. The delays were consistent across clips and runs, and each clip started from a clear state. Still, treat 0.42 s as a good estimate, not a precise figure. Repeat in a quiet room.

**Does the agent's own voice trip it?**
- In the quiet-room echo run, the agent's voice through the speakers scored at most 0.11, below the threshold.
- In the two signal runs the room was not quiet (the baseline heard "Who's up for testing?"). So "never true while the agent talks" could not be judged there; the test only checks it when its baseline was quiet.
- In every run, none of the transcripts was the agent's own words.

**A real risk this exposed: other people's speech counts as the user's.**
- Bystanders were transcribed as user turns ("You wanna start a new Zoom?").
- They turn `isUserSpeaking` on, which holds the screen agent.
- They reach the stop watcher, so a bystander saying "stop" would cancel a task.
- They can interrupt the agent.

Voice processing removes echo, not other voices. For the demo, use a quiet room, or headphones with a close microphone. Noisy-room handling (ElevenLabs' `noisy_environment_detection`, or a push-to-talk alternative) is not built.

**Ordering: the stop watcher hears a sentence before that turn's tool runs.**
- The SDK calls our callbacks on the main actor, in the order the server sent them, and the driver handles them right there, with no extra hop. So a transcript is always handled before the tool call that follows it.
- The transcript goes to the listeners at once, on their own queue.
- Every tool call first waits for that queue to catch up. A unit test proves a transcript followed by an `answer_task` call runs the listener first, even when the listener takes 80 ms.
- Tool handlers and listeners never run on the main actor, so the overlay keeps animating.
- Listeners must return quickly; `StopWatcher.heard` does.

### 4. Making the agent speak when a task has news

**It works through Swift exactly as in Python.**
- `VoiceSession.push(_:)` queues the event, waits for a quiet moment, and sends it with `sendMessage` as an `[APP]` line.
- In the live test, a question pushed with no user message was spoken **0.46 to 0.49 s** later (3 runs): "Two contacts match. Priya Shah or Priya Patel?"
- Progress lines are also sent silently with `updateContext`, the SDK's contextual update.

**Waiting for the agent before a push, after the integration review:**
- **A progress line never makes the next push wait.** The agent is told it may say nothing for a progress line, and then no reply would come. Before this fix, a confirmation pushed after an unspoken progress line waited the full 10 s cap. Now only a question, confirmation or result makes the next push wait for the agent's reply. Progress also reaches the agent silently as context, and in voice mode the speaking state still holds a push while the agent says it.
- **After the user speaks, or after a tool answers, the wait is capped at 4 s** (it was 15 s). The agent may relay an answer through `answer_task` and say nothing, so the cap must be short. The spike measured replies arriving 0.4 to 2.6 s after the turn. The wait restarts when the tool answers, because any reply comes after that.
- **Unit tests** cover both cases: a progress line left unsaid followed by a confirmation, which goes out at once; and an answer relayed silently, which holds a confirmation for at most 4 s.
- **Live text runs** (`aConfirmationRightAfterAProgressLineIsSpokenPromptly`, 2 runs): the agent said the progress line both times, 0.43 to 0.81 s after it was pushed. The confirmation pushed straight after was spoken 0.45 to 0.50 s later.
- **Not yet seen: what the server sends when the agent truly stays silent.** It is still open whether it sends no `agent_response`, or an empty one. The code no longer depends on the answer. Check it in a voice run when live runs are allowed again.

### 5. Text-only mode and memory

- **Text-only mode.** `ConversationOverrides(textOnly: true)` uses a websocket and no microphone. It needs a signed URL from `GET /v1/convai/conversation/get-signed-url`. The agent allows this override.
- **Voice mode** uses `customTokenProvider`, which fetches a LiveKit token from `GET /v1/convai/conversation/token` with our key (200, tested).
- **Memory.** It goes in as `dynamicVariables: ["user_memory": ..., "session_context": ...]`.
- **Typed messages and the listeners.** The server does not echo typed messages back as transcripts. So `sendText` calls the transcript listeners itself, which lets automated tests drive the stop watcher.

### 6. Audio on macOS

**Echo cancellation is on.** In voice mode LiveKit records and plays through `AVAudioEngine`, with Apple's voice-processing unit allowed by default and not bypassed. At run time `VoiceDiagnostics.echoCancellationReport()` printed:

```
platform voice processing allowed: true
voice processing bypassed: false
echoCancellation: isAvailable true, isRequested true, isActive true   (noise suppression and AGC the same)
resolved echo cancellation: effective Platform
```

**The live echo test** is `HF_LIVE_AUDIO=1 swift test --filter LiveAudioTests`. It ran with real speakers and the real mic, system volume 19%, the same volume at which Python heard itself 6 times.

1. **The mic is proven live first.**
   - Peak voice activity reached 0.96.
   - A person talking nearby was transcribed ("... spent a lot of time designing.").
   - The Mac's own `say` command was *not* transcribed. Voice processing also suppresses other apps' sound, which is good when the user plays a video.
2. **Then the agent spoke four sentences for about 25 s.**
   - 0 interruptions
   - 0 transcripts of its own words
   - peak voice activity 0.11
   - exactly one reply
3. **Verdict:** the echo problem is solved in the Swift path, with no code of our own.

**Microphone permission.** The command-line test did not prompt, because macOS charges the permission to the app hosting the terminal (Orca), which already has it. The built app will need its own Microphone permission: an `NSMicrophoneUsageDescription` string in its `Info.plist` and the first-run prompt. The app's onboarding owns that.

**Choosing devices.** The SDK exposes `conversation.audioDevices` and `selectedAudioDeviceID`, the input devices. LiveKit's `AudioManager.shared` can set the input and output device. Switching devices mid-session was not tested.

### What the user must do by hand

- The built app needs **Microphone** permission, which only the user can grant (the onboarding prompt).
- The **spoken checks still need a person**: slow and paused speech, and barging in over the agent. Run `swift run hf-voice talk` from `Packages/HFVoice` and speak. Type `/push Shah or Patel?` to hear a pushed question.

## 11. The agent configuration

`AgentConfiguration.definition(tools:)` in `Packages/HFVoice/Sources/HFVoice/AgentConfiguration.swift` builds the whole agent. Its unit tests check every value below.

| Part | Value | Why |
|------|-------|-----|
| LLM | `claude-haiku-5-5`, reasoning `none`, temperature 0, max 300 tokens, backups `claude-haiku-4-5` then `gpt-4.1-mini` after 4 s | [section 5](#5-which-llm) |
| Prompt | `docs/prompts/voice_agent.md`, with `{{user_memory}}` and `{{session_context}}` and defaults for both | sections [4](#4-memory-in-the-system-prompt-dynamic-variables) and [8](#8-dropped-connection-and-reconnecting) |
| Timezone | the Mac's (`TimeZone.current`) | so "tomorrow at three" means the right day |
| Turn | `patient`, `turn_timeout -1`, `silence_end_call_timeout -1`, spelling patience `auto`, speculative turn on | [section 3](#3-turn-taking-for-slow-or-paused-speech) |
| Voice | Alice (`Xb7hH8MSUJpSbSDYk0k2`), `expressive_mode: false` | clear speech, no `[happy]` tags |
| Session | `max_duration_seconds 7200`; client events: those the session uses | the server's maximum |
| First message | empty | no greeting on every reconnect |
| Overrides a client may use | text-only and first message, nothing else | tests need text mode; the prompt and model stay fixed |
| Each ToolSpec | `type client`, `expects_response true`, `response_timeout_secs` from `timeoutSeconds` clamped to 1–120, `pre_tool_speech off`, `interruption_mode allow`, `execution_mode immediate` | [section 1](#1-client-tools) |

**How the agent is kept in step with the code.**
- `swift run hf-voice setup` creates or updates the agent and writes `ELEVENLABS_AGENT_ID` into the repo's `.env`. Run twice, the first run found the existing agent by name and stored its id. The second updated it by id and left `.env` alone: one line, mode 600.
- Setup leaves the tool list out, so it never wipes the real tools.
- Each time the app starts, `VoiceSession` updates the agent with the current prompt and the app's real `ToolSpec` list before connecting. So the agent always matches the running code. If that update fails, the session logs it and carries on.
- `hf-voice text`, `hf-voice talk` and the live tests put the demo tool on the agent. The app puts the real tools back when it next starts.
- Tools go in the deprecated `prompt.tools` list, which the server turns into standalone tools and keeps in sync ([section 1](#1-client-tools)). If that list is ever removed, the change is to create each tool through `/v1/convai/tools` and send `tool_ids`.

**The prompt** is `docs/prompts/voice_agent.md`, the master copy. The package carries a copy in `Packages/HFVoice/Sources/HFVoice/Resources/voice_agent.md`, and a unit test fails if the two differ. To change the prompt, edit the docs copy, then copy it into the package.

It was rewritten for the direction change (the agent works the screen like a person):
- **Routing.** Only single actions go to quick tools. Everything else goes to `start_task`, as one self-contained goal with every detail.
- **While a task runs.** The agent says "On it." and stays quiet, relaying progress briefly and questions and confirmations exactly.
- **Confirmations.** They come only from the task. The user's reply goes back to `answer_task` word for word, and the app decides whether it was a yes.
- **Stop.** "Stop" means go quiet, and confirm in a word or two once the task reports it has stopped.
- **What carries over.** The rules that passed the Python behaviour test still apply: no hands-on instructions, brief speech, "Go on." for a cut-off sentence, never invent choices, never claim what a tool did not report, never speak reasoning or tool names.
- **Not yet tested.** The new routing and relaying wording has not been through a behaviour test. The live Swift test only checks the tool call and one relayed question.

## 12. Not verified, and open risks

- **The rewritten prompt's behaviour.** The Python behaviour test (78 of 78) ran against the earlier wording. The new routing, "stay quiet while a task runs" and word-for-word relaying need a behaviour test in Swift, or a spoken run.
- **A real person speaking.** Slow, paused or atypical speech, barging in over the agent on purpose, and "stop" said quietly while the agent talks. Echo is solved, but these still need `hf-voice talk` with a person.
- **Reconnecting against the real service** is unit-tested with a fake SDK (growing gaps, context carried over, queued events kept). It was not run against a real dropped connection or the 2-hour limit.
- **Push timing in voice mode** relies on the SDK's speaking state from LiveKit, plus a 0.6 s settle after each reply. It was unit-tested and is in the live audio path, but it was not measured with a question pushed while the agent was mid-sentence.
- **Ordering when the app hops to the main actor.** `push` is safe to call from any thread and keeps order. Calling it from separate `Task { @MainActor in ... }` blocks, as `PartAssembly` does now, does not strictly guarantee order. Calling `push` directly from the runner's sink is safer.
- **Size.** LiveKit and WebRTC add about 2.3 GB of build artefacts (3.1 GB for the package's `.build`), and the first build takes about 2 min 40 s. Each separate build folder pays this again.
- **Bystanders count as the user.** See section 10.3. This needs a quiet room or headphones for the demo.
- **The speaking-signal delay** (about 0.42 s) was measured with people talking in the room, and the room microphone was probably not really muted. Repeat it in a quiet room.
- **Device changes** mid-session (AirPods) and Bluetooth audio were not tested.
- **Cost.** Credits used were not measured. With reconnects at least every 2 hours, an all-day session means many conversations.
