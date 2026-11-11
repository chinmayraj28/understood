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
| Scribe `scribe_v3` with `no_verbatim` | best single recogniser; fillers and restarts left out (25.2% vs 29.7%) |
| No recogniser hints for a recording | hints raised words wrong 25.2% → 28.2% |
| Gemini lane: Gemini 3.1 Pro for a recording | 13.9% vs 36.6% for Flash |
| Examples in one labelled message, new clip last and named | fixed copying; Pro 19.8% → 13.9% |
| A fourth lane, Gemini 4 Carbon | an independent second listener; the merge drops to 11.4% |
| Repair for a recording: a transcription prompt, Claude Opus 5.5, the speaker's set-up phrases as known phrases | merging, not guessing a command; Opus beat Sonnet and Haiku |
| Live transcript: `scribe_v3_live` | 32.7% vs 37.6% |
| Voice setup hears its clips with Scribe only | the phrasebook matches Scribe; setup is fast |
| Longer limits for a recording (15 s to hear, 8 s to repair) | Gemini with examples sometimes needs 5–14 s |

Spoken turns to the pretend phone are unchanged: Scribe with hints, Gemini Flash, Haiku, 4 s.

**Tried and not adopted:**
- the recording's length as a hint to Claude (slightly worse);
- snapping Claude's text to the nearest transcript (worse; arXiv 2409.09554 suggested it);
- 10 examples instead of 5 (no clear gain);
- an audio re-listen stage (about 3 words better on 220, within noise, for 4 more seconds).

## Results

(Filled in below from `evalTranscription.ts`: before = the pipeline at commit cd48785; after =
this change; same clips, same scoring.)

## Known limits

- One dataset, 11 speakers, mostly single words; TORGO's single words are isolated prompts with no
  context, which is the hardest case and not how people talk to an assistant.
- A recording now takes about 6 to 15 seconds (Gemini 4 Carbon is the slowest listener).
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
