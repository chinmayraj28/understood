# Plan: the website ("Understood")

Written 9 Nov 2026, when the user moved the demo from the Mac app to a website: "focus on the speech model, leave the Clicky thing for now; run it on a website and show the pipeline so it's transparent about what it's doing." The understanding design itself is unchanged: see `docs/SPEECH_PLAN.md` sections 2 and 4. Deadline 11 Nov, 11:59pm GMT; target 6pm.

## 1. What a visitor sees

A page that shows one turn of speech travelling through the pipeline, live:

1. **Speak.** A big live transcript writes itself as you talk (ElevenLabs Scribe realtime). A waveform breathes with your voice. The page waits through long pauses (2.5 s by default, adjustable), or you say "done". A button also ends the turn, for visitors with hands.
2. **Hear, three ways.** Three lanes race, each with its own stopwatch: Scribe with your keyterms, Gemini shown your own clips, and the realtime transcript. Words land as each finishes. Words the lanes disagree on light up.
3. **Phrasebook.** If something you said before was misheard the same way, its card turns over: "heard *call some* → you meant *call Sam*, confirmed 3 times".
4. **Repair.** Claude's reading appears with a confidence meter and one plain sentence on why.
5. **Decide.** A switch-track picks the route, and the rule that fired is written out: "Two recognisers heard the same words and Claude was sure, so it acts." Or: "Scribe heard a different name, so it asks first."
6. **Act or ask.** A small pretend phone beside the pipeline does the thing (message, call, timer, music, reminder), or the assistant speaks a yes/no question. Your answer is a new turn that goes through the same pipeline.
7. **Learn.** A confirmed or corrected turn flies into the phrasebook panel, which grows over the session.

Alongside:
- **Set up your voice:** read 10 short phrases shown on screen. Their clips become Gemini's examples and the first phrasebook entries.
- **Stage switches:** turn off keyterms, Gemini, examples, phrasebook or repair and say the same thing again, to see what each stage adds.
- **Evaluation:** the numbers from real recordings of people with dysarthria (TORGO, `eval/`), with replays of evaluation turns animated through the same pipeline view. Text and timings only: TORGO audio is not ours to publish.

## 2. Architecture

```
 Browser (web/src)                                         API server (web/server)
 ─────────────────                                         ───────────────────────
 mic ─► AudioWorklet ─► 16 kHz PCM ─┬─► Scribe realtime WebSocket (token from /api/realtime-token)
                                    │      └─► live transcript on screen; its final text = third vote
                                    └─► end-of-turn detector (patient) ─► WAV
 phrasebook + clips (IndexedDB, on this device only)
 POST /api/understand { wav, realtimeText, phrasebook, examples, keyterms, context, switches }
                                                     ───►  Scribe batch ∥ Gemini (OpenRouter)   (time-limited)
 ◄── server-sent PipelineEvents, one per step ──────────    agreement → phrasebook match → repair (Claude Haiku)
                                                             → decider (code) → decision + the rule that fired
 POST /api/act { text }  ─────────────────────────────►    Claude picks one pretend-phone action
 POST /api/speak { text } ────────────────────────────►    ElevenLabs text-to-speech, streamed PCM
```

| Choice | Why | Rejected |
|--------|-----|----------|
| TypeScript, React + Vite page, Hono API | One language for page and server; Hono runs unchanged on Node locally and on Cloudflare Workers | Next.js (heavier, ties hosting to Vercel); a Swift server (the Swift pipeline uses Apple's on-device recogniser, which cannot run on a web host) |
| Server-sent events for the pipeline | One request per turn, events arrive as each stage finishes; works on every host | WebSockets (more moving parts for one-way updates) |
| Phrasebook in the browser (IndexedDB), sent with each turn | Speech recordings of a disabled person are health data; the server keeps nothing | A server database |
| Scribe realtime as the live transcript and third vote | Visitors see words appear as they speak; it replaces Apple's on-device recogniser, which a website cannot use | Chrome's Web Speech API (sends audio to Google, Chrome only, no keyterms) |
| Decider and phrasebook matching ported from Swift with the same test cases | Same rules as the evaluated pipeline, including the 9 Nov review fixes | Writing new rules for the web |
| Hosting: Cloudflare (Workers + static assets), set up last | Free tier, no AWS underneath (Vercel runs on AWS) | Vercel, Render |

Keys stay on the server: `ELEVENLABS_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, read from the repo's `.env` locally. Every key has a spending cap; the server limits each visitor's turns per minute.

## 3. Files and owners

| Path | Owner | Contains |
|------|-------|----------|
| `web/shared/pipeline.ts` | lead | The event and request contract |
| `web/shared/rules/` | pipeline | Text normalisation, agreement, phrasebook matching, the decider (pure, used by the server) |
| `web/server/` | pipeline | Hono app: `/api/understand`, `/api/realtime-token`, `/api/speak`, `/api/act`; hearers; repair |
| `web/tests/` | pipeline | Vitest, ported from the Swift tests |
| `web/src/` | page | Everything the visitor sees and the browser audio |
| `web/package.json`, configs | lead | |

## 4. What happens to the Swift work

The Swift package `Packages/HFUnderstand` stays: it is what the evaluation ran against, and the Mac app (parked) would use it. The web port copies its rules and tests so both give the same decisions on the same input.

## 5. Schedule

| When | Work |
|------|------|
| Mon 9 Nov | Server pipeline with streamed events; page with replayed events while the server is built; browser audio and live transcript |
| Tue 10 Nov | Joined up end to end; enrolment, phrasebook, pretend phone, stage switches; evaluation page; review by a second agent; hosting |
| Wed 11 Nov | Write-up, README, ai.md, demo video, clean-clone test, submit by 6pm |
