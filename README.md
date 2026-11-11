# Understood

**A voice assistant that understands speech other assistants get wrong.**

Understood is a website that listens to one spoken sentence and works out what the person meant, even when their speech is slow, slurred or quiet. It shows every step on screen as it happens, with real timings, and then either acts or asks a short question first.

It is my submission for the Hiya Voice AI Challenge (Accessibility track). The one-page write-up is in [WRITEUP.md](WRITEUP.md), and the AI tools I used are described in [ai.md](ai.md).

## Who it is for, and why voice

People with **dysarthria** (speech made slow, slurred, quiet or breathy by cerebral palsy, ALS, Parkinson's, MS or a stroke) are failed by voice assistants. On severe dysarthria, off-the-shelf recognisers get more than 49% of words wrong. Many of the same people cannot use their hands well either, so a keyboard is not a fallback. Voice is their only way in, and today it is the way that works worst for them.

Two things from the research shaped the design. First, the **meaning often survives when the words don't**: "mum sis, I'm running late" is very likely "message Sam, running late". Second, a recogniser gets much better at one person's speech when it is shown a few of that person's own recordings, with no training at all.

## What happens to one sentence

Say "message Sam running late". The page draws the sentence moving along a line of five stations:

1. **Hear it several ways, at the same time.**
   - **ElevenLabs Scribe** is the main recogniser: v2 with hints (the person's contacts and usual phrases) for a spoken turn, v3 without fillers for a recording.
   - **Gemini** (through OpenRouter) hears the clip after being shown a few recordings of this same person with their correct text: Gemini 3.8 Flash for a spoken turn, Gemini 3.1 Pro for a recording.
   - **Gemini 4 Carbon**, for a recording only, listens the same way as a second, independent ear.
   - **Scribe realtime** writes the live transcript you see while you speak (v2) or a recording plays (v3 live), and is a vote too.

   ElevenLabs gives no "how sure am I" score, so **agreement between the recognisers is the confidence signal**. Words they disagree on light up.
2. **Phrasebook.** It keeps the mishearings this person has corrected before ("heard *call some*, meant *call Sam*, confirmed 3 times"). If a recogniser makes the same mistake again, the phrasebook catches it.
3. **Repair.** For a spoken turn, Claude Haiku 5.5 reads the transcripts, the phrasebook matches and the conversation so far, and picks the most likely meaning. For a recording, Claude Opus 5.5 merges the transcripts into one verbatim transcript, knowing which recognisers are related and which phrases this person says. Either way it gives a confidence (high, medium or low) and explains why in one sentence.
4. **Decide, in code.** Fixed rules decide whether to act, ask a yes/no question, offer a choice ("Mum or Sam?") or ask once to repeat only the unclear part. The page writes out the rule that fired. **Claude alone never makes it act:** a reading is acted on only when the recognisers, or a phrasebook entry confirmed at least twice, back it word for word. The rules are in [`web/shared/rules/decider.ts`](web/shared/rules/decider.ts).
5. **Act or ask.** A pretend phone beside the line sends a message, makes a call, or sets a timer, a song or a reminder. Anything that would reach another person always asks first ("Send 'I'm running late' to Sam?"). Your answer is a new sentence that goes through the same pipeline.

A turn that was confirmed or corrected is added to the phrasebook, so it gets better the more one person uses it.

**A real run** (from the server check below, a synthetic voice saying "message Sam running late"):

| Stage | Result | Time |
|---|---|---|
| Scribe | "Mum sis, I'm running late" | 0.8 s |
| Live transcript | "message Sam running late" | live |
| Gemini | timed out, so the pipeline went on with two votes | 4.0 s limit |
| Claude | "message Sam running late", confidence **medium** | 2.1 s |
| Decision | Ask: "Message Sam running late?" | rule: *Claude thought this likely but was not sure of a word that matters* |

The recognisers disagreed, so it asked rather than guessing. That is the behaviour the whole design is built around: **a wrong action is worse than a slow one**, because the person cannot undo it by hand.

## The site

Three pages under one header:

- **Home** (`#/`): what it is, how a sentence travels through the five stages, the TORGO results, and how your voice is handled. The opening diagram is a real run: TORGO speaker M05 saying "up", heard as "Uh" by two recognisers and "up" by Gemini.
- **Pipeline** (`#/pipeline`): the workspace. Input on the left (a TORGO recording, your own file, or the microphone) with the stage switches under it; the scored transcript and the pipeline line in the middle; an inspector on the right for the phrasebook, the conversation and the pretend phone.
- **Recordings** (`#/recordings`): every TORGO clip on your computer.

What you can do there:

- **Hear a recording.** The main way in. Pick a real TORGO recording of a person with dysarthria (by speaker, test or set-up clip, or search), or choose your own audio file (WAV, MP3, M4A, OGG or WebM, up to 60 seconds, decoded in the browser). It plays out loud while the live recogniser writes it down, then goes through every stage. The answer is shown as a transcript in large type and, when what was said is known (the TORGO prompt, or text you type), every word is marked right or wrong, with the share of words wrong for each recogniser on its own and for the whole pipeline, scored exactly as the evaluation scored it. A recording is only transcribed: nothing is acted on, asked, spoken or learned.
- **Heard as the right voice.** The first time you hear one of a TORGO speaker's clips, the page sets up that speaker's voice from up to 20 of their own set-up clips, as the evaluation did: their phrases become Scribe's hints, five clips become Gemini's examples, and every mishearing becomes a phrasebook entry (about 20 seconds, once per visit). Test clips are never used for this, so a test clip is a fair test; hearing a set-up clip says so. Your own file can be heard as nobody in particular, as your own voice, or as a TORGO speaker.
- **Set up your voice.** Read 10 short phrases. Their recordings become Gemini's examples and the first phrasebook entries.
- **Stage switches.** Turn off the hints, Gemini, the examples, the phrasebook or the repair, hear the same recording again, and compare the two results side by side.
- **Evaluation.** The numbers from real recordings of people with dysarthria (below), led by how many words the transcript got wrong.
- **Speak live.** **Start listening** still runs your own speech through the same pipeline, with the pretend phone acting or asking first.
- **Recordings.** Every TORGO clip on your computer, playable, filtered by speaker, severity, word or sentence, and set-up or test. For the 121 clips the evaluation tested, open one to see what each recogniser heard, Claude's reading and the decision, next to what Scribe alone did. It needs the data on disk (`eval/scripts/fetch_torgo.sh`, about 1 GB). Because TORGO may not be redistributed, the audio is served only by the local server, only to this computer, and only for clips listed in the manifest; a hosted copy of the site has no such route.
- **Clear everything** deletes the phrasebook, the recordings and the conversation from the browser.

## Run it

You need [Node.js](https://nodejs.org/) (built and tested with v24.13.0), a microphone, and three API keys.

| Key | What it is for |
|---|---|
| `ELEVENLABS_API_KEY` | Scribe (batch and realtime) and the spoken replies. It needs Speech to Text and Text to Speech access |
| `OPENROUTER_API_KEY` | Gemini hearing the audio (3.8 Flash for speech; 3.1 Pro and 4 Carbon for recordings) |
| `ANTHROPIC_API_KEY` | Claude: the repair step (Haiku 5.5 for speech, Opus 5.5 for recordings), and choosing the pretend-phone action |
| `ELEVENLABS_VOICE_ID` | Optional. The voice the assistant speaks in; a default is used without it |

1. Get the code and enter the folder.

```bash
git clone <repository-url> understood
cd understood
```

2. Create the settings file at the repo root and fill in the three keys. `.env` is ignored by git.

```bash
cp .env.example .env
chmod 600 .env
open -e .env
```

3. Install and start the website. This runs the page on port 5173 and the API server on port 8787.

```bash
cd web
npm install
npm run dev
```

4. Open http://localhost:5173 and click **Open the pipeline**. Under **Input**, pick a TORGO clip (this needs the data: `eval/scripts/fetch_torgo.sh`) or choose your own audio file, and watch it go through the pipeline. To speak instead, choose **Microphone**, click **Start listening**, allow the microphone and say "message Sam running late"; the turn ends after 2.5 seconds of silence, or when you say "done".

The server keeps the keys. They never reach the browser: the page gets only a short-lived token for the live transcript. Each visitor is limited to 20 sentences a minute (90 on the local server, because setting up a TORGO speaker's voice hears 20 clips at once). If a key is missing, the server says so when it starts, and that stage shows as failed on the page.

## Run the tests

```bash
cd web
npm test            # 283 tests in 30 files, no network
npm run typecheck
```

Last run on 11 Nov 2026: all 283 passed, and the typecheck was clean. The decision rules and phrasebook matching are ported from the Swift package the evaluation ran against (`Packages/HFUnderstand`). They give the same answer as the Swift version on all 3,902 comparison cases, so the website decides exactly as the evaluated pipeline did.

A live check against real services (it uses the keys and costs a fraction of a penny):

```bash
cd web
npm start           # API server only, in one terminal
# in another terminal, make a test clip and send it through every stage:
say -o x.aiff "message Sam running late" && afconvert -f WAVE -d LEI16@16000 -c 1 x.aiff x.wav
npx tsx tests/live.smoke.ts x.wav
```

It prints each stage with its time, then checks the phone action, the spoken reply and the live-transcript token. The table above came from this check on 11 Nov 2026.

## Does it work? Transcription accuracy

On 11 November the pipeline's transcription was measured end to end, the way the pipeline page hears a recording, on **held-out TORGO test clips**: two samples from a fixed half of the test clips, set aside before any change was made and never used to choose anything. 220 clips from 11 speakers, 8 with dysarthria.

| Held-out, 220 clips | Before (11 Nov morning) | Now |
|---|---|---|
| Words wrong, all | 39.9% | **20.6%** |
| Single words | 65.9% | 36.3% |
| Sentences | 33.9% | 16.9% |
| Speakers with dysarthria | 52.9% | 27.6% |
| Every word right | 43% | 64% |

Each listener alone gets 31% to 41% wrong on the same clips; merging them is what brings it to 21%. On the 186 held-out clips whose phrase the speaker never said during setup, it fell from 43.5% to 22.4%. The two samples differ (18.7% and 22.5% after), which is the honest spread. What changed, the evidence behind each choice (including a comparison of 13 speech recognisers and 5 audio models), how it was measured, and the limits are in [`docs/TRANSCRIPTION.md`](docs/TRANSCRIPTION.md). The scripts are in `web/scripts/` (`evalTranscription.ts` runs the whole pipeline).

## The earlier evaluation: deciding when to act

The first version of the pipeline was measured on **TORGO**, recordings of people with dysarthria (mostly from cerebral palsy) made by the University of Toronto. Each speaker's earlier recordings were used to set them up; their later recordings were the test, so no clip was in both. There were 121 test clips. Full method and results are in [`eval/README.md`](eval/README.md) and [`eval/results/2026-11-09-second-run/results.md`](eval/results/2026-11-09-second-run/results.md).

| Setup (each adds to the one above) | Words wrong | Acted, and was right | Acted, and was **wrong** | Asked first |
|---|---|---|---|---|
| Scribe alone | 34% | 0% | 0% | 98% |
| + hints | 29% | 0% | 0% | 98% |
| + Gemini with the person's own clips | 29% | 39% | 7% | 54% |
| + third vote and Claude's repair | 27% | 37% | 4% | 59% |
| + phrasebook (the full pipeline) | **25%** | 34% | **2%** | 64% |

On phrases the person had said before (66 clips), words wrong fell from 38% to **19%**.

How to read this: with Scribe alone the rules almost always asked, because one recogniser has nothing to agree with. Adding Gemini let the pipeline act on 39% of clips, but it was wrong on 7%. The third vote, Claude's repair and the phrasebook brought wrong actions down to 2%, while still acting correctly on about a third of sentences without needing to ask.

**Limits of the evaluation:** one dataset, a handful of speakers, single runs, and mostly single words and short phrases. TORGO is free for academic, non-profit use. It is used here only to evaluate; its audio is never committed or published, and the page shows text and timings only.

To rerun it (Swift, macOS; downloads about 4.4 GB once):

```bash
eval/scripts/fetch_torgo.sh
cd Packages/HFUnderstand
swift run -c release hf-understand eval ../../eval/data/torgo/manifest.json --limit 30
```

## Privacy

- **Recordings and the phrasebook stay in the browser** (IndexedDB), because speech recordings of a disabled person are health data. Each request carries only the clips it needs, and the server stores nothing.
- Audio goes to ElevenLabs (Scribe) and to Google's Gemini through OpenRouter, and the transcripts go to Anthropic (Claude), only while a sentence or recording is being understood. The live transcript streams audio only during a turn. A TORGO clip heard in the pipeline goes to the same services, as it did in the evaluation; it is never stored by the server or added to the repo.
- Keys stay on the server and are never logged.

## Safety rules it follows

- Nothing is acted on when the pipeline is unsure. That rule is code, not a prompt, so it holds when the model is wrong.
- Anything that reaches another person (a message or a call) always needs a yes.
- A yes counts only if it is just a yes, said after the question finished playing. "Okay, message Sam instead" is not a yes to "Message Mum?". Questions expire after 60 seconds.
- The model never chooses who a message goes to. "Message Mallory" does nothing unless Mallory is a known contact.
- "Stop" or "cancel" on its own always acts at once, because stopping is always safe.
- If a service is down, the pipeline goes on with what is left and asks more often. If everything is down, it says "I can't hear properly right now."

## Known limits

- **Not hosted yet.** It runs locally. Cloudflare Workers was planned (Vercel was ruled out because it runs on AWS); the checklist is in [`docs/WEB_PLAN.md`](docs/WEB_PLAN.md), section 6.
- **Speed.** About 3 to 6 seconds from the end of a spoken sentence to the decision: the 2.5-second pause wait, then up to 4 seconds for Gemini and about 2 seconds for Claude. A recording, where accuracy matters most, takes about 6 to 15 seconds after it has played, because the stronger listeners are slower.
- **Hard cases.** Isolated single words stay hard (36% wrong held-out), homophones such as "knew" and "new" cannot be told apart without context, and the most severe speakers (M02, M04) are still misheard about half the time.
- **Gemini with example clips is erratic.** On 11 Nov the same request took anywhere from 1.4 to 14 seconds. A spoken turn gives it 4 seconds and goes on with two votes when it is late. A recording, where the transcript is the point, gives it 15 seconds and Claude 8, so a recording can take up to about 25 seconds.
- **Not tested with a person with dysarthria using it live.** The evaluation used real recordings, played in offline; the live checks used synthetic voices.
- **English only, and a pretend phone.** Nothing on the page reaches a real person.
- The per-visitor limit is kept in memory, which is enough locally but not for a public deployment.

## Map of the repo

```
web/                  the website (submission)
  src/                the pages: React; pages/ (home, pipeline), router.ts, microphone,
                      recordings, live transcript, pipeline view
  server/             the API: Hono on Node; /api/understand, /api/realtime-token,
                      /api/speak, /api/act; the three recognisers and the repair;
                      dataset.ts, the local-only TORGO route for the Recordings tab
  shared/rules/       the decision rules and phrasebook matching, ported from Swift
  tests/              Vitest: 283 tests, plus live.smoke.ts
Packages/
  HFCore/, HFUnderstand/   the same pipeline in Swift, and the hf-understand evaluation tool
eval/                 the TORGO evaluation: method, scripts, results (no audio)
docs/                 SPEECH_PLAN.md (the design), WEB_PLAN.md (the website)
DECISIONS.md          every significant choice, what was rejected, and why
```

The other folders (`Handsfree/`, the other `Packages/`, `scripts/`, `third_party/`) hold an earlier Mac prototype that is not part of this submission.

Where to read first: [`docs/SPEECH_PLAN.md`](docs/SPEECH_PLAN.md) (why each stage exists), then [`DECISIONS.md`](DECISIONS.md).

## Credits

- **ElevenLabs** (Scribe v2, v3 and realtime speech-to-text, and text-to-speech), **Google Gemini** (3.8 Flash, 3.1 Pro, 4 Carbon) through **OpenRouter**, and **Anthropic** (Claude Haiku 5.5 and Opus 5.5).
- **TORGO**: Rudzicz, Namasivayam and Wolff (2012), *The TORGO database of acoustic and articulatory speech from speakers with dysarthria*, Language Resources and Evaluation 46(4):523–541.
- Fonts: Atkinson Hyperlegible, self-hosted (see `web/public/fonts/README.md`).
- The earlier Mac prototype in the repo adapts parts of **Clicky** by Farza (MIT). Details are in `third_party/clicky/NOTICE.md`.
