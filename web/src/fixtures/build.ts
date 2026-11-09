// Builds the replayed example turns. Each example is written as a short script (who heard what,
// how long each step took) and turned into the exact PipelineEvents the server would stream, with
// timestamps in milliseconds from the end of speech. The texts are made up for the demo and
// labelled as examples on the page; none of it is real recorded speech.

import type {
  ActResponse,
  Decision,
  HearerName,
  PhrasebookEntry,
  PhrasebookMatch,
  PipelineEvent,
  Reading,
} from "../../shared/pipeline";
import { normalise, words } from "../model/learning";

export interface ReplayTurn {
  /** The live transcript writing itself: [ms after speech began, text so far]. */
  partials: [number, string][];
  /** How long the person spoke, pauses included. */
  speechSeconds: number;
  /** Events, `at` in ms after the end of speech. */
  events: PipelineEvent[];
}

export interface Replay {
  id: string;
  title: string;
  /** One sentence on what this example shows. */
  summary: string;
  /** The phrasebook the example starts with. */
  phrasebook: PhrasebookEntry[];
  turns: ReplayTurn[];
  /** What /api/act would answer, keyed by the normalised understood text. */
  acts: Record<string, ActResponse>;
}

interface HearSpec {
  hearer: HearerName;
  /** ms after the turn started. */
  start: number;
  seconds: number;
  text: string;
  failure?: string;
}

export interface TurnSpec {
  turnId: string;
  keyterms?: string[];
  exampleCount?: number;
  hear: HearSpec[];
  disputed?: string[];
  phrasebook?: PhrasebookMatch | null;
  repair?: { seconds: number; reading: Reading } | { skipped: string };
  decision: Decision;
  rule: string;
}

const FILLER = new Set(["a", "an", "the", "to", "for", "please", "um", "uh"]);

function contentWords(text: string): string[] {
  return words(text).filter((w) => !FILLER.has(w));
}

export function turnEvents(spec: TurnSpec): PipelineEvent[] {
  const events: PipelineEvent[] = [];
  const keyterms = spec.keyterms ?? ["Mum", "Sam", "Priya", "Dad", "Amma", "message", "call", "timer"];
  events.push({ type: "turn.started", turnId: spec.turnId, at: 0, keyterms, exampleCount: spec.exampleCount ?? 5 });

  let lastHeard = 0;
  for (const h of spec.hear) events.push({ type: "hear.started", hearer: h.hearer, at: h.start });
  const finished = [...spec.hear].sort((a, b) => a.start + a.seconds * 1000 - (b.start + b.seconds * 1000));
  // As on the server, every hearer starts before any finishes (the live transcript's vote is ready at once).
  const lastStart = Math.max(0, ...spec.hear.map((h) => h.start));
  for (const h of finished) {
    const at = Math.max(lastStart + 1, Math.round(h.start + h.seconds * 1000));
    lastHeard = Math.max(lastHeard, at);
    events.push({ type: "hear.done", hearer: h.hearer, at, text: h.text, seconds: h.seconds, failure: h.failure });
  }

  // Agreement: the largest group of hearers whose content words are identical.
  const heard = spec.hear.filter((h) => !h.failure && h.text);
  const contentByHearer: Partial<Record<HearerName, string[]>> = {};
  for (const h of heard) contentByHearer[h.hearer] = contentWords(h.text);
  const groups = new Map<string, HearerName[]>();
  for (const h of heard) {
    const key = (contentByHearer[h.hearer] ?? []).join(" ");
    groups.set(key, [...(groups.get(key) ?? []), h.hearer]);
  }
  const agreeing = [...groups.values()].sort((a, b) => b.length - a.length)[0] ?? [];
  let t = lastHeard + 18;
  events.push({
    type: "agreement",
    at: t,
    contentWords: contentByHearer,
    agreeing: agreeing.length > 1 ? agreeing : [],
    disputedWords: spec.disputed ?? [],
  });

  t += 14;
  events.push({ type: "phrasebook", at: t, match: spec.phrasebook ?? null });

  if (spec.repair && "reading" in spec.repair) {
    t += 9;
    events.push({ type: "repair.started", at: t });
    t += Math.round(spec.repair.seconds * 1000);
    events.push({ type: "repair.done", at: t, reading: spec.repair.reading, seconds: spec.repair.seconds });
  } else {
    t += 6;
    events.push({ type: "repair.skipped", at: t, why: spec.repair?.skipped ?? "Repair is switched off." });
  }

  t += 7;
  events.push({ type: "decision", at: t, decision: spec.decision, rule: spec.rule });
  t += 4;
  events.push({ type: "turn.done", at: t, seconds: t / 1000 });
  return events;
}

/** The live transcript growing word by word over `seconds`, with an optional long pause. */
export function partialsFor(text: string, seconds: number, pauseAfterWord = -1): [number, string][] {
  const ws = text.split(" ");
  const pause = pauseAfterWord >= 0 ? 1600 : 0;
  const step = (seconds * 1000 - pause) / Math.max(1, ws.length);
  const out: [number, string][] = [];
  let at = 250;
  for (let i = 0; i < ws.length; i++) {
    out.push([Math.round(at), ws.slice(0, i + 1).join(" ")]);
    at += step + (i === pauseAfterWord ? pause : 0);
  }
  return out;
}

export function replayTurn(spec: TurnSpec, liveText: string, speechSeconds: number, pauseAfterWord = -1): ReplayTurn {
  return { partials: partialsFor(liveText, speechSeconds, pauseAfterWord), speechSeconds, events: turnEvents(spec) };
}

export function entry(heard: string, meant: string, hearer: HearerName, times: number, source: PhrasebookEntry["source"] = "confirmation"): PhrasebookEntry {
  return {
    id: `ex-${normalise(heard).replace(/ /g, "-")}-${hearer}`,
    heard,
    meant,
    hearer,
    timesConfirmed: times,
    lastConfirmedAt: Date.UTC(2026, 10, 8, 18, 30),
    source,
  };
}

export function actKey(text: string): string {
  return normalise(text);
}
