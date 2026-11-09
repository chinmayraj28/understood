# Spike: the app listens for itself, the agent only speaks

Run on 7–8 Nov 2026 for `docs/SPEECH_PLAN.md` section 3. ElevenLabs Swift SDK **3.4.0** (LiveKit 2.19.0), macOS 26.3.1, MacBook Air M4. Tool: `Packages/HFVoice/Sources/hf-listen-spike` (`swift run hf-listen-spike muted|textonly`), against the TEST agent (`ELEVENLABS_TEST_AGENT_ID`).

**Main blocker during the runs: the laptop lid was closed** (`ioreg … AppleClamshellState = Yes`). macOS switches the built-in microphone off when the lid is shut. Any capture, with or without voice processing, ran without errors but got **no audio buffers at all**. Both Orca and `claude` hold the Microphone permission, so this was not a permission problem. As a result, no voice conversation could be started, and nothing about echo could be measured. Everything below says whether it was **run**, **read in the SDK source**, or **still open**.

## Answers

### 1. Can the SDK microphone be muted, or never captured, while the agent still speaks?

**Muted: yes (read in the source). Never captured: no, not through the public API.**

- `Conversation.setMicrophoneMuted(true)` calls LiveKit's `localParticipant.setMicrophone(enabled: false)`. This stops publishing our microphone track. The agent's audio is a separate remote track and keeps playing. `Conversation.setMuted(_:)` does the same thing, unless `AudioPipelineConfiguration(useSoftwareMute: true)` is set; then it keeps the microphone open and sends zeros.
- What LiveKit does on mute is set by `AudioPipelineConfiguration(microphoneMuteMode:)`:
  - `.inputMixer` (the default) keeps LiveKit's engine and its voice processing running and only silences the input.
  - `.restart` restarts LiveKit's engine without microphone input.
  - `.voiceProcessing` uses Apple's voice-processing mute.
- **The microphone is always opened at connect.** `WebRTCConnectionManager.connect` calls `setMicrophone(enabled: true)` whenever the permission is granted. The SDK has an option to carry on if that fails, `ConversationOptions.microphoneFailureHandling = .continueWithoutMicrophone`, but `ConversationConfig` does not pass it through, and `Conversation`'s initialiser is internal. So the app cannot reach it.
- **Run:** with the lid closed, `ElevenLabs.startConversation(conversationToken:config:)` failed with `microphoneToggleFailed("Timed out")` after **8 to 12 s** (two runs). **A voice conversation cannot start without a working microphone**, even when we only want the agent's voice.
- A pending mute can be set while the conversation is still connecting, but the SDK applies it only after the microphone has been switched on. So there is always a short moment (not measured) when our microphone reaches the agent. `AudioManager.shared.mixer.micVolume = 0` before connecting would silence that moment (spike flag `--premute`; **not run**).
- LiveKit lists only real input devices. The "Microsoft Teams Audio" virtual input was not offered, so it could not stand in for the missing microphone.

### 2. Does a typed user message make the agent reply aloud in a muted voice conversation, and how fast?

**Still open for voice mode** (no conversation could be started). Evidence so far:

- **Run, text-only, 8 Nov:** `conversation.sendMessage(...)` brought the reply text after **0.80 s**. The agent said the requested sentence word for word.
- **Earlier spike** (`docs/spikes/elevenlabs.md` section 2): in a voice conversation, a typed `send_user_message` made the agent **speak** after **1.36 s**. In the app, a typed message makes a tool call arrive after 0.59 to 0.65 s. Typed turns produce no `user_transcript` event.
- The SDK call is `Conversation.sendMessage(_:)`, which the app uses already (`ElevenLabsDriver.sendUserMessage`). The spike's `muted` mode measures "send → agent audio starts" and "send → first audible agent audio on this Mac" (a meter on `conversation.agentAudioTrack`) as soon as a microphone works.

### 3. Can our own AVAudioEngine with voice processing run beside the SDK, and does it keep the agent's voice out?

**Still open: no microphone audio was possible.** What was found:

- **Run:** an AVAudioEngine with `inputNode.setVoiceProcessingEnabled(true)` starts, and reports a 48 kHz input with 5 to 7 channels. Use only the first channel: it is the cleaned-up voice. If the output side (`mainMixerNode`, `outputNode`, a player) is first touched *after* voice processing is turned on, the engine fails to start with **-10875**. Created *before*, it starts. The earlier spike found the same rule (`docs/spikes/elevenlabs.md` section 7). `TurnRecorder` follows it.
- **Run, once, dead microphone:** with voice processing on and a text-only conversation open, the agent's text reply did not arrive within 15 s. With voice processing off, it came in 0.80 s. This is a single run without a microphone, so it is not conclusive, but it must be rerun.
- **The design risk.** Apple's echo canceller removes what its *own* engine plays. In a muted voice conversation the agent's voice is played by LiveKit's engine, so our engine's canceller has no copy of the sound to remove. There would also be two voice-processing units in one process. Whether macOS cancels audio played by another engine is unknown; the earlier spike only measured playback through the *same* engine.
- **Measured earlier** (`docs/spikes/elevenlabs.md` section 7) with the agent's audio played through the **same** voice-processing engine: echo **20 to 25 dB lower**, and the agent's own words were never transcribed in 4 live conversations. A person talking over the agent still got through.

### 4. Fallback: a text-only conversation plus ElevenLabs text-to-speech

**Works (run 8 Nov, voice processing off, so no microphone was involved):**

| Step | Time |
|------|------|
| Typed message → reply text (`sendMessage`, text-only websocket) | **0.80 s** |
| Reply text → whole reply audio (`POST /v1/text-to-speech/{voice}?output_format=pcm_16000`, `eleven_flash_v2_5`, non-streaming, 4.1 s of audio) | **0.83 s** |
| Typed message → audio starts playing | **1.63 s** |

**What is lost, and what we would build instead:**

- The SDK's speaking and listening state. We know it ourselves, because we play the audio.
- ElevenLabs' turn-taking and its own "stop" on interruption. We take both over anyway (`TurnRecorder`: patient end of turn, and `stopHeard` from the live recogniser, which calls `stopAgentAudio()`).
- About **0.8 s** more before the voice starts. The streaming endpoint (`/stream`) should cut this; not measured.
- Text-to-speech cost per reply.

**What is gained:**

- No LiveKit microphone at all.
- The conversation does not need a working microphone to start.
- The agent's voice is played through **our** voice-processing engine, so the echo canceller has the exact copy to remove (the measured 20 to 25 dB case).

## Recommendation

**Use the text-only conversation plus text-to-speech played through `TurnRecorder.playAgentAudio`.** Do not use the muted voice conversation. The reasons:

1. The SDK always opens its own microphone at connect, and fails to connect without one. No public setting changes that in 3.4.0.
2. A muted voice conversation still leaves the agent's voice playing in LiveKit's engine, out of reach of our echo canceller. That is the one thing this design must not get wrong: the person has to be able to say "stop" over the agent, without the agent's voice being heard as theirs.
3. Playing the voice through our own engine is the only set-up with a measured good result.
4. The price is about 0.8 s, which streaming text-to-speech should mostly recover.

**Before this is final, one rerun with a working microphone** (lid open), under the live lock:

```
cd Packages/HFVoice
swift run hf-listen-spike textonly --vp on                 # voice processing on, reply played through our engine
swift run hf-listen-spike muted --vp on --say              # for comparison: the muted voice conversation
swift run hf-listen-spike muted --vp off --no-own-mic --say
```

Each run prints what Apple's recogniser hears in our recording while the agent speaks; the agent's sentence should not be in it. With `--say`, `say` speaks a sentence while the agent's microphone is muted; it must not appear as a user transcript. The text-only run with voice processing on must also answer within about 1 s, unlike the dead-microphone run above.

## SDK calls to use

| Need | Call |
|------|------|
| Text-only conversation | `ElevenLabs.startConversation(signedWebSocketURL:config:)` with `ConversationOverrides(textOnly: true)` (as `ElevenLabsDriver` already does) |
| The repaired sentence as the user's turn | `Conversation.sendMessage(_:)` |
| Background context that must not make the agent speak | `Conversation.updateContext(_:)` |
| The agent's reply text | `ConversationConfig.onAgentResponse` |
| Speak it | `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=pcm_16000`, body `{"text", "model_id": "eleven_flash_v2_5"}`, header `xi-api-key`, then `TurnRecorder.playAgentAudio(pcm16:)` |
| Stop it | `TurnRecorder.stopAgentAudio()` |
| If the muted voice conversation is kept after the rerun | `Conversation.setMicrophoneMuted(true)` straight after connect, `AudioPipelineConfiguration(microphoneMuteMode: .restart)` so LiveKit's own voice processing stops, and `AudioManager.shared.mixer.micVolume = 0` before connecting |

## Built: own-listening mode in HFVoice (9 Nov)

`VoiceSession(..., ownListening: OwnListening?)`. It is off (nil) by default, and then nothing changes. When it is on:

- The conversation is text-only, so the SDK microphone is never opened.
- `sendHeardTurn(_:)` sends the understood sentence. It goes exactly where a spoken transcript goes: `.userSaid` on the activity bus, then the transcript listeners (so the stop watcher sees it before any tool call of the turn), then the agent.
- Replies are spoken with streaming text-to-speech (`POST /v1/text-to-speech/{voice_id}/stream?output_format=pcm_16000`, `eleven_flash_v2_5`, the agent's own voice) into the app's `play` sink. The app connects that sink to `TurnRecorder.playAgentAudio`.

**Live run** (`HF_LIVE=1 swift test --filter LiveOwnListening`, TEST agent, no sound played, audio written to a file):

| Step | Time |
|------|------|
| Heard turn sent → reply text | **0.72 s** |
| Asked for speech → first audio chunk | **0.27 s** |
| Heard turn sent → first audio chunk | **0.97 s** (non-streaming was 1.63 s) |

The reply was 4.3 s of audio (138,206 bytes), in 44 chunks.

**What the speech side does in place of the SDK's audio:**

- **The agent counts as speaking** from the first chunk until the audio handed over is due to have finished, plus 0.3 s. The time is worked out from the bytes (32,000 a second), because the sink has no "finished" callback. While the speech is still being made, before the first chunk, the agent also counts as busy, so a task message cannot slip in.
- **`.agentActivity(.speaking / .listening)`** comes from the speaker, so the activity events, the waiting of task messages and the idle timer work as in voice mode.
- **`interruptAgentSpeech()`** stops playback and drops queued speech. It is counted as an interruption. A new heard turn does the same first.
- **`userIsSpeaking(level:)`** stands in for the SDK's voice-activity score. It drives `isUserSpeaking`, the idle timer and `.userSpeaking`.

**What cannot be the same as voice mode** (three points):

1. **ElevenLabs does not know a reply was cut short.** In voice mode its server trims an interrupted reply in its own record of the conversation. In text mode it believes the whole reply was said, so later turns may assume the person heard all of it. A reply that is cut off is not counted as heard on our side (point 2).
2. **"Said" is now judged on the audio, not the text (consent fix, 9 Nov).** In voice mode a question counts as said when the reply text arrives. Here it counts only when its audio has been handed over and is due to have finished playing, with no failure and no interruption:
   - If text-to-speech fails, or the reply is interrupted (`interruptAgentSpeech`, a new heard turn, a close or a drop), nothing in it counts as heard.
   - A question or confirmation is then sent again once, by today's said-check rule.
   - An answer that arrives before the question has finished playing is held back, as an answer to an unheard question is today.
   - The rule is strict: the whole reply must play, not just the question's own words. We do not know where in the audio the question's words end.
   - Tests: `OwnListeningConsentTests`. They cover played fully (said), an answer while still playing (held, then passed on), speech failure (not said, held, sent again), interrupted (not said), talked over (not said), and voice mode (unchanged).
3. **The end of playback is estimated** from the bytes handed over (32,000 a second) plus 0.3 s, because the sink reports no "finished". If the player lags further, a question can count as heard up to that lag early. It could be exact if the app passed on a "finished playing" callback from its player.

Also different, but covered: text mode sends no "thinking" state. The wait for a reply (`awaitingReplySince`) covers it.

**The rerun still needed once the lid is open** (or a microphone is plugged in), under the live lock:

1. `swift run hf-listen-spike textonly --vp on` to check echo removal with our own voice-processing engine, and that the reply still arrives in about 1 s. The dead-microphone run did not get one.
2. A spoken run of the full app: the person speaks over the agent's voice, "stop" is heard, and the agent's own words never come back as a turn.

## Parked, 9 Nov

The Mac app is parked, and the demo moves to a website. The consent gap named earlier (a question counted as said when the reply text arrives, not when it has played) **was closed before parking**: in own-listening mode "said" now needs the audio played to the end (`OwnListeningConsentTests`, all 160 HFVoice tests pass). Still open: the end of playback is estimated from bytes rather than reported by the player, and the microphone rerun above has not been done by this agent.

## Rerun with the lid open (9 Nov, 02:15)

Lid open (`AppleClamshellState = No`), MacBook Air microphone. **The Mac's sound output was muted** (`output muted:true`, volume 69), so nothing played through the speakers could reach the microphone. Tests: `Packages/HFUnderstand/Tests/HFUnderstandTests/TurnRecorderLiveTests.swift` (`HF_LIVE=1 swift test --filter TurnRecorderLiveTests`, under the live lock).

| Check | Result |
|-------|--------|
| 1. The microphone delivers sound | **Run, passes.** Voice processing on: 21 buffers in 2 s, peak 0.133, median −46.9 dBFS (first channel of 5, 48 kHz). Off: 20 buffers, peak 0.039, median −49.3 dBFS. |
| 2. One turn across a 1.5 s pause; "done" ends the turn | **Blocked by the muted output** (the `say` phrases were never audible). It did show a bug, below. |
| 3. Echo from `playAgentAudio`, and a person heard over it | **Blocked by the muted output.** The spike's echo numbers below are meaningless while muted. |
| 4. Text-only reply with voice processing on | **Run, passes.** `hf-listen-spike textonly --vp on`: reply text **0.79 s** after sending, TTS (non-streaming) 0.28 s, audio queued 1.09 s after sending. The 15 s timeout of 8 Nov was the closed lid. |

**Bug found in `TurnEndDetector`** (HFUnderstand). This room sits at about −47 dBFS, above `quietestSpeechDecibels` (−55). The noise floor is seeded from the very first chunk and learnt only while idle. With voice processing off, the recorder reported "speech started" 0.8 s after starting with nothing playing, and the turn never ended on silence; with it on, a 15 s "turn" ended only at a lull, with an empty live transcript. So in a moderately noisy room the first turn is stuck until the 30 s maximum. Fix to consider: learn the floor for the first ~0.5 s before any turn may start, and keep learning it while a "turn" has no words from the live recogniser.

Still to run once the output is unmuted: checks 2 and 3 (`HF_LIVE=1 swift test --filter "TurnRecorderLiveTests/(turnsFromRealSound|echo)"`).
