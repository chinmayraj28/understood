// The two recognisers the server calls. The third, the realtime transcript, is heard in the
// browser while the person speaks and arrives with the request.
// Request details are copied from the Swift ScribeHearer.swift and GeminiHearer.swift, which
// were checked against the docs and by real calls on 7 Nov 2026 (docs/spikes/hearers.md).

import type { SpeechExample } from "../shared/pipeline";
import { base64ToBytes, send, ServiceFailure } from "./http";

/** What a hearer gets: the turn's WAV (base64), example clips, and a signal that ends it early. No word list. */
export interface HearingRequest {
  wavBase64: string;
  examples: SpeechExample[];
  signal: AbortSignal;
  /** Seconds, only for wording a time-out. */
  seconds: number;
  /** "transcribe" for a recording: Gemini gets the transcription prompt and layout (see below). */
  purpose?: "conversation" | "transcribe";
  /** The audio model to ask; defaults to geminiModel. */
  model?: string;
}

// MARK: ElevenLabs Scribe (batch)
// POST https://api.elevenlabs.io/v1/speech-to-text, header xi-api-key, multipart form with
// `file`, `model_id` and `language_code`. No word list is sent: the recognisers hear every turn
// with nothing to pull them towards expected words.
//
// scribe_v3 with no_verbatim (fillers, false starts and non-speech sounds left out) was the most
// accurate recogniser tried on TORGO dev clips on 11 Nov: 25.2% of words wrong, against 29.7% for
// scribe_v2 and 27.7% for the best other service (scripts/compareRecognisers.ts, docs/TRANSCRIPTION.md).
export const scribeModel = "scribe_v3";
/** A spoken turn keeps scribe_v2 and every word: no_verbatim could drop the "no" in "Mum, no, Sam". */
export const conversationScribeModel = "scribe_v2";

export const scribeEndpoint = "https://api.elevenlabs.io/v1/speech-to-text";

/** The multipart form for Scribe. Separate so tests can check its shape. */
export function scribeForm(request: HearingRequest): FormData {
  const form = new FormData();
  const transcribing = request.purpose === "transcribe";
  form.append("model_id", transcribing ? scribeModel : conversationScribeModel);
  form.append("language_code", "en");
  // For a recording, leave out "uh", "um" and restarts: on impaired speech they are mostly the
  // recogniser filling a gap. Never for a spoken turn, where a false start can carry a "no".
  if (transcribing) form.append("no_verbatim", "true");
  // Sounds such as "(laughs)" are not words the person said; leave them out of the text.
  form.append("tag_audio_events", "false");
  // Word timings are not used, so don't ask for them.
  form.append("timestamps_granularity", "none");
  const bytes = base64ToBytes(request.wavBase64);
  form.append("file", new Blob([bytes as BlobPart], { type: "audio/wav" }), "turn.wav");
  return form;
}

export async function hearWithScribe(apiKey: string, request: HearingRequest): Promise<string> {
  if (!apiKey) throw new ServiceFailure("There's no ElevenLabs key, so Scribe can't be used.");
  const response = await send(scribeEndpoint, {
    method: "POST", headers: { "xi-api-key": apiKey }, body: scribeForm(request), signal: request.signal,
  }, "ElevenLabs", request.seconds);
  const reply = (await response.json().catch(() => null)) as { text?: unknown } | null;
  if (!reply || (reply.text !== undefined && typeof reply.text !== "string")) throw new ServiceFailure("ElevenLabs gave an answer I didn't expect.");
  const text = (reply.text as string | undefined ?? "").trim();
  if (!text) throw new ServiceFailure("ElevenLabs heard no words.");
  return text;
}

// MARK: Gemini Flash with audio, through OpenRouter
// Chat completions with an `input_audio` part (base64 WAV). google/gemini-3.8-flash is the newest
// Flash that takes audio; its reasoning cannot be turned off, but "minimal" keeps a 2-second clip
// to about 1.8 s. The research behind it (arXiv 2509.15516): showing the model 3 to 5 of the same
// speaker's clips with their correct text cut word errors from 28.1% to 22.0%. Those clips go in
// as earlier user and assistant turns. The prompt never names a medical condition: doing so made
// results worse (arXiv 2605.02782).

export const geminiEndpoint = "https://openrouter.ai/api/v1/chat/completions";
export const geminiModel = "google/gemini-3.8-flash";
/**
 * For a recording, accuracy over speed. On 66 TORGO dev clips with five of the speaker's own
 * clips and the transcription layout, Gemini 3.1 Pro got 13.9% of words wrong (median 3.9 s) and
 * Gemini 4 Carbon 14.9% (median 5.4 s), against 36.6% for Flash with the old layout; together
 * with Scribe v3 and Claude Opus merging them, 11.4% (docs/TRANSCRIPTION.md).
 */
export const transcribeGeminiModel = "google/gemini-3.1-pro-preview";
export const secondListenerModel = "google/gemini-4-carbon";
const maxExamples = 5;
/** Five of the speaker's clips: ten were no better on TORGO dev clips (docs/TRANSCRIPTION.md). */
export const maxTranscribeExamples = 5;
const maxExampleCharacters = 200;
export const noSpeechReply = "(no speech)";
const transcribeAsk = "Transcribe this clip.";

/** The instruction. Plain and strict: write down the words, do not fix or explain them. */
export const geminiInstruction = [
  "You write down exactly what a person says in a short audio clip, word for word. The person is talking to their phone, usually giving a short command or answering a question. The language is British English.",
  "",
  "Reply with only the words spoken, as plain text on one line. No quotes, labels, notes or explanations.",
  "Keep the person's own words even when they are unusual, unfinished or ungrammatical. Do not correct, complete, reword or translate them.",
  "If a word is hard to make out, write your best guess of the word that was said.",
  "Earlier clips from the same person may come first, each followed by exactly what they said. Use them to learn how this person sounds.",
  `If there is no speech at all, reply with only: ${noSpeechReply}`,
].join("\n");

const audioPart = (wavBase64: string) => ({ type: "input_audio", input_audio: { data: wavBase64, format: "wav" } });

/**
 * For a recording: no "talking to a phone" framing, and the speaker's clips go in one message,
 * each labelled as a reference, with the new clip last and named as the only one to write down.
 * Example turns as separate chat turns let the model answer with an example's text (a whole
 * sentence came back as "meat", one of the examples).
 */
export const geminiTranscribeInstruction = [
  "You write down exactly what a person says in an audio recording, word for word. Their speech may be slow, slurred or quiet. The language is English.",
  "",
  "You may first hear reference recordings of the same person, each with exactly what they said, so you can learn how this person sounds. The reference recordings are not the recording to transcribe. The recording to transcribe is the last one, and it may say something completely different from every reference.",
  "Reply with only the words spoken in the last recording, as plain text on one line. No quotes, labels, notes or explanations.",
  "Keep the person's own words even when they are unusual or unfinished. Do not correct, complete, reword or translate them, and leave out fillers such as uh and um.",
  "If a word is hard to make out, write your best guess of the word that was said.",
  `If there is no speech at all, reply with only: ${noSpeechReply}`,
].join("\n");

function transcribeBody(request: HearingRequest, examples: SpeechExample[]): Record<string, unknown> {
  const content: unknown[] = [];
  examples.forEach((example, i) => {
    // The text is untrusted (it can come from the page): one line, as a JSON string, so it cannot close the quote.
    const said = JSON.stringify(example.text.replace(/[\r\n]+/g, " ").trim());
    content.push({ type: "text", text: `Reference recording ${i + 1} of ${examples.length}. This person said: ${said}` });
    content.push(audioPart(example.wavBase64));
  });
  content.push({ type: "text", text: examples.length ? "The recording to transcribe (a new recording, not one of the references):" : "The recording to transcribe:" });
  content.push(audioPart(request.wavBase64));
  return {
    model: request.model ?? geminiModel,
    messages: [{ role: "system", content: geminiTranscribeInstruction }, { role: "user", content }],
    temperature: 0,
    max_tokens: 512,
    reasoning: { effort: "low", exclude: true },
  };
}

/** The chat request body. Separate so tests can check its shape. */
export function geminiBody(request: HearingRequest): Record<string, unknown> {
  if (request.purpose === "transcribe") {
    const usable = request.examples.filter((e) => e.text.trim().length > 0 && [...e.text.trim()].length <= maxExampleCharacters);
    return transcribeBody(request, usable.slice(0, maxTranscribeExamples));
  }
  const messages: unknown[] = [{ role: "system", content: geminiInstruction }];
  const examples = request.examples.filter((example) => {
    const text = example.text.trim();
    return text.length > 0 && [...text].length <= maxExampleCharacters;
  });
  for (const example of examples.slice(0, maxExamples)) {
    messages.push({ role: "user", content: [{ type: "text", text: transcribeAsk }, audioPart(example.wavBase64)] });
    messages.push({ role: "assistant", content: example.text.trim() });
  }
  messages.push({ role: "user", content: [{ type: "text", text: transcribeAsk }, audioPart(request.wavBase64)] });
  return {
    model: geminiModel, messages, temperature: 0,
    // A command is a few words; this only stops a runaway reply from costing money.
    max_tokens: 512,
    reasoning: { effort: "minimal", exclude: true },
  };
}

export async function hearWithGemini(apiKey: string, request: HearingRequest): Promise<string> {
  if (!apiKey) throw new ServiceFailure("There's no OpenRouter key, so Gemini can't be used.");
  const response = await send(geminiEndpoint, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json", "X-Title": "Understood" },
    body: JSON.stringify(geminiBody(request)), signal: request.signal,
  }, "Gemini", request.seconds);
  const text = cleanTranscript(geminiReplyText(await response.json().catch(() => null)));
  if (!text) throw new ServiceFailure("Gemini heard no words.");
  return text;
}

/**
 * The assistant text from a chat completions reply. OpenRouter can answer 200 with an `error`
 * object when the model's provider failed. A reply cut off by the token limit, or with no
 * content at all, is a broken reply, not silence.
 */
export function geminiReplyText(json: unknown): string {
  const unexpected = new ServiceFailure("Gemini gave an answer I didn't expect.");
  if (!json || typeof json !== "object") throw unexpected;
  const reply = json as { error?: unknown; choices?: { finish_reason?: unknown; message?: { content?: unknown } }[] };
  if (reply.error) throw new ServiceFailure("Gemini had a problem on its side.");
  const choice = reply.choices?.[0];
  if (!choice?.message) throw unexpected;
  if (choice.finish_reason === "length") throw unexpected;
  const content = choice.message.content;
  if (typeof content === "string") return content;
  // Some providers send the content as a list of parts.
  if (Array.isArray(content)) return content.map((part) => (typeof part?.text === "string" ? part.text : "")).join(" ");
  throw unexpected;
}

/**
 * Strips what a chat model sometimes adds around a transcript: a label such as "Transcript:",
 * surrounding quotes or code fences, extra lines, and the no-speech reply.
 */
export function cleanTranscript(raw: string): string {
  let text = raw.trim().replace(/^```[a-z]*\s*|\s*```$/g, "");
  text = text.replace(/^(here(?:'s| is) (?:the |a |your )?(?:verbatim )?(?:transcript(?:ion)?|text)[^:\n]*:|(?:verbatim )?transcript(?:ion)?:|text:)\s*/i, "").trim();
  for (const [open, close] of [['"', '"'], ["'", "'"], ["“", "”"], ["‘", "’"]]) {
    if (text.length >= 2 && text.startsWith(open) && text.endsWith(close)) text = text.slice(1, -1).trim();
  }
  // Several lines means the model added a note; the transcript is the first line.
  text = text.split(/\r?\n/).find((line) => line.trim().length > 0) ?? "";
  const lowered = text.trim().toLowerCase();
  if (lowered === noSpeechReply || lowered === "no speech") return "";
  return text.trim();
}
