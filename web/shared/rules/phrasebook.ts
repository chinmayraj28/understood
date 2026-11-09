// The person's phrasebook: pairs of "a recogniser heard X, the person meant Y". On the web it
// lives only in the browser (speech of a disabled person is health data) and is sent with each
// turn, so everything here is a pure function over a list of entries. Ported from the Swift
// Phrasebook.swift and PhrasebookMatching.swift; the SQLite store became an array.

import type { HearerName, PhrasebookEntry, PhrasebookMatch } from "../pipeline";
import { fillerWords, normalise, similarityOfWords, words } from "./speechText";
import type { Hypothesis, TurnOutcome } from "./types";

/** Pairs not confirmed for this long count half as much: speech changes in progressive conditions. */
export const halfLifeDays = 30;
/** Matches below this similarity are not reported: they would only distract the repair stage. */
export const minimumMatchSimilarity = 0.6;

const dayMs = 86_400_000;

/** 1 for now, 0.5 after one half-life, 0.25 after two. */
export function recencyWeight(at: number, now: number): number {
  const days = Math.max(0, (now - at) / dayMs);
  return 0.5 ** (days / halfLifeDays);
}

/**
 * The stored pair closest to any of the transcripts, or null. A hint for the repair stage only.
 *
 * Method: similarity between each transcript and each stored "heard" text. The best pair wins by
 * similarity × a recency factor (0.6 + 0.4 × the half-life weight), so a recent pair beats an
 * equally close old one. `timesConfirmed` in the result is the recency-weighted count, rounded
 * down (at least 1): three confirmations a month ago count as one, so a pair nobody has used for
 * a while is checked with the person once more before the decider trusts it on its own.
 */
export function bestMatch(
  entries: readonly PhrasebookEntry[], transcripts: readonly string[], now: number, cache: SimilarityCache = new Map(),
): PhrasebookMatch | null {
  const heard = transcripts.map(words).filter((list) => list.length > 0);
  if (heard.length === 0) return null;
  return best(entries, heard, now, cache);
}

/**
 * Similarities already worked out in this turn, by heard and stored words. Pass the same cache to
 * `matchesByHearer` and `bestMatch` so each pair is compared once.
 */
export type SimilarityCache = Map<string, number>;

/**
 * For each recogniser that heard something, its closest pair among the pairs that same
 * recogniser stored. Recognisers make different mistakes: the realtime recogniser's
 * "mess a mum" for "message Mum" says nothing about what Scribe's "message Sam" meant. This is
 * what the decider trusts.
 */
export function matchesByHearer(
  entries: readonly PhrasebookEntry[], hypotheses: readonly Hypothesis[], now: number, cache: SimilarityCache = new Map(),
): Partial<Record<HearerName, PhrasebookMatch>> {
  const matches: Partial<Record<HearerName, PhrasebookMatch>> = {};
  for (const hypothesis of hypotheses) {
    const heard = words(hypothesis.text);
    if (heard.length === 0) continue;
    const match = best(entries.filter((entry) => entry.hearer === hypothesis.hearer), [heard], now, cache);
    if (match) matches[hypothesis.hearer] = match;
  }
  return matches;
}

/**
 * False when two word counts are too far apart for the pair ever to reach the match threshold,
 * so the costly comparison can be skipped without changing any result. Why it is safe: every
 * word one side has more than the other costs at least 1 in the edit distance, so similarity is
 * at most shorter ÷ longer. When the shorter has fewer than 60% of the longer's words (they
 * differ by more than 40%), similarity is below 0.6, and such a match is never reported.
 * Counted in whole numbers (5 × shorter < 3 × longer) so rounding can never decide it.
 */
export function mayReachThreshold(first: number, second: number): boolean {
  const shorter = Math.min(first, second), longer = Math.max(first, second);
  return longer > 0 && 5 * shorter >= 3 * longer;
}

function best(entries: readonly PhrasebookEntry[], heard: string[][], now: number, cache: SimilarityCache): PhrasebookMatch | null {
  let winner: { score: number; match: PhrasebookMatch } | null = null;
  for (const entry of entries) {
    const stored = words(entry.heard);
    const comparable = heard.filter((list) => mayReachThreshold(list.length, stored.length));
    if (comparable.length === 0) continue;
    const similarity = Math.max(0, ...comparable.map((list) => {
      const key = `${list.join(" ")}\u0000${stored.join(" ")}`;
      let value = cache.get(key);
      if (value === undefined) cache.set(key, (value = similarityOfWords(list, stored)));
      return value;
    }));
    if (similarity < minimumMatchSimilarity) continue;
    const weight = recencyWeight(entry.lastConfirmedAt, now);
    const match: PhrasebookMatch = {
      entryId: entry.id, meant: entry.meant, heard: entry.heard, similarity,
      // + 0.01: a pair confirmed a moment ago keeps its full count.
      timesConfirmed: Math.max(1, Math.floor(entry.timesConfirmed * weight + 0.01)),
      strong: false,
    };
    const score = similarity * (0.6 + 0.4 * weight);
    if (winner && (winner.score > score || (winner.score === score && winner.match.timesConfirmed >= match.timesConfirmed))) continue;
    winner = { score, match };
  }
  return winner?.match ?? null;
}

/**
 * Words and phrases this person says, most used first, for recognisers that accept hints. Each
 * meant phrase is followed by its own content words ("message Mum", "message", "Mum"), so a
 * recogniser that only takes single words still gets the names. Use is the recency-weighted
 * number of confirmations.
 */
export function phrasebookKeyterms(entries: readonly PhrasebookEntry[], limit: number, now: number): string[] {
  if (limit <= 0) return [];
  const usage = new Map<string, number>();
  const wording = new Map<string, string>();
  const newestFirst = [...entries].sort((a, b) => b.lastConfirmedAt - a.lastConfirmedAt);
  for (const entry of newestFirst) {
    const key = normalise(entry.meant);
    if (!key) continue;
    usage.set(key, (usage.get(key) ?? 0) + entry.timesConfirmed * recencyWeight(entry.lastConfirmedAt, now));
    if (!wording.has(key)) wording.set(key, entry.meant); // newest wording
  }
  const terms: string[] = [];
  const seen = new Set<string>();
  const append = (term: string) => {
    if (terms.length >= limit || seen.has(term.toLowerCase())) return;
    seen.add(term.toLowerCase());
    terms.push(term);
  };
  const keys = [...usage.keys()].sort((a, b) => usage.get(b)! - usage.get(a)! || (a < b ? -1 : a > b ? 1 : 0));
  for (const key of keys) {
    const phrase = wording.get(key)!;
    append(phrase);
    for (const raw of phrase.split(" ")) {
      const word = raw.replace(/^\p{P}+|\p{P}+$/gu, "");
      if ([...word].length > 1 && !fillerWords.has(word.toLowerCase())) append(word);
    }
  }
  return terms;
}

/**
 * Adds a pair, or, when the same recogniser has heard the same thing for the same meaning
 * before, counts one more confirmation. Returns a new list; the old one is not changed.
 * `makeId` gives the id for a new entry (the browser passes crypto.randomUUID).
 */
export function addPair(
  entries: readonly PhrasebookEntry[],
  pair: { heard: string; meant: string; hearer: HearerName; source: PhrasebookEntry["source"] },
  now: number, makeId: () => string,
): PhrasebookEntry[] {
  const heardKey = normalise(pair.heard), meantKey = normalise(pair.meant);
  if (!heardKey || !meantKey) return [...entries];
  const index = entries.findIndex((entry) =>
    entry.hearer === pair.hearer && normalise(entry.heard) === heardKey && normalise(entry.meant) === meantKey);
  if (index >= 0) {
    const updated = { ...entries[index], meant: pair.meant, timesConfirmed: entries[index].timesConfirmed + 1, lastConfirmedAt: now };
    return entries.map((entry, position) => (position === index ? updated : entry));
  }
  return [...entries, {
    id: makeId(), meant: pair.meant, heard: pair.heard, hearer: pair.hearer,
    timesConfirmed: 1, lastConfirmedAt: now, source: pair.source,
  }];
}

/**
 * Learns from how a turn ended. Only a spoken yes, a chosen option or a correction teaches: an
 * action that simply went ahead is never passed in as "confirmed", because learning from an
 * uncorrected mistake would make it a habit. A rejection teaches nothing (the "no" was already
 * counted as a failed try by `nextFailedTries`).
 *
 * One pair for each recogniser that got it wrong, so the same garble is caught next time. When
 * every recogniser was right, one pair "meant → meant" keeps the phrase as a confirmed example.
 */
export function learnFromTurn(
  entries: readonly PhrasebookEntry[], hypotheses: readonly Hypothesis[], outcome: TurnOutcome,
  now: number, makeId: () => string,
): PhrasebookEntry[] {
  if (outcome.kind === "rejected" || words(outcome.meant).length === 0) return [...entries];
  const source = outcome.kind === "corrected" ? "correction" : "confirmation";
  const meantKey = normalise(outcome.meant);
  const heard = hypotheses.filter((hypothesis) => words(hypothesis.text).length > 0);
  const wrong = heard.filter((hypothesis) => normalise(hypothesis.text) !== meantKey);
  if (wrong.length === 0) {
    const hearer = heard.find((hypothesis) => hypothesis.hearer === "scribe")?.hearer ?? heard[0]?.hearer ?? "scribe";
    return addPair(entries, { heard: outcome.meant, meant: outcome.meant, hearer, source }, now, makeId);
  }
  let result = [...entries];
  for (const hypothesis of wrong) {
    result = addPair(result, { heard: hypothesis.text, meant: outcome.meant, hearer: hypothesis.hearer, source }, now, makeId);
  }
  return result;
}
