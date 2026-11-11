# How I used AI

I built this the way an engineering lead runs a small team. AI agents wrote the code; I chose the problem, made the design calls, set the rules they worked under, and held every claim to measured evidence. AI also runs inside the product. This file covers which tools did what, how I organised and checked the work, the decisions that were mine, and how I know the result holds up.

## The tools

**Claude Code, as the coding team.** One lead session planned the work, wrote the shared contract between the parts, ran the full test suite, and integrated what the others produced. Subagents did the implementation, the research and the reviews. The working rules I set are in `CLAUDE.md`. I matched the model to the job: Opus 5.5 for design, safety, integration, debugging and reviews; Sonnet 5.5 for documents and mechanical edits. When running eight agents at once exhausted the account's limits and stalled progress, I capped parallelism at three or four, which kept the work moving. From the session transcripts: the lead ran mostly on Claude Fable 5.1 with some Opus 5.5; the subagents made about 14,500 Opus 5.5 calls, about 200 Sonnet 5.5 calls and a handful on Haiku 5.5.

**Claude inside the product.**
- **Repair, for a spoken sentence (Haiku 5.5):** reads the transcripts, the phrasebook and the conversation, and returns the most likely meaning with a confidence and a one-sentence reason. Haiku was chosen over Sonnet by measurement: 1.3–1.7 s against 2.2–4.1 s on the real request, and Sonnet's slow calls would overrun the 3-second budget.
- **Repair, for a recording (Opus 5.5):** merges the transcripts into one verbatim transcript. Chosen because it made the fewest word errors of the three models on TORGO dev clips (`docs/TRANSCRIPTION.md`).
- **The pretend phone (Haiku 5.5):** turns a confirmed sentence into one action. Code checks every field it returns.
- All through the Messages API with structured outputs, so every answer has a fixed shape.

**ElevenLabs.** Scribe is the main recogniser: `scribe_v2` with the person's contacts and phrases as hints for speech, `scribe_v3` without fillers for recordings. Scribe realtime writes the live transcript and is a vote. Text-to-speech speaks the assistant's questions.

**Gemini, through OpenRouter.** Gemini hears each clip after being shown a few recordings of the same person with their correct text, which a published study found cuts errors on impaired speech without any training (arXiv 2509.15516). Speech uses Gemini 3.8 Flash for speed; recordings use Gemini 3.1 Pro plus Gemini 4 Carbon as a second, independent listener, chosen by measuring five audio models.

**The earlier Mac prototype** (removed from this repo for the submission) also used Jev (TypeSafe's classifier) and code adapted from Clicky, an MIT-licensed Mac app by Farza. Neither is part of the website.

## The decisions that were mine

1. **The problem.** After feedback from a Hiya engineer on 7 November, I moved the product from voice control of a laptop to understanding impaired speech. People who cannot use their hands very often have dysarthria too, and every voice assistant fails them first, so this was the bigger gap for the same users.
2. **Transparency as the product.** On 9 November I asked for the pipeline to run on a website that shows every stage live, so a user (or a reviewer) can see exactly why it heard what it heard. On 11 November I made the website the whole submission.
3. **Ask rather than guess.** A wrong action is worse than a slow one, because the person cannot undo it by hand. So the rule for acting is code, not a prompt, and the model's confidence alone never makes it act.
4. **Real recordings, never synthetic "impaired" speech.** Faking dysarthric speech misrepresents it and imitates real people without consent. I chose TORGO, real recordings, used only to evaluate, never to train, never committed or published, and cited (Rudzicz, Namasivayam and Wolff, 2012).
5. **Health data stays with the person.** The phrasebook and voice clips live in the browser; the server stores nothing.
6. **The quality bar for transcription.** Testing the page myself, I saw transcripts that were wrong in ways that mattered (a whole sentence came back as "meat"). I asked for it to be fixed and measured on real audio, with no hand-picked examples and no invented benchmarks. That bar is why the work below used a held-out set.
7. **Vendor and data rules.** No Amazon or AWS (which ruled out Vercel), keys only in an ignored `.env`, and nothing that reaches a real person without a spoken yes.

## How I organised and checked the work

- **Plan first, in writing.** `docs/SPEECH_PLAN.md` and `docs/WEB_PLAN.md` were written before the code, with the options rejected and why.
- **A shared contract before parallel work.** The request and the event stream (`web/shared/pipeline.ts`) were fixed first, so one agent could build the pipeline and another the page without touching each other's files.
- **One set of rules, proven equal to the evaluated one.** The pipeline was first built and measured in Swift. The website's decision rules are a port, tested to give the same answer on all 3,902 comparison cases, so the measurements carry over.
- **Independent review of every piece.** Each batch was reviewed by an agent that had not written it, and its findings were fixed and re-tested before moving on.
- **Verify, don't assume.** Claims from documentation or search (for example, which models accept audio, or how an API bills) were checked with real calls before the design relied on them.

### What that process caught

These are the kind of failures that look fine until something checks them. Each one was caught by the review or testing step and fixed with a test.

- **A "yes" that wasn't one.** "Okay, message Sam instead", said in reply to "Message Mum?", would have counted as agreement. Now a yes counts only if it is just a yes, said after the question finished playing.
- **The model choosing who a message goes to.** "Tell her I'm late" could have gone to whoever the model guessed. Now code accepts a recipient only if it is a known contact the person actually said.
- **Agreement that wasn't independent.** Two recognisers "agreeing" on a name they had both been hinted towards proved little. The independent vote now counts only when it shared no hints.
- **A "no" that could be outvoted.** A negation heard by any recogniser now blocks acting.
- **Recordings leaving the computer.** Testing the public demo link from outside showed the TORGO recordings were reachable through the tunnel. It was shut within seconds, the local-only check was hardened against proxied requests, and the link was shared only after the same test returned 403.
- **A safety regression in an improvement.** The transcription work first switched spoken turns to a mode that drops false starts, which could have dropped the "no" in "Mum, no, Sam". Review caught it; spoken turns keep every word.
- **Smaller issues:** unbounded matching cost, a Unicode normalisation mismatch with the Swift version, audio streamed between turns, and a per-visitor limit too loose for paid endpoints.

## The transcription work on 11 November

Starting from the bar I set (real audio, held-out results), the work went like this:
- **Measure.** The agents built a harness that runs the website's own pipeline on TORGO. They split the test clips once into a dev half, used for every choice, and a held-out half, used only to report.
- **Compare.** They compared 13 speech recognisers, 5 audio models and several ways of merging transcripts. A research agent surveyed the literature and current API documentation.
- **Diagnose.** Reading the failures found two causes: Gemini copied its example clips, and the repair prompt rewrote correct transcripts as phone commands.
- **Result.** On 220 held-out clips, words wrong fell from **39.9% to 20.6%**, and from 52.9% to 27.6% for speakers with dysarthria. The gain is on new speech the speaker never said during setup (43.5% → 22.4%), not on memorised phrases.

The full record is `docs/TRANSCRIPTION.md`: what changed, the evidence for each choice, what was tried and rejected, and the limits.

## How I know it holds up

- **Tests.** 283 tests in 30 files, all passing, with no network. They include every safety case above and the checks that keep the TORGO recordings on this computer.
- **Held-out evaluation.** The accuracy numbers come from recordings never used to make a choice, and both held-out samples are reported, including the harder one.
- **Live runs.** Real clips through every stage with real keys, on the page and through the API. The page was also tested end to end by me, on TORGO recordings, uploaded audio and my own voice.
- **A readable decision log.** `DECISIONS.md` records each choice, what was rejected and why. Every decision on the page shows the rule that fired, in words.

**What is not yet verified:** use by people with dysarthria themselves, live; a permanent hosted deployment; and cost per turn at scale. Those are the next steps, in that order, because the first is the one that matters most.
