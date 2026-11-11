# Transcription accuracy: what was changed, why, and how it was measured

11 November 2026. The goal: when a recording (a TORGO clip or an uploaded file) goes through the
pipeline page, the transcript should be as accurate as possible. Actions on the transcript were
out of scope.

## How accuracy was measured

- **Data.** TORGO test clips only: 8 speakers with dysarthria from cerebral palsy and 3 without.
  Every speaker's voice is set up only from their own enrolment clips, never from test clips
  (`eval/README.md`, section 2).
- **Dev and held-out.** Test clips are split once, by a hash of the clip id, into a dev half and
  a held-out half. Every choice below was made on dev clips. The held-out half was run once, at
  the end, with the final pipeline, and is the number to quote.
- **Score.** Word error rate, scored as the evaluation scored it (`shared/wordErrors.ts`, a port
  of `WordErrorRate.swift`): lower case, punctuation and apostrophes dropped, digits as words.
  Fillers are not removed from the reference or the transcript, so a recogniser that writes "uh"
  is penalised. Corpus-level: total errors over total reference words. Words and sentences are
  reported separately, because single words are much harder.
- **Tools** (all in `web/scripts/`, answers cached so a change can be re-scored without paying for
  the audio again; failures are never cached):
  - `compareRecognisers.ts`: dedicated speech recognisers, no hints.
  - `compareListeners.ts`: audio language models, with and without the speaker's clips.
  - `compareCombiners.ts`: ways of merging several transcripts (medoid vote, Claude).
  - `compareJudge.ts`: an audio model re-listening with the candidates (tried, not adopted).
  - `evalTranscription.ts`: the website's whole pipeline end to end, as the page runs it.
- **Samples.** Component comparisons used 66 dev clips (6 per speaker: about 40% sentences). With
  about 220 reference words, differences under 2 points are noise; only larger, consistent
  differences drove a decision.

## What was wrong (found by reading the failures)

1. **Gemini copied its examples.** The speaker's clips were sent as earlier chat turns, so the
   model sometimes answered with an example's text: a whole sentence came back as "meat".
2. **The second listener was weak.** Gemini 3.8 Flash got 36.6% of words wrong with five
   examples; better models were available.
3. **Hints hurt.** The speaker's set-up phrases as Scribe keyterms pulled new sentences towards
   known ones (25.2% → 28.2% words wrong with Scribe v3).
4. **The repair was written for phone commands.** Claude was asked what the person "could be
   saying to their phone", and rewrote transcripts (in one case from 38% to 63% wrong).
5. **Fillers and restarts.** Recognisers wrote "uh", "okay", and restarts twice.
6. **Correlated voters.** Scribe batch and Scribe realtime make the same mistakes, so two of three
   votes could outvote a better, different listener.

## Evidence (dev clips)

Single recognisers, no hints (66 clips):

| Recogniser | Words wrong | Single words | Sentences |
|---|---|---|---|
| Scribe v3, `no_verbatim` | **25.2%** | 68.2% | 13.3% |
| Scribe v3 | 26.2% | 72.7% | 13.3% |
| Gemini 3.5 Transcribe | 27.7% | 52.3% | 20.9% |
| Voxtral Small Transcribe 3 | 27.7% | 63.6% | 17.7% |
| AssemblyAI Universal 3.6 Pro | 29.2% | 65.9% | 19.0% |
| Scribe v2 (before) | 29.7% | 70.5% | 18.4% |
| Deepgram Nova 3 | 31.7% | 47.7% | 27.2% |
| GPT-4o Transcribe | 32.2% | 63.6% | 23.4% |
| Scribe v3 live (realtime) | 32.7% | 65.9% | 23.4% |
| Scribe v2 realtime (before) | 37.6% | 75.0% | 27.2% |
| Whisper large v3 | 39.6% | 63.6% | 32.9% |
| Google Chirp 3 | 38.1% | 70.5% | 29.1% |
| GPT Transcribe | 34.7% | 54.5% | 29.1% |
| Meta Muse Voice Transcribe 1.0 | 40.6% | 56.8% | 36.1% |
| xAI Grok STT 2.0 | 41.1% | 70.5% | 32.9% |
| NVIDIA Nemotron 3.5 Transcribe | 44.1% | 113.6% | 24.7% |

Audio language models, shown the speaker's own set-up clips (66 clips):

| Model, layout | Shots | Words wrong | Single words | Median time |
|---|---|---|---|---|
| Gemini 3.8 Flash, examples as chat turns (before) | 5 | 36.6% | 54.5% | 2.7 s |
| Gemini 4 Argon, chat turns | 5 | 32.7% | 118% (invents text) | |
| Gemini 4 Carbon, chat turns | 5 | 17.8% | 40.9% | 6.2 s |
| Gemini 3.1 Pro, chat turns | 5 | 19.8% | 36.4% | 4.7 s |
| Gemini 4 Carbon, one labelled message | 5 | 14.9% | 38.6% | 5.4 s |
| **Gemini 3.1 Pro, one labelled message** | **5** | **13.9%** | 31.8% | 3.9 s |
| Gemini 3.1 Pro, one labelled message | 10 | 14.4% | 36.4% | 2.9 s |

Merging (66 clips, the same cached transcripts):

| Inputs → merge | Words wrong | Single words | Sentences |
|---|---|---|---|
| Scribe v3 + Gemini 3.5 Transcribe + Voxtral + Deepgram → medoid | 21.3% | 54.5% | 12.0% |
| same → Opus 5.5 with known phrases | 18.8% | 56.8% | 8.2% |
| Scribe v3 + Gemini Pro + live → Opus with known phrases | 15.8% | 56.8% | 4.4% |
| **Scribe v3 + Gemini Pro + Gemini 4 Carbon → Opus with known phrases** | **11.4%** | 38.6% | 3.8% |
| the same + live → Opus with known phrases | 11.9% | 38.6% | 4.4% |
| the same, Sonnet 5.5 | 13.4% | 38.6% | 6.3% |
| the same + an audio re-listen as a fifth candidate → Opus | 10.4% | 31.8% | 4.4% |

## What changed

| Change | Why (evidence) |
|---|---|
| Scribe `scribe_v3` with `no_verbatim`, for a recording | best single recogniser; fillers and restarts left out (25.2% vs 29.7%) |
| No recogniser hints for a recording | hints raised words wrong 25.2% → 28.2% |
| Gemini lane: Gemini 3.1 Pro for a recording | 13.9% vs 36.6% for Flash |
| Examples in one labelled message, new clip last and named | fixed copying; Pro 19.8% → 13.9% |
| A fourth lane, Gemini 4 Carbon | an independent second listener; the merge drops to 11.4% |
| Repair for a recording: a transcription prompt, Claude Opus 5.5, the speaker's set-up phrases as known phrases | merging, not guessing a command; Opus beat Sonnet and Haiku |
| The prompt says which recognisers are related, and uses a known phrase only when a transcript nearly matches it | the first end-to-end run showed Claude replacing correctly heard words with words from the speaker's list ("horn" became "warm") and the two Scribe voices outvoting Gemini; on the same 110 dev transcripts, 13.4% → 9.6% |
| Live transcript of a recording playing: `scribe_v3_live` | 32.7% vs 37.6% |
| Voice setup hears its clips with Scribe only | the phrasebook matches Scribe; setup is fast |
| Longer limits for a recording (15 s to hear, 8 s to repair) | Gemini with examples sometimes needs 5–14 s |

Spoken turns to the pretend phone are unchanged: `scribe_v2` with hints and every word kept (`no_verbatim` could drop the "no" in "Mum, no, Sam"), `scribe_v2_realtime` for the microphone, Gemini Flash with the chat-turn layout, Haiku, 4 s. A review on 11 Nov caught that the first version had switched speech to v3 and `no_verbatim` as well; that was undone.

**Tried and not adopted:**
- the recording's length as a hint to Claude (slightly worse);
- snapping Claude's text to the nearest transcript (worse; arXiv 2409.09554 suggested it);
- 10 examples instead of 5 (no clear gain);
- an audio re-listen stage (about 3 words better on 220, within noise, for 4 more seconds).

## Results

The website's pipeline end to end (`evalTranscription.ts`): the speaker's voice set up from
their own enrolment clips, then each clip heard, merged and decided as the page does it.
**Before** is the pipeline at commit cd48785 (11 Nov morning); **after** is this change. Same
clips, same scoring, 10 clips per speaker (4 sentences, 6 words), 110 clips per half.

**Held-out, first sample (never used for any choice):**

| Held-out, 110 clips | Before | After |
|---|---|---|
| Words wrong, all | 42.4% | **18.7%** |
| Single words | 65.2% | 39.4% |
| Sentences | 37.4% | 14.1% |
| Speakers with dysarthria | 55.7% | 24.4% |
| Speakers without | 7.9% | 4.0% |
| Every word right | 43% | 64% |

Each listener alone on the same held-out clips: Scribe v3 35.0%, Gemini 3.1 Pro 33.1%, Scribe v3
live 40.8%. The merge is what brings it to 18.7%.

**Held-out, second sample** (another 110 held-out clips, none in the first sample; run after the
review fixes, and also used to try a 25-second limit for Gemini 4, which was not adopted: 22.2%
vs 22.5%, within noise):

| Held-out, second 110 | Before | After |
|---|---|---|
| Words wrong, all | 37.3% | **22.5%** |
| Single words | 66.7% | 33.3% |
| Sentences | 30.1% | 19.9% |
| Speakers with dysarthria | 50.0% | 31.0% |
| Every word right | 43% | 65% |

**Both held-out samples together (220 clips; the number to quote):** words wrong **39.9% → 20.6%**;
single words 65.9% → 36.3%; sentences 33.9% → 16.9%; speakers with dysarthria 52.9% → 27.6%; every
word right 43% → 64%. Each listener alone on the same 220: Scribe v3 33.3%, Gemini 3.1 Pro 30.8%,
Scribe v3 live 40.5%.

The second sample is harder than the first, and on it the merge helped sentences less (Scribe v3
alone 25.5%, the pipeline 19.9%). That is the honest spread of these numbers.

**Seen and unseen.** 15 of the 110 held-out clips say a phrase the speaker also said during setup,
so it is among Claude's known phrases. On those, words wrong were 6.3% before and after. On the 95
unseen clips, 45.9% before and **19.9%** after. Over both samples (186 unseen clips): 43.5% →
22.4%; the 34 seen clips 7.0% → 4.2%. The gain is on new speech, not on recognising known phrases.

**Checks on the numbers.** The "before" run used `scribe_v2_realtime` for the live transcript, as
the page did then. In the held-out "after" run, one clip had no live transcript and one had no
repair (Claude did not answer in time), so it fell back to the recognisers; both count as they
came out. The harness was fixed afterwards so a failed live transcript can never be cached as an
empty answer.

**Dev half (used for the choices, so it flatters):** before 34.8%, after 9.9% (single words 31.8%,
sentences 5.2%, every word right 77%). The gap between dev and held-out is partly tuning and partly
that the held-out half is harder (Scribe alone: 23.3% on dev, 35.0% held-out).

Per speaker, held-out, after: F01 14%, F03 11%, F04 17%, M01 34%, M02 48%, M03 0%, M04 51%,
M05 17%; controls FC01 3%, FC02 9%, MC01 0%. The most severe speakers remain hard: some long
sentences come back as a different sentence of similar sound ("Alimony harms a divorced man's
wealth" → "I live on the hill I suppose meant to work").

**Beyond TORGO** (`evalUploads.ts`): 24 sentences synthesised with four macOS voices at 80 to 150
words a minute, half with white noise at about 15 dB SNR, heard as an uploaded file with no voice
set up (no examples, no phrasebook). Words wrong 0.7%, 23 of 24 exactly right (the miss: "Mum"
written "Mom"). This is clear speech, not impaired speech: it checks that the pipeline handles
audio it has never seen and does not damage clear speech, nothing more.

**On the page:** a TORGO sentence (M02, severe, "I can read") and a noisy M4A upload ("Please read
me the last message from Sam") both came back every word right, in 12 to 14 seconds including the
recording playing.

## Known limits

- One dataset, 11 speakers, mostly single words; TORGO's single words are isolated prompts with no
  context, which is the hardest case and not how people talk to an assistant.
- A recording now takes about 6 to 15 seconds (Gemini 4 Carbon is the slowest listener, and on
  the held-out run it sometimes ran out its 15 seconds; the merge then works with the others).
- Isolated single words stay hard (36% wrong over both held-out samples), and homophones cannot be told apart
  without context ("knew" and "new").
- Opus 5.5 cannot have thinking switched off, only kept short ("adaptive" at low effort); if it
  runs past 8 seconds the turn falls back to the recognisers.
- The prompt was tuned on dev transcripts; its examples of Scribe's habits ("Got it", "Yep")
  came from reading dev failures.
- The cost per recording is higher: two Gemini Pro-class calls with five example clips each, and
  an Opus call.
- Not tested with people with dysarthria using it live.

## Sources

- Agarwal et al., *The Universal Personalizer*, arXiv 2509.15516: same-speaker examples help an
  audio LLM on impaired speech; examples from another speaker hurt.
- Ma et al., *ASR Error Correction using Large Language Models*, arXiv 2409.09554: LLM correction
  of a strong recogniser can hurt; larger models help.
- Hernandez et al., arXiv 2509.25048: correcting every TORGO transcript nearly doubled WER;
  confidence-guided correction avoided it.
- Alsayegh and Masood, arXiv 2512.17474: audio LLMs on TORGO by severity; Pro-class beats Flash.
- ElevenLabs speech-to-text API reference (`scribe_v3`, `no_verbatim`, keyterm limits).
- OpenRouter speech-to-text guide and models API (transcription endpoint, model list).
