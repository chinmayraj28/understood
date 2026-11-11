# Evaluation: does the understanding layer understand impaired speech?

This folder measures `HFUnderstand` (the impaired-speech layer, see `docs/SPEECH_PLAN.md`) on real
recordings of people with dysarthria. It runs from a clean clone with only API keys: no Mac app,
no permissions, no signing.

## 1. The data: TORGO

TORGO (University of Toronto with Holland Bloorview Kids Rehabilitation Hospital, 2008–2010)
holds speech from seven people with dysarthria caused by cerebral palsy or ALS, plus matched
speakers without it. Prompts include single command words ("yes", "no", "up", "select", "menu"),
the radio alphabet, word lists and short sentences.

**Licence.** TORGO is free for academic, non-profit use. We use it only to evaluate; we never
train on it, never redistribute it, and its audio is never committed (`eval/data/` is gitignored).
Publications using it must cite Rudzicz, Namasivayam and Wolff (2012), *The TORGO database of
acoustic and articulatory speech from speakers with dysarthria*, Language Resources and Evaluation
46(4):523–541. Official page: <https://www.cs.toronto.edu/~complingweb/data/TORGO/torgo.html>.

We do not use synthetic "impaired" speech: it misrepresents real speech and imitates real people
without their consent.

### Getting it

```bash
eval/scripts/fetch_torgo.sh
```

Shell and curl only. It downloads the women and men with dysarthria (archives `F` and `M`, all
speakers) and the start of the two control archives (`FC`, `MC`; set `CONTROL_BYTES` to change how
much), extracts only the audio and prompt texts, deletes each archive, and builds
`eval/data/torgo/manifest.json`. About 4.4 GB is downloaded and under 1 GB kept. The server drops
connections often; the script resumes where it stopped and can be rerun safely.

- Plain HTTP is used because the server's HTTPS is throttled to a few hundred bytes a second from
  some networks. The files are audio and text and are never run.
- The Hugging Face copy (`abnerh/TORGO-database`) was not used: its viewer API drops the file names
  that carry the speaker, so a per-speaker split is impossible without a Parquet reader.

### Speakers and severity

Severity is as reported in the TORGO literature (Frenchay Dysarthria Assessment based; see e.g.
Rudzicz et al. 2012 and the per-speaker table in Joy & Umesh 2018). We did not re-assess it; the
archives carry no severity field.

| Speaker | Group | Reported severity |
|---|---|---|
| F01, M01, M02, M04 | cerebral palsy | severe |
| M05 | cerebral palsy | moderate to severe |
| F03 | cerebral palsy | moderate |
| F04, M03 | cerebral palsy | mild |
| FC.., MC.. | control | none |

## 2. Keeping the result honest: the split rule

Everything a setup learns about a speaker (keyterms, Gemini's example clips, the phrasebook) comes
**only from that speaker's enrolment clips**, never from test clips, and never from another speaker.
The split is fixed in the manifest before anything runs:

Each speaker's clips are put in recording order (session, then utterance number). Then:

- **A prompt the speaker said two or more times:** the first recording is enrolment; every later
  recording is test. Example: F03 says "up" in session 3 and again in session 4; the session-3 clip
  teaches, the session-4 clip is tested.
- **A prompt said once:** enrolment if it is in the speaker's earliest session (for a speaker with one
  session, the first half), otherwise test.
- **One microphone per utterance** (the array microphone, or the head microphone when a session has
  no array recording). Both microphones record the same utterance, so using both would put the same
  speech on both sides.
- Non-word tasks ("[say Ah-P-eee repeatedly]"), picture descriptions and "xxx" are dropped.
- Enrolment is capped per speaker (`--enrol-limit`, default 20) to keep API cost down. Under the cap,
  enrolment clips of prompts the speaker says again later are used first, then the rest in recording
  order. This mirrors the app's setup screen, where a person records the everyday phrases they will
  keep using; it never uses the later recordings themselves.

So a recording is never on both sides, and nothing recorded later teaches anything earlier. A test
clip is **seen** if its prompt is among the enrolment clips used, otherwise **unseen**:

- **Seen**: the prompt was also said in enrolment. This is the realistic case for this product: a
  hands-free user says the same everyday commands again and again ("scroll down", "message Mum").
- **Unseen**: the prompt never appeared in enrolment. This is the harder, free-speech case.

Repair runs with empty context (no screen, no conversation), so it can only use the recognisers'
transcripts and the phrasebook. In the app it also sees the front app and what the agent just
asked, so these numbers understate what repair can do there.

## 3. The setups (cumulative)

| Setup | What it adds |
|---|---|
| `scribe` | ElevenLabs Scribe alone, no hints |
| `keyterms` | + the speaker's enrolment prompts as Scribe keyterms |
| `gemini` | + Gemini Flash hearing the clip, shown 5 of the speaker's own enrolment clips with their text |
| `repair` | + Apple's on-device recogniser as a third vote, and Claude repairing the text |
| `phrasebook` | + a phrasebook learned by feeding every enrolment clip through the hearers and confirming its prompt, as the app learns from confirmed turns |

Every setup ends with the same decision code the app uses (act, confirm, choose, ask again).
Each is built fresh per speaker.

## 4. Running it

Keys come from `.env` at the repo root (`ELEVENLABS_API_KEY`, `OPENROUTER_API_KEY`,
`ANTHROPIC_API_KEY`), read through `Settings.load()` and never printed.

The Swift tool (`hf-understand`) that produced the 9 Nov results is not included in this submission. The website's own pipeline is measured the same way, with the same split rule, by `web/scripts/evalTranscription.ts` (see `docs/TRANSCRIPTION.md`):

```bash
cd web
npx tsx scripts/evalTranscription.ts --split dev --per-speaker 10
```

Options: `--setups a,b`, `--limit N` (test clips, taken in turn from each speaker and alternating
seen and unseen prompts, so the same limit always picks the same clips), `--enrol-limit N`,
`--speakers F01,M04`, `--clip-limit S` (seconds one clip may take before it is scored as "cannot hear"; default 30), `--out dir` (default `eval/results/<date-time>`).

## 5. Reading the results

Each run writes `results.md` (tables) and `results.json` (every clip: each recogniser's transcript,
the phrasebook match, Claude's reading, the decision, the time).

- **WER** (word error rate): wrong words per word said, after lower-casing, removing punctuation and
  writing digits as words. Lower is better; it can exceed 100% when words are added.
- **Exact match**: the final reading equals the prompt after normalising. Our proxy for "the meaning
  got through"; for commands, one wrong word usually means the wrong action.
- **Wrong action**: the layer acted without asking and the text was wrong. For someone who cannot undo
  by hand this is the number that matters most, and it must stay near zero.
- **Correct action**: acted without asking, and right.
- **Asked**: a question would be asked first ("Message Mum?"). Asking is safe but costs a turn.
- **Seconds**: from the end of the clip to the decision; mean and 90th percentile.

## 6. Limits

One dataset, a handful of speakers, read prompts (not spontaneous commands), single runs (model
outputs vary between runs), and small samples: with 30 clips, one clip is 3 percentage points.
Claim only what a table shows, with its sample size.
