// Hand-written checks for every request body. The server is on the open internet and pays for
// every call it makes, so anything malformed or oversized is refused before any money is spent.

import type { ActRequest, HearerName, PhrasebookEntry, SpeakRequest, SpeechExample, StageSwitches, TurnContext, UnderstandRequest } from "../shared/pipeline";
import { words } from "../shared/rules/speechText";
import { decodedLength } from "./http";

/** The turn's recording: 2 MB is about a minute of 16 kHz speech, far longer than any command. */
export const maxWavBytes = 2_000_000;
/** One of the person's clips: they are short phrases. */
export const maxExampleBytes = 1_000_000;
export const maxExamples = 5;
/**
 * Phrasebook size and the live transcript's length bound the matching work, which grows with
 * (words heard) × (words stored) × (entries). These limits keep the worst allowed turn well
 * under 200 ms of CPU; a real phrasebook is a few dozen short phrases.
 */
export const maxPhrasebookEntries = 200;
export const maxPhraseWords = 20;
export const maxRealtimeCharacters = 600;
/** Scribe realtime takes at most 50 keyterms. */
export const maxRealtimeKeyterms = 50;
export const maxSpeakCharacters = 300;

export type Checked<T> = { ok: true; value: T } | { ok: false; error: string };

class Invalid extends Error {}
const fail = (message: string): never => { throw new Invalid(message); };

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

function text(value: unknown, field: string, maxLength: number, options: { optional?: boolean; nonEmpty?: boolean } = {}): string | undefined {
  if (value === undefined || value === null) return options.optional ? undefined : fail(`${field} is missing.`);
  if (typeof value !== "string") return fail(`${field} must be text.`);
  if (value.length > maxLength) return fail(`${field} is too long.`);
  if (options.nonEmpty && !value.trim()) return fail(`${field} is empty.`);
  return value;
}

function list<T>(value: unknown, field: string, maxCount: number, item: (entry: unknown, name: string) => T, optional = false): T[] | undefined {
  if (value === undefined || value === null) return optional ? undefined : fail(`${field} is missing.`);
  if (!Array.isArray(value)) return fail(`${field} must be a list.`);
  if (value.length > maxCount) return fail(`${field} has too many items.`);
  return value.map((entry, index) => item(entry, `${field}[${index}]`));
}

function count(value: unknown, field: string, max: number, optional = false): number | undefined {
  if (value === undefined || value === null) return optional ? undefined : fail(`${field} is missing.`);
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > max) return fail(`${field} must be a number from 0 to ${max}.`);
  return value;
}

const base64Pattern = /^[A-Za-z0-9+/]*={0,2}$/;

function wav(value: unknown, field: string, maxBytes: number): string {
  const data = text(value, field, Math.ceil(maxBytes / 3) * 4 + 4, { nonEmpty: true })!;
  if (data.length % 4 !== 0 || !base64Pattern.test(data)) fail(`${field} must be base64.`);
  if (decodedLength(data) > maxBytes) fail(`${field} is too large.`);
  return data;
}

const hearerNames: HearerName[] = ["scribe", "gemini", "realtime"];
const sources: PhrasebookEntry["source"][] = ["enrolment", "confirmation", "correction"];

function entry(value: unknown, field: string): PhrasebookEntry {
  if (!isObject(value)) return fail(`${field} must be an object.`);
  const hearer = value.hearer as HearerName;
  if (!hearerNames.includes(hearer)) fail(`${field}.hearer is not a known recogniser.`);
  const source = value.source as PhrasebookEntry["source"];
  if (!sources.includes(source)) fail(`${field}.source is not known.`);
  return {
    id: text(value.id, `${field}.id`, 100)!, meant: phrase(value.meant, `${field}.meant`), heard: phrase(value.heard, `${field}.heard`),
    // A whole number, as Swift stores it.
    hearer, timesConfirmed: Math.floor(count(value.timesConfirmed, `${field}.timesConfirmed`, 100_000)!),
    lastConfirmedAt: count(value.lastConfirmedAt, `${field}.lastConfirmedAt`, 1e14)!, source,
  };
}

/** A stored phrase: at most 300 characters and at most 20 words. */
function phrase(value: unknown, field: string): string {
  const result = text(value, field, 300)!;
  if (words(result).length > maxPhraseWords) fail(`${field} has too many words.`);
  return result;
}

function example(value: unknown, field: string): SpeechExample {
  if (!isObject(value)) return fail(`${field} must be an object.`);
  return { wavBase64: wav(value.wavBase64, `${field}.wavBase64`, maxExampleBytes), text: text(value.text, `${field}.text`, 300)! };
}

function context(value: unknown): TurnContext {
  if (value === undefined || value === null) return {};
  if (!isObject(value)) return fail("context must be an object.");
  const result: TurnContext = {};
  const question = text(value.pendingQuestion, "context.pendingQuestion", 300, { optional: true });
  if (question !== undefined) result.pendingQuestion = question;
  const answers = list(value.expectedAnswers, "context.expectedAnswers", 10, (item, name) => text(item, name, 100)!, true);
  if (answers) result.expectedAnswers = answers;
  const turns = list(value.recentTurns, "context.recentTurns", 20, (item, name) => text(item, name, 500)!, true);
  if (turns) result.recentTurns = turns;
  const tries = count(value.failedTries, "context.failedTries", 100, true);
  if (tries !== undefined) result.failedTries = Math.floor(tries);
  return result;
}

function switches(value: unknown): StageSwitches {
  if (!isObject(value)) return fail("switches is missing.");
  const names = ["keyterms", "gemini", "examples", "phrasebook", "repair"] as const;
  for (const name of names) if (typeof value[name] !== "boolean") fail(`switches.${name} must be true or false.`);
  return { keyterms: value.keyterms as boolean, gemini: value.gemini as boolean, examples: value.examples as boolean, phrasebook: value.phrasebook as boolean, repair: value.repair as boolean };
}

function checked<T>(build: () => T): Checked<T> {
  try {
    return { ok: true, value: build() };
  } catch (error) {
    if (error instanceof Invalid) return { ok: false, error: error.message };
    throw error;
  }
}

export function checkUnderstand(body: unknown): Checked<UnderstandRequest> {
  return checked(() => {
    if (!isObject(body)) return fail("The request must be a JSON object.");
    const realtimeText = text(body.realtimeText, "realtimeText", maxRealtimeCharacters, { optional: true });
    const realtimeKeyterms = list(body.realtimeKeyterms, "realtimeKeyterms", maxRealtimeKeyterms, (item, name) => text(item, name, 100)!, true);
    return {
      turnId: text(body.turnId, "turnId", 100, { nonEmpty: true })!,
      wavBase64: wav(body.wavBase64, "wavBase64", maxWavBytes),
      ...(realtimeText !== undefined ? { realtimeText } : {}),
      ...(realtimeKeyterms !== undefined ? { realtimeKeyterms } : {}),
      phrasebook: list(body.phrasebook, "phrasebook", maxPhrasebookEntries, entry)!,
      examples: list(body.examples, "examples", maxExamples, example)!,
      keyterms: list(body.keyterms, "keyterms", 200, (item, name) => text(item, name, 100)!)!,
      context: context(body.context),
      switches: switches(body.switches),
      ...(body.purpose === undefined ? {} : { purpose: purpose(body.purpose) }),
    };
  });
}

function purpose(value: unknown): "conversation" | "transcribe" {
  if (value !== "conversation" && value !== "transcribe") return fail(`purpose must be "conversation" or "transcribe".`);
  return value;
}

export function checkAct(body: unknown): Checked<ActRequest> {
  return checked(() => {
    if (!isObject(body)) return fail("The request must be a JSON object.");
    const recentTurns = list(body.recentTurns, "recentTurns", 20, (item, name) => text(item, name, 500)!, true);
    return { text: text(body.text, "text", 500, { nonEmpty: true })!, ...(recentTurns ? { recentTurns } : {}) };
  });
}

export function checkSpeak(body: unknown): Checked<SpeakRequest> {
  return checked(() => {
    if (!isObject(body)) return fail("The request must be a JSON object.");
    return { text: text(body.text, "text", maxSpeakCharacters, { nonEmpty: true })! };
  });
}
