# Plan: understanding impaired speech

Written 7 Nov 2026 after feedback from a Hiya engineer, and agreed with the user the same day: **the impaired-speech understanding system is the product; the Mac agent (Handsfree, built on Clicky) is where it is demonstrated.** Deadline 11 Nov, 11:59pm GMT (target 6pm). Sources are in section 10.

---

## 1. What the feedback said, and what we do

| Feedback | What we do |
|----------|-----------|
| Build around **speech impairment recognition**, not noise cancellation | Headline: "a voice agent that understands people whose speech other agents get wrong" |
| Keep Clicky if it works, don't over-focus on it | No new Mac agent features. The Mac app gains its own listening and the understanding layer, nothing else |
| The speech feature should stand alone and has business value for Hiya | It is its own package, `HFUnderstand`, with one input (a recorded turn plus context) and one output (a reading, a confidence, a decision). The same contract would sit in front of Hiya's call-answering agent |
| They judge design and trade-offs | Every stage has a "why this, not that", and every stage is measured on real recordings |
| Build a web app, easier for reviewers | **Not followed, on purpose.** The user chose the Mac demo. To keep it testable, the evaluation tool `hf-understand` runs from a clean clone with only API keys: no app, no permissions, no signing |

**Why this fits the users we already chose.** People who cannot use their hands (ALS/MND, cerebral palsy, MS, Parkinson's, stroke) very often also have dysarthria: slow, slurred, quiet or breathy speech, with long pauses. 70 to 100% of people with Parkinson's have it. Today our app, like every voice agent, fails the people it is for. This is not a new user, it is the biggest gap for the same user.

An example from the feedback itself: the meeting notes wrote "Hiya" as "Haier" every time. A recogniser told that "Hiya" is a likely word would not have done that. That is technique one.

---

## 2. What the research says

- Off-the-shelf recognisers do fine on mild dysarthria (1 to 5% of words wrong) and fail on severe dysarthria (over 49% wrong on all eight systems tested: Whisper, Deepgram, AssemblyAI, GPT-4o, Gemini and others).
- **The meaning often survives when the words don't.** So success is judged by "did the agent do what the person meant", not only by word error rate.
- Showing Gemini 2.5 Flash a few of the same person's recordings with their correct text, with no training, cut errors from 28.1% to 22.0% (5 clips) and from 35.8% to 26.8% (19 clips).
- Telling a model "this person has dysarthria" does not help and often hurts. Personal examples help; labels don't.
- Google's personal models cut errors by up to 85% on repeated everyday phrases, less in free conversation. Most of what a hands-free user says is repeated everyday phrases.
- ElevenLabs does not let you plug in your own recogniser, gives no confidence score on transcripts, and accepts a keyword list.
- Claude cannot take audio; it can reason over text from recognisers.

---

## 3. The main design change: the app listens for itself

Today the ElevenLabs agent hears the user and acts on its own raw transcript straight away. If it hears "call some" instead of "call Sam", it has already acted before anything could fix it. **Repair must happen before the agent sees the words.** So:

```
 Before:  mic ─► ElevenLabs (hears + thinks + speaks) ─► tools on the Mac

 After:   mic ─► HFUnderstand on the Mac ──────────────► ElevenLabs agent (thinks + speaks)
                  1. record the turn (patient)              receives the repaired sentence
                  2. hear it three ways                     as the user's turn; its own
                  3. repair (Claude)                        microphone is muted
                  4. decide in code: act / ask / choose
                  5. learn from what was confirmed
```

- **Why not keep ElevenLabs hearing and fix things afterwards:** its agent answers the raw transcript at once; there is no hook between its transcript and its reply that runs on the Mac. Its "custom LLM" option needs a public server, which the Mac app is not.
- **Why keep ElevenLabs at all:** its voice, its agent prompt and all the tools, safety and task wiring already work and are tested. We change what goes in, not what happens after.
- **What this costs:** we take over turn detection and the fast "stop" from ElevenLabs. We gain both: we control how long a pause is allowed, and Apple's on-device recogniser shows words as they are spoken, so "stop" can be caught mid-sentence instead of after the transcript arrives (today about 0.9 s after the last word).
- **Proved on 8 Nov (docs/spikes/own_listening.md):** the SDK always opens its own microphone in a voice conversation, and our echo cancellation cannot remove the agent's voice when the SDK plays it. So the conversation runs **text only**: the repaired sentence goes in as the user's turn, and the reply is spoken with ElevenLabs text-to-speech played through our own recorder's audio engine, so echo cancellation works. About 0.8 s slower to start speaking; streaming text-to-speech wins most of it back.

---

## 4. The stages

### Stage 1: record the turn, patiently

- Our own microphone capture (AVAudioEngine, as the wake listener already does), with echo cancellation on so the agent's voice is not recorded as the user.
- A turn ends after a longer silence than usual (default 2.5 s, adjustable in the panel), or when the person says "done". Long pauses inside a sentence are normal in dysarthric speech, and our own spike found a 3-second pause gets cut off today.
- Apple's on-device recogniser runs on the live audio for two things only: catching "stop" at once, and catching "done".

### Stage 2: hear it three ways, in parallel

| Recogniser | Why it is here | Cost |
|-----------|----------------|------|
| **ElevenLabs Scribe** (batch, `scribe_v2`), with up to 100 keyterms (above 100, each request is billed as at least 20 s): the person's phrasebook, contacts and app names from memory, and the labels on screen | Our main recogniser; keyterms fix names ("Hiya", "Amma") | ~0.5–1 s |
| **Gemini 3.8 Flash with audio** (`google/gemini-3.8-flash`), through OpenRouter (key we already have, verified 8 Nov), shown 3 to 5 of this person's own clips with their correct text | The only no-training technique with a published gain on impaired speech (~22% fewer errors) | ~1–3 s |
| **Apple on-device** (SpeechAnalyzer), with the same words as hints | Free, private, already running for stage 1; a third vote | ~0 s extra |

**Why three:** when different recognisers agree, we can act without asking. When they disagree, the disagreement is the confidence signal ElevenLabs does not give us.

**Rejected:** training a model per person (best results, but needs hundreds of recordings and days); Voiceitt (no public API docs); Apple's "Listen for atypical speech" (an Apple system setting our code cannot use); telling the models about the condition (shown to hurt).

### Stage 3: repair (Claude)

Claude gets the three transcripts, the closest phrasebook matches (by spelling and by sound), the last few turns and the current context (front app, what the agent just asked). It returns the best reading, a confidence (high, medium, low) and up to two alternatives.

- **Why Claude:** a recogniser does not know what the person could plausibly want right now; Claude does. When the agent has just asked "Mum or Sam?", "sum" means Sam.
- **Risk:** Claude can confidently pick a plausible but wrong meaning. That is why stage 4 is code, and why nothing risky happens without a spoken yes (the existing safety gate is unchanged).

### Stage 4: decide, in code

| Situation | What happens | Example |
|-----------|-------------|---------|
| Recognisers agree or a strong phrasebook match, and Claude says high | The reading goes to the agent as the user's turn | "Volume up" |
| Claude says medium, or recognisers disagree on a word that matters | One yes/no question first | "Message Mum?" |
| Claude says low | Two choices, or ask for only the unclear part | "Mum or Sam?" / "Say just the name." |
| Two failed tries in a row | Yes/no questions only, which are the easiest to say | "Is it a message?" … "To Mum?" |

- **Why closed questions:** "yes" and "no" are short and easy to say, and recognisers get them right far more often than a sentence. We never ask "can you repeat that?" more than once: repeating is tiring and usually fails the same way.
- **Why code, not the prompt:** a rule about when to ask must hold when the model is wrong. Same lesson as the safety gate (DECISIONS.md, 6 Nov).
- The yes/no answer itself goes through stages 1 to 3 and is judged by the existing answer classifier (Jev, with keyword fallback).

### Stage 5: learn

- **Setup, hands-free:** the panel shows 15 short phrases the person uses ("open WhatsApp", "message Mum", "scroll down"); the app listens to each and moves on by itself. We store the clip, what each recogniser heard, and the intended text.
- **Every confirmed or corrected turn** adds a "heard → meant" pair. The next time a recogniser produces the same garble, the phrasebook catches it before Claude is asked.
- The most useful few clips (recent, and the ones recognisers found hardest) become Gemini's examples.
- **Stored on the Mac only**, in its own SQLite file: speech recordings of a disabled person are health data. Each request carries only the clips it needs. Pairs from long ago count for less, because speech changes in progressive conditions.

### Latency

Worst case about 3 to 4 s from end of speech to the agent replying (2.5 s pause wait is before this). Fast path: when Apple and Scribe agree with a phrasebook entry, skip Gemini and Claude (under 1 s). We accept the slow path because for this user a wrong action is far worse than a slow one: they cannot undo it by hand. Measured, not guessed, and reported.

---

## 5. Code layout

New package **`Packages/HFUnderstand`** (depends only on `HFCore`, like every package):

| File | Contains |
|------|---------|
| `TurnRecorder.swift` | Microphone capture, patient end of turn, "stop" and "done" from Apple's live recogniser |
| `Hearers.swift` | `ScribeHearer`, `GeminiHearer`, `AppleHearer`, all behind one protocol |
| `Repairer.swift` | The Claude repair call, through `StructuredLanguageModel` from `HFCore` |
| `Decider.swift` | The table in stage 4, pure code |
| `Phrasebook.swift` | SQLite store of clips and pairs; matching by spelling and sound |
| `Understander.swift` | Runs the stages for one turn; posts each stage to `ActivityBus` so the companion can show "heard … → understood …" |
| `hf-understand` (command-line tool) | `hear <file.wav>`, `enrol`, and `eval <manifest>`: the reviewer-runnable piece |

Shared types go in `HFCore/Understanding.swift` (written by the lead before parallel work starts). The app gains the wiring, a setup screen and a "what I heard" line in the companion. `HFVoice` gains: microphone muted, "send repaired turn", and keyterm hints. New env var: none (Gemini goes through OpenRouter; check on day 1 that OpenRouter accepts audio for Gemini, otherwise add `GEMINI_API_KEY`).

---

## 6. Proving it works

- **Data:** TORGO (speakers with cerebral palsy and ALS, plus speakers without). Free for academic, non-profit use. We use it only to evaluate, do not put clips in the repo, and say so in the write-up. We will not generate fake impaired speech: it misrepresents real speech and imitates real people without consent.
- **Measures:** word error rate per stage; **meaning success** (did the reading lead to the right action); **wrong-action rate** (acted without asking, and was wrong; must be near zero); turns needed; time per turn.
- **Setups compared, cumulative:** Scribe alone → + keyterms → + Gemini with personal clips → + Apple vote and repair → + phrasebook learned from earlier clips of the same speaker.
- Each result with its sample size and limits: one dataset, a handful of speakers, single runs.
- **The demo video:** TORGO clips (clearly labelled) played into the real app, with the companion showing raw versus understood text, plus the user's own voice for a live run.

---

## 7. Schedule

| Day | Work |
|-----|------|
| Sat 7 Nov | Contract in `HFCore`. Spikes: muted ElevenLabs mic + typed turn; OpenRouter audio for Gemini; Scribe keyterms. TORGO subset downloaded and listed. Baseline: Scribe alone, then with keyterms |
| Sun 8 Nov | `HFUnderstand`: recorder, three hearers, repairer, decider, phrasebook, CLI. Evaluation run 1 |
| Mon 9 Nov | App wiring, setup screen, companion line. Full spoken run on the Mac. Evaluation run 2 with phrasebook |
| Tue 10 Nov | Review by a second agent and fixes. Rewrite `WRITEUP.md`, `PITCH.md`, `README.md`, `ai.md`, `DECISIONS.md`. Demo video |
| Wed 11 Nov | Buffer, clean-clone test, submit by 6pm |
| Thu 12 Nov | King's SET fair, 5:30 to 7:30pm: live demo on the laptop |

**Cut first if late:** the Apple vote, then Gemini (keep Scribe + keyterms + repair + decide + phrasebook). **Never cut:** ask-when-unsure in code, the spoken yes before anything risky, the stop watcher, the evaluation numbers.

---

## 8. Failure modes

| What goes wrong | What happens |
|----------------|--------------|
| Gemini or OpenRouter down or slow (over 4 s) | Go on with the other two; the missing vote counts as "not sure", so medium readings ask |
| Claude down | Phrasebook match or recogniser agreement still act; otherwise ask a yes/no question built from the Scribe text |
| Scribe down | Apple and Gemini only; everything above low confidence asks |
| Everything down | Say "I can't hear properly right now" and keep listening for "stop" on the device |
| The agent's own voice picked up as the user | Echo cancellation, plus ignore turns that match what the agent just said |
| Person speaks while the agent talks | Still recorded; "stop" still works; the agent's speech is cut as today |
| Wake phrase, sleep and the locked-Mac checks | Unchanged |

---

## 9. Risks

| Risk | What we do |
|------|-----------|
| Muting the ElevenLabs mic does not work in the Swift SDK | Day-1 spike; fallback is text-only conversation plus text-to-speech |
| Reviewers can't easily run the Mac app | `hf-understand eval` runs with only keys; demo video |
| TORGO licence is academic only | Evaluation only, no redistribution, stated openly |
| Few speakers | Results reported per speaker; claim only what the data shows |
| The rule "no Python, Swift only" | Kept: everything new is Swift. Evaluation scripts are Swift too |
| Late changes break the working app | Wiring behind a setting: "understanding on / off", which also gives the before/after demo |

---

## 10. Sources

- Off-the-shelf systems on TORGO, by severity: arXiv 2512.17474
- Speech Accessibility Project Challenge 2025 (best 8.11% WER, meaning score): arXiv 2507.22047
- Gemini few-shot with the same speaker's clips (28.1% → 22.0%): arXiv 2509.15516
- Describing the condition in the prompt does not help: arXiv 2605.02782
- Transcript correction from 5 alternatives (trained corrector, modest gain): arXiv 2505.20163
- Google Euphonia / Project Relate personal models: research.google blog, "Personalized ASR models from a large and diverse disordered speech dataset"
- ElevenLabs: `asr.keywords`, `retranscribe_on_turn_timeout`, no custom recogniser, no transcript confidence (API reference: agents create; client events)
- Scribe keyterms: 1,000 in batch, 50 in realtime (ElevenLabs speech-to-text docs)
- Dysarthria by condition: ASHA practice portal. Voice problems in US adults: NIDCD
- TORGO licence: cs.toronto.edu/~complingweb/data/TORGO
