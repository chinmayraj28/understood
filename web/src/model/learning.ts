// Small pure rules the conversation uses: how a yes or no is recognised, which option an answer
// picks, what the phrasebook learns from a confirmed turn, and which clips Gemini is shown.

import type { HearerName, PhoneAction, PhrasebookEntry, SpeechExample } from "../../shared/pipeline";
import { DEMO_CONTACTS } from "../../shared/pipeline";
import { addPair, learnFromTurn as sharedLearn, type Hypothesis } from "../../shared/rules";
import { HEARERS, type TurnModel } from "./turn";

/** Lower case, punctuation dropped, single spaces: "Call  Sam!" is "call sam". */
export function normalise(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}' ]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function words(text: string): string[] {
  const n = normalise(text);
  return n ? n.split(" ") : [];
}

const YES = new Set(["yes", "yeah", "yep", "yup", "yea", "ya", "sure", "correct", "right", "ok", "okay", "please"]);
const NO = new Set(["no", "nope", "nah", "don't", "dont", "cancel", "wrong", "not"]);

/** "yes", "no", or "other". A "no" may carry a correction: "no, Sam" gives rest "sam". */
export function classifyAnswer(text: string): { kind: "yes" | "no" | "other"; rest: string } {
  const w = words(text);
  if (w.length === 0) return { kind: "other", rest: "" };
  if (NO.has(w[0]) || (w.length <= 3 && w.some((x) => NO.has(x)))) {
    const rest = w.filter((x) => !NO.has(x) && !["it's", "its", "i", "meant", "said"].includes(x));
    return { kind: "no", rest: rest.join(" ") };
  }
  if (YES.has(w[0]) || (w.length <= 3 && w.some((x) => YES.has(x)))) return { kind: "yes", rest: "" };
  return { kind: "other", rest: w.join(" ") };
}

/**
 * Which option an answer picks. Only the words that tell the options apart count: for
 * "Message Mum" and "Message Sam", the answer "Sam" picks the second.
 */
export function matchOption(answer: string, options: string[]): string | null {
  const said = new Set(words(answer));
  const counts = new Map<string, number>();
  for (const option of options) for (const w of new Set(words(option))) counts.set(w, (counts.get(w) ?? 0) + 1);
  let best: string | null = null;
  let bestScore = 0;
  for (const option of options) {
    const distinctive = words(option).filter((w) => counts.get(w) === 1);
    const score = distinctive.filter((w) => said.has(w)).length;
    if (score > bestScore) {
      best = option;
      bestScore = score;
    } else if (score === bestScore && score > 0) {
      best = null; // two options tie: do not guess
    }
  }
  return bestScore > 0 ? best : null;
}

/** The short words that answer a "choose" question: for Mum or Sam, ["mum", "sam"]. */
export function optionLabels(options: string[]): string[] {
  const counts = new Map<string, number>();
  for (const option of options) for (const w of new Set(words(option))) counts.set(w, (counts.get(w) ?? 0) + 1);
  return options.map((o) => words(o).filter((w) => counts.get(w) === 1).join(" ") || o);
}

/**
 * What a confirmed turn teaches the phrasebook, using the same rule the server matches with
 * (web/shared/rules): every recogniser that heard something else gets a "heard -> meant" pair,
 * or its existing pair is bumped. When all of them heard it right, that is recorded too.
 * Returns the new list and the entries that were added or bumped, for the panel to highlight.
 */
export function learnFromTurn(
  turn: TurnModel,
  meant: string,
  source: "confirmation" | "correction",
  entries: PhrasebookEntry[],
  now = Date.now(),
): { entries: PhrasebookEntry[]; changed: PhrasebookEntry[] } {
  const hypotheses: Hypothesis[] = HEARERS.map((hearer) => {
    const lane = turn.lanes[hearer];
    return { hearer, text: lane.status === "done" ? (lane.text ?? "") : "", seconds: lane.seconds ?? 0, failure: lane.failure };
  });
  const outcome = source === "correction" ? { kind: "corrected" as const, meant } : { kind: "confirmed" as const, meant };
  const next = sharedLearn(entries, hypotheses, outcome, now, newEntryId);
  return { entries: next, changed: changedEntries(entries, next) };
}

/** A setup phrase: one pair for a recogniser's text, through the shared rule. */
export function learnEnrolmentPair(entries: PhrasebookEntry[], heard: string, meant: string, hearer: HearerName, now = Date.now()) {
  const next = addPair(entries, { heard, meant, hearer, source: "enrolment" }, now, newEntryId);
  return { entries: next, changed: changedEntries(entries, next) };
}

function changedEntries(before: PhrasebookEntry[], after: PhrasebookEntry[]): PhrasebookEntry[] {
  const old = new Map(before.map((e) => [e.id, e.timesConfirmed]));
  return after.filter((e) => old.get(e.id) !== e.timesConfirmed);
}

function newEntryId(): string {
  return `pb-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** A stored clip of the person's own voice, with what they meant. Kept only in this browser. */
export interface Clip {
  id: string;
  text: string;
  wavBase64: string;
  createdAt: number;
  source: "enrolment" | "confirmation";
  /** 0...1: the share of words the worst recogniser got wrong. Hard clips teach Gemini most. */
  difficulty: number;
}

/** Share of `meant` words missing from `heard`, 0...1. A rough word error, enough to rank clips. */
export function wordMiss(heard: string, meant: string): number {
  const target = words(meant);
  if (target.length === 0) return 0;
  const got = words(heard);
  const missing = target.filter((w) => !got.includes(w)).length;
  return Math.min(1, (missing + Math.max(0, got.length - target.length) * 0.5) / target.length);
}

/** Up to five clips for Gemini: the three most recent, then the hardest of the rest. */
export function chooseExamples(clips: Clip[], max = 5): SpeechExample[] {
  const recent = [...clips].sort((a, b) => b.createdAt - a.createdAt);
  const picked = recent.slice(0, Math.min(3, max));
  const hardest = recent.slice(picked.length).sort((a, b) => b.difficulty - a.difficulty);
  for (const clip of hardest) {
    if (picked.length >= max) break;
    picked.push(clip);
  }
  return picked.map((c) => ({ wavBase64: c.wavBase64, text: c.text }));
}

const ACTION_WORDS = ["message", "call", "timer", "minutes", "music", "remind", "reminder", "yes", "no", "done"];

/** Words likely in a turn: contacts, the things the pretend phone does, names from the phrasebook. */
export function keytermsFor(entries: PhrasebookEntry[]): string[] {
  const terms = new Set<string>([...DEMO_CONTACTS, ...ACTION_WORDS]);
  for (const entry of entries) {
    for (const w of entry.meant.split(/\s+/)) if (/^[A-Z][a-z]+$/.test(w)) terms.add(w);
  }
  return [...terms].slice(0, 100);
}

/** The yes/no question asked before anything that would reach another person. */
export function confirmQuestion(action: PhoneAction): string {
  switch (action.kind) {
    case "message":
      return `Send “${action.text}” to ${action.to}?`;
    case "call":
      return `Call ${action.to}?`;
    default:
      return "Shall I go ahead?";
  }
}
