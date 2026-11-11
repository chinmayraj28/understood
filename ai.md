# How I used AI

I used AI heavily, in two ways: as the coding agent that built most of the code, and as parts of the product itself. This file says which tools did what, how the work was organised, what I decided myself, what the AI got wrong, and how I can vouch for the result.

Where a sentence below is marked **[CHECK]**, it is something I must confirm in my own words before submitting.

## The tools

**Claude Code, as the coding agent.** One lead session planned the work, wrote the shared contract between the parts, ran the whole test suite, and reviewed and integrated what the others produced. The rules it followed are in `CLAUDE.md`. Subagents did the implementation and the reviews. I told the lead to use Opus 5.5 agents for the harder work (design, anything touching safety, integration, debugging, reviews) and Sonnet 5.5 agents for lighter work (documents, mechanical edits), and later to run fewer agents at once, because eight at a time used up the account's limit twice and stalled the work for hours. Counted from the session transcripts on 11 November: the lead sessions ran mostly on Claude Fable 5.1, with some turns on Opus 5.5; the subagents ran almost entirely on Opus 5.5 (about 14,500 model calls), with about 200 on Sonnet 5.5 and a handful on Haiku 5.5. I did not type the code by hand. I chose the problem, made the decisions below, and directed and questioned the work; the agents wrote almost all of it.

**Claude inside the product.** Claude Haiku 5.5 does two jobs, both through the Anthropic Messages API with structured outputs, so its answer always has a fixed shape:

- **Repair:** it reads the three transcripts, the phrasebook matches and the conversation so far, and returns the most likely meaning, a confidence (high, medium or low), up to two alternatives and a one-sentence reason.
- **The pretend phone:** it turns a confirmed sentence into one phone action (message, call, timer, music, reminder). Code checks every field it returns.

Haiku was chosen over Sonnet 5.5 by measurement. On the real repair request, 7 calls each, Haiku took 1.3 to 1.7 s and Sonnet 2.2 to 4.1 s. Both read the test cases correctly, but Sonnet's slow calls would overrun the 3-second repair limit (`DECISIONS.md`, 9 Nov).

**ElevenLabs.** Scribe (`scribe_v2`) is the main recogniser, given the person's contacts and phrases as hints (keyterms). Scribe realtime writes the live transcript on the page and is the third vote. ElevenLabs text-to-speech speaks the assistant's questions.

**Gemini, through OpenRouter.** Gemini Flash (`google/gemini-3.8-flash`) hears each clip after being shown a few recordings of the same person with their correct text. A published study found this cut errors on impaired speech by about a fifth with no training (arXiv 2509.15516).

**The earlier Mac prototype** still in the repo also used Jev (TypeSafe's classifier, through OpenRouter) and code adapted from Clicky, an MIT-licensed open-source Mac app by Farza (`third_party/clicky/NOTICE.md`). Neither is part of the website.

## How the work was organised

- **Plan first, in writing.** `docs/SPEECH_PLAN.md` says why each stage exists and what was rejected. `docs/WEB_PLAN.md` says how the website is built. Both were written before the code.
- **A shared contract before parallel work.** The lead wrote `web/shared/pipeline.ts` first: the request the page sends and the events the server streams back, one per stage. One agent then built the pipeline (`web/shared/rules/`, `web/server/`, `web/tests/`) while another built the page (`web/src/`). Neither edited the other's files.
- **One set of rules, checked against the evaluated one.** The pipeline was first built and measured in Swift (`Packages/HFUnderstand`). The website's decision rules and phrasebook matching are a port of that code, with the same tests, and give the same answer as the Swift version on all 3,902 comparison cases. That way the numbers measured in Swift describe what the website does.
- **A different agent reviews each piece.** Every batch of work was reviewed by an agent that had not written it, and the fixes were committed with the findings listed (see below).
- **Run it for real before relying on it.** Assumptions from search results (for example that OpenRouter accepts audio for Gemini, or how Scribe bills keyterms) were checked with real calls before the design depended on them.

## What I decided myself

1. **Make the product about understanding impaired speech.** On 7 November a Hiya engineer advised building around recognising impaired speech rather than noise cancellation, and being ready to justify every design choice. I agreed it was the bigger gap for the users I had already chosen: people who cannot use their hands very often have dysarthria too, and every voice assistant fails them first.
2. **Show the pipeline on a website.** On 9 November I said: "focus on the speech model, leave the Clicky thing for now; run it on a website and show the pipeline so it's transparent about what it's doing." On 11 November I made the website the whole submission and dropped the Mac app from the documents.
3. **Ask rather than guess.** A wrong action is worse than a slow one, because the person cannot undo it by hand. So the rule for when to act is code, not a prompt, and Claude's confidence alone never makes it act.
4. **Real recordings, not fake ones.** This was my call. The evaluation uses TORGO, real recordings of people with dysarthria, and no synthetic "impaired" speech, because that misrepresents real speech and imitates real people without their consent. TORGO is free for academic, non-profit use: it is used here only to evaluate, never to train, its audio is never committed or published, and the source paper is cited (Rudzicz, Namasivayam and Wolff, 2012).
5. **Recordings stay with the person.** Speech recordings of a disabled person are health data, so the phrasebook and clips live in the browser, and the server stores nothing.
6. **No Amazon or AWS.** That ruled out Vercel for hosting, because it runs on AWS. Cloudflare is planned instead.
7. **How the agents report and when they ask me.** Plain-language reports with examples, no unnecessary questions, and escalation to me only for credentials, anything that reaches a real person, and pushing or submitting.

## What the AI got wrong, and how it was caught

I am listing these because they show where the process needs checking, and because I can explain each one.

**A yes that was not a yes.** A review found that any sentence starting with "okay" or "yes" counted as agreement. So "Okay, message Sam instead", said in reply to "Message Mum?", would have sent the message to Mum. Now a yes counts only if it is just a yes, said after the question finished playing, and questions expire after 60 seconds. The same review found that the page could hear its own spoken question as the person's answer; it now ignores its own voice.

**The model could choose who a message went to.** In an early version, Claude filled in the recipient, so "tell her I'm late" could go to whoever it guessed. Now code accepts a name only if it is a known contact and the person actually said it, and otherwise the phone asks who. Message and call always ask before acting, and the question is written by code, so it always names who and what.

**Agreement that was not independent.** The live transcript is meant to be a check that was not steered by hints. A review found it was counted as independent even when it had been given the same hint words as Scribe, so two recognisers "agreeing" on a hinted name proved little. It now counts only when it shared no hints with the others.

**A "no" that could be outvoted.** In the Swift version, a review found that if one recogniser heard "no" or "don't" and the others did not, the pipeline could still act. Now a negation from any recogniser blocks acting. The same review made strong phrasebook matches require the same recogniser and identical digits, names and negations, and made the phrasebook learn only from a spoken yes, a chosen option or a correction.

**Audio sent when it did not need to be.** The page streamed microphone audio to the live recogniser between turns as well as during them. It now sends audio only during a turn. "Clear everything" also missed some stored data; it now deletes the browser database and the conversation.

**Small things a reviewer caught.** Phrasebook matching had no bound on its cost, so a long sentence could stall it. Text normalisation treated some Unicode characters differently from the Swift version, which would have broken the 3,902-case match. The per-visitor limit was too loose for open endpoints that call paid services.

**An API shape that did not work.** The usual way to force a fixed answer shape is a forced tool call. The API rejects a forced tool choice on Sonnet 5.5, and we wanted one code path while comparing both models, so the repair uses structured outputs instead.

**From the earlier Mac prototype, one lesson that shaped this work.** There, every package passed its own tests, yet the safety check could be bypassed because three packages described a Send button in different words. Only a test across packages found it. That is why the website's rules are tested against the Swift version case by case rather than trusted because each side passes alone. In the same phase, agents copied a real phone number into code and tests as an example. It was removed before the first commit, and real details now stay only in the ignored `.env`.

**The limit of AI review.** A reviewer is also an AI. It caught what it was pointed at. None of this replaces testing with real people.

## How the evaluation was kept honest

- **No clip is in both the setup and the test.** For each speaker, a phrase said more than once has its first recording used for setup and later ones for testing. Results are split into phrases seen during setup and phrases not seen (`eval/README.md`, section 2).
- **Each stage is measured by adding it to the one before**, so the table shows what each stage adds, including where it made things worse: adding Gemini let the pipeline act on 39% of clips, but it was wrong on 7%.
- **The safety number is reported, not only accuracy.** "Acted, and was wrong" must be near zero. It is 2% for the full pipeline.
- **The limits are stated:** one dataset, a handful of speakers, single runs, mostly short phrases.

## How I can vouch for the code

- **The tests.** The website has 259 tests in 28 files, all passing on 11 Nov 2026, with no network. They include the safety cases above, and the checks that keep the TORGO recordings on this computer. The Swift package has its own tests, including the review findings.
- **A live run.** `web/tests/live.smoke.ts` sends a real clip through every stage with real keys. On 11 Nov 2026, Scribe misheard a synthetic "message Sam running late" as "Mum sis, I'm running late", Gemini timed out, and the pipeline asked "Message Sam running late?" rather than acting.
- **The decision log.** `DECISIONS.md` records each choice, what was rejected and why.
- **Plain rules.** Each decision on the page comes with the rule that fired, in words, and the rules are one short file (`web/shared/rules/decider.ts`).

What is not yet verified, and I will not claim otherwise: use by a person with dysarthria live (the evaluation used real recordings offline; the live checks used synthetic voices), a hosted deployment, and the cost per turn at scale. **[CHECK: whether I have done a spoken run in the browser myself, and what happened.]**

**What I did myself.** I chose the problem and every change of direction listed above, and I set the rules the agents worked under. I had each stage of the pipeline explained to me in plain words, including why it exists and what was rejected. The agents' own checks (the test suite and the live run above) were run by them and reported to me; I have not re-run them myself.
