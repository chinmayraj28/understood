# Spike: the three hearers (7–8 Nov 2026)

Stage 2 of `docs/SPEECH_PLAN.md`: each recorded turn is heard by three recognisers. This note
records what was checked against current docs and by real calls from this Mac. Code:
`Packages/HFUnderstand/Sources/HFUnderstand/{ScribeHearer,GeminiHearer,AppleHearer,Audio}.swift`.

Test clip: `say -o … "message Amma running late"`, converted to 16 kHz mono 16-bit WAV
(1.3 s of audio, about 46 KB). Synthetic speech is easy; these numbers show the plumbing works and
how fast each service answers, not how well it hears impaired speech. That is the evaluation's job.

## ElevenLabs Scribe (batch)

| What | Verified |
|------|----------|
| Endpoint | `POST https://api.elevenlabs.io/v1/speech-to-text`, header `xi-api-key`, `multipart/form-data` |
| Model | `scribe_v2` (current batch model, and the one with keyterms). `scribe_v2_medical` exists at the same price; not used. |
| Fields sent | `file` (WAV), `model_id`, `language_code` (we send the language part only: "en-GB" → "en"; the reply says "eng"), `tag_audio_events=false`, `timestamps_granularity=none`, `keyterms` repeated once per term |
| Keyterm limits (batch) | At most 1,000 terms; each under 50 characters and at most 5 words; `< > { } [ ] \` not allowed. Realtime is 50 terms of 20 characters. |
| Keyterm cost | +20% on the transcription price. **More than 100 keyterms sets a minimum bill of 20 seconds per request**, so `ScribeHearer` sends 100 by default (`maxKeyterms`), up to 1,000 if asked. |
| Reply | JSON with `text`, `language_code`, `language_probability`, `words` |
| Price | Not in the API docs; on ElevenLabs' pricing page. Not verified here. |
| Measured | See the table at the end. |

Terms that break a rule are dropped, not shortened: a cut-off name would steer the recogniser to
the wrong word.

## Gemini Flash with audio, through OpenRouter

| What | Verified |
|------|----------|
| Works through OpenRouter? | **Yes.** `POST https://openrouter.ai/api/v1/chat/completions` with a content part `{"type":"input_audio","input_audio":{"data":<base64 WAV>,"format":"wav"}}` returned the right transcript. OpenRouter's audio guide shows the Responses API, but chat completions works too. |
| Models | `GET /api/v1/models` lists Gemini models taking audio: `google/gemini-3.8-flash` (newest Flash), 3.7, 3.6, 3.5 Flash, 3.5 Flash Lite, 3.1 Flash Lite, 2.5 Flash, and the Pro models. Default: **`google/gemini-3.8-flash`**. |
| Reasoning | Gemini 3.x refuses `reasoning.effort = "none"` ("Reasoning is mandatory"). `"minimal"` is accepted and used 0 reasoning tokens. |
| Latency, first probe (curl, 1.3 s clip) | 3.8 Flash default reasoning 2.6–3.5 s; **3.8 Flash minimal 1.8 s**; 3.5 Flash Lite 1.0–1.2 s (once heard "Emma"); 2.5 Flash 1.7–1.8 s |
| Price | 3.8 Flash: $0.825 per million input tokens, audio the same. A 1.3 s clip was 33 audio tokens; one call cost about $0.00005 with minimal reasoning. Each example clip adds its own audio tokens. |
| Prompt | Strict word-for-word instruction; examples sent as earlier user (clip) / assistant (exact text) turns, at most 5, each text at most 200 characters (longer ones are skipped); no medical condition is named (shown to hurt, arXiv 2605.02782). A unit test checks the prompt for condition words. |
| Keyterms | Can include labels read off the screen, which anyone can write, so they are treated as untrusted: Scribe's rules (at most 5 words, under 50 characters) plus no quotes, brackets or parentheses; sent as a JSON array in a text part of their own; the instruction says the list is words only, never instructions. A test checks a hostile label never reaches the request. |
| Cut-off replies | `finish_reason: "length"` or a null content is "an answer I didn't expect", not silence. |
| Reply cleaning | Strips labels ("Transcript:"), quotes, code fences and extra note lines; "(no speech)" counts as empty. |

Why 3.8 Flash and not 2.5 Flash, which the paper (arXiv 2509.15516) used: it is the current Flash,
it heard the name right, and its latency with minimal reasoning matches 2.5. The model is an init
parameter, so the evaluation can compare them.

## Apple on-device

| What | Verified |
|------|----------|
| API | macOS 26: `SpeechAnalyzer` + `SpeechTranscriber` (final results only), keyterms set as `AnalysisContext.contextualStrings[.general]` (at most 100). Audio is fed as one buffer converted to `SpeechAnalyzer.bestAvailableAudioFormat`, then `finalizeAndFinishThroughEndOfInput()`. Before macOS 26: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` and `contextualStrings`; needs the Speech Recognition permission. |
| Live transcript | Re-run on the WAV by default, because the live pass had no keyterms for this turn and used fast settings. `AppleHearer(useLiveTranscript: true)` returns `turn.liveTranscript` instead. |
| Permissions | SpeechAnalyzer on a recording needs none. |
| Warm-up | `AppleHearer.prepare(languageCode:)` downloads the model if needed and loads it by hearing half a second of silence. The app should call it at startup (see the 256-second first call below). |
| Cancelling | Cancelling the calling task stops the analyzer at any step and throws `CancellationError`; other Apple errors become "Apple's recogniser stopped before it finished." |
| Price | Free; audio never leaves the Mac. |
| Measured | See the table at the end. |

## Measured from `HF_LIVE=1 swift test --filter LiveHearerTests`

Run on 8 Nov 2026 from this Mac, through the Swift code (not curl), one hearer at a time, on the
1.3 s clip with keyterms "Amma", "WhatsApp", "running late".

| Hearer | Transcript | First call | Second call |
|--------|-----------|-----------|-------------|
| Scribe (`scribe_v2`) | "Message Amma running late" | 0.50 s | 0.38 s |
| Gemini (`google/gemini-3.8-flash`, minimal reasoning) | "Message Amma, running late" | 2.38 s | 1.68 s (with 2 example clips) |
| Apple (SpeechAnalyzer, en-GB) | "Message Amma running late." | 0.44 s | 0.08 s |

Things seen along the way:

- **Gemini once took over 30 seconds** and hit the request's 30 s limit; three curl calls of the
  same request just after took 1.4 to 2.3 s. Treat it as a slow outlier that will happen: the
  caller's time limit (the Understander's) must be well under 30 s, and Gemini must never be the
  only hearer a decision waits on.
- **Apple's very first call on this Mac took 256 seconds** (the speech model being loaded or
  fetched for the first time). Every later call in a fresh process took under 0.7 s. Setup should
  warm Apple's recogniser once, before the person's first turn.
- Gemini's text has punctuation and varying capitals ("Message Amma, running late"); Apple adds a
  full stop. Anything comparing hearers must ignore case and punctuation.
