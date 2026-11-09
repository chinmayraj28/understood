// Shared test helpers, mirroring the Swift test helpers so the cases read the same.
import type { HearerName, PhrasebookEntry, PhrasebookMatch, Reading } from "../shared/pipeline";
import { decide as decideRule } from "../shared/rules/decider";
import type { DecisionInput, Hypothesis } from "../shared/rules/types";

/** Scribe, Gemini and realtime; `null` is a hearer that failed (timed out). */
export function heard(scribe: string | null, gemini: string | null, realtime: string | null): Hypothesis[] {
  const one = (hearer: HearerName, text: string | null): Hypothesis =>
    text === null ? { hearer, text: "", seconds: 4, failure: "timed out" } : { hearer, text, seconds: 0.1 };
  return [one("scribe", scribe), one("gemini", gemini), one("realtime", realtime)];
}

export function reading(text: string, confidence: Reading["confidence"], alternatives: string[] = []): Reading {
  return { text, confidence, alternatives, reason: "" };
}

export function match(meant: string, heardText: string, similarity: number, timesConfirmed: number): PhrasebookMatch {
  return { entryId: "x", meant, heard: heardText, similarity, timesConfirmed, strong: false };
}

/** Like the Swift DeciderTests `decide`: `scribeMatch` is Scribe's own match; `own` adds the others'. */
export function decide(
  hypotheses: Hypothesis[],
  options: {
    reading?: Reading; scribeMatch?: PhrasebookMatch; own?: Partial<Record<HearerName, PhrasebookMatch>>;
    expected?: string[]; failedTries?: number;
  } = {},
) {
  const byHearer = { ...(options.own ?? {}) };
  if (options.scribeMatch) byHearer.scribe = options.scribeMatch;
  const expected = options.expected ?? [];
  return decideRule({
    hypotheses, matchesByHearer: byHearer, reading: options.reading,
    context: { pendingQuestion: expected.length ? "Which?" : undefined, expectedAnswers: expected },
    failedTries: options.failedTries ?? 0,
  }).decision;
}

export function decideInput(input: DecisionInput) {
  return decideRule(input).decision;
}

export const isAct = (decision: { kind: string }) => decision.kind === "act";

/** A fixed clock: 1,800,000,000 s after 1970, as in the Swift tests. */
export const startTime = 1_800_000_000_000;
export const days = (count: number) => count * 86_400_000;

let nextId = 0;
export const makeId = () => `entry-${++nextId}`;

export function entry(heardText: string, meant: string, hearer: HearerName, timesConfirmed = 1, lastConfirmedAt = startTime): PhrasebookEntry {
  return { id: makeId(), heard: heardText, meant, hearer, timesConfirmed, lastConfirmedAt, source: "confirmation" };
}
