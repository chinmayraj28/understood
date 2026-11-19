// The evidence rules the decider uses before it may act without asking. Each one closes a way a
// wrong reading could become an action: recognisers out-voting the main one (Scribe), a
// phrasebook pair from one recogniser being used for another's transcript, and a one-word negation.
// Ported from the Swift DeciderEvidence.swift. The Swift version also guarded against hints
// pushing recognisers into agreeing on a hinted name; the web recognisers get no hints, so that
// guard is gone here.

import type { HearerName, PhrasebookMatch } from "../pipeline";
import { contentWords, keyWordsAgree, names, negationWords, normalise, sameWords, similarity, words } from "./speechText";
import type { DecisionInput, Hypothesis } from "./types";

/** A phrasebook entry this close to what was heard (0...1)... */
export const strongMatchSimilarity = 0.9;
/**
 * ...and confirmed at least this often is trusted like an agreeing recogniser. Two, so one lucky
 * confirmation is not enough: the first time a garble is learned the person is asked once more,
 * and from the second time on it simply works.
 */
export const strongMatchConfirmations = 2;
/** Another recogniser's transcript this close to a phrasebook meaning supports it. */
export const supportSimilarity = 0.8;

/** True when a phrasebook match is close enough, and confirmed often enough, to be considered. */
export function isStrong(match: PhrasebookMatch | null | undefined): boolean {
  return !!match && match.similarity >= strongMatchSimilarity && match.timesConfirmed >= strongMatchConfirmations;
}

// MARK: Fixed answers

/**
 * The expected answer to act on, or null (then the turn is confirmed instead). All must hold:
 * - two or more recognisers heard it, Scribe among them;
 * - no recogniser heard a different expected answer;
 * - no recogniser heard a negation the answer does not itself contain ("not Mum", "yes, don't").
 */
export function trustedExpectedAnswer(heard: Hypothesis[], input: DecisionInput): string | null {
  const expected = input.context?.expectedAnswers ?? [];
  if (expected.length === 0) return null;
  const winners = expected.filter((answer) => {
    const matching = heard.filter((hypothesis) => matchesAnswer(hypothesis.text, answer, expected));
    return matching.length >= 2 && matching.some((hypothesis) => hypothesis.hearer === "scribe");
  });
  if (winners.length !== 1) return null;
  const answer = winners[0];
  const answerWords = new Set(words(answer));
  for (const hypothesis of heard) {
    if (expected.some((other) => other !== answer && matchesAnswer(hypothesis.text, other, expected))) return null;
    const negations = words(hypothesis.text).filter((word) => negationWords.has(word));
    if (negations.some((word) => !answerWords.has(word))) return null;
  }
  return answer;
}

/**
 * True when `text` is the answer itself, or just the part that tells it apart from the others:
 * "Sam" answers "message Mum or message Sam?". Filler words are ignored ("yes please").
 */
export function matchesAnswer(text: string, answer: string, answers: string[]): boolean {
  const heardWords = contentWords(text);
  if (heardWords.length === 0) return false;
  if (sameWords(heardWords, contentWords(answer))) return true;
  const index = answers.indexOf(answer);
  if (index < 0) return false;
  return sameWords(heardWords, contentWords(distinguishingParts(answers)[index]));
}

/**
 * Each option with the words all options share at the start and the end removed. When that would
 * leave an option empty ("call Sam" against "call Sam now"), the full options are kept.
 */
export function distinguishingParts(options: string[]): string[] {
  const split = options.map((option) => option.split(" ").filter((word) => word.length > 0));
  if (split.length < 2) return options;
  const shortest = Math.min(...split.map((list) => list.length));
  const same = (offset: number, fromEnd: boolean) =>
    new Set(split.map((list) => normalise(fromEnd ? list[list.length - 1 - offset] : list[offset]))).size === 1;
  let prefix = 0;
  while (prefix < shortest && same(prefix, false)) prefix += 1;
  let suffix = 0;
  while (suffix < shortest - prefix && same(suffix, true)) suffix += 1;
  const parts = split.map((list) => list.slice(prefix, list.length - suffix).join(" "));
  return parts.some((part) => part.length === 0) ? options : parts;
}

// MARK: Agreement

/**
 * The agreed text when at least two recognisers, Scribe among them, heard the same content words
 * and none heard different ones. Returns Scribe's wording.
 */
export function agreedText(heard: Hypothesis[]): string | null {
  const usable = heard.filter((hypothesis) => words(hypothesis.text).length > 0);
  const scribe = usable.find((hypothesis) => hypothesis.hearer === "scribe");
  if (usable.length < 2 || !scribe) return null;
  const scribeWords = contentWords(scribe.text);
  if (scribeWords.length === 0 || !usable.every((hypothesis) => sameWords(contentWords(hypothesis.text), scribeWords))) return null;
  return scribe.text;
}

// MARK: Phrasebook

/**
 * The phrasebook match the decider may act on, or null. All must hold:
 * - a recogniser's transcript matches a pair that same recogniser stored, strongly (`isStrong`);
 * - that transcript and the stored text have the same negations, digits and names;
 * - every other recogniser that heard something supports the meaning: it heard the same garble,
 *   or its own stored pair means the same, or it is close to the meaning itself.
 * Scribe's match is tried first.
 */
export function trustedPhrasebookMatch(
  heard: Hypothesis[], byHearer: Partial<Record<HearerName, PhrasebookMatch>>,
): PhrasebookMatch | null {
  const ordered = [...heard].sort((a, b) => (a.hearer === "scribe" ? 0 : 1) - (b.hearer === "scribe" ? 0 : 1));
  for (const candidate of ordered) {
    const match = byHearer[candidate.hearer];
    if (!match || !isStrong(match)) continue;
    const nameSet = new Set([...names(candidate.text), ...names(match.heard), ...names(match.meant)]);
    if (!keyWordsAgree(candidate.text, match.heard, nameSet)) continue;
    const others = heard.filter((hypothesis) => hypothesis.hearer !== candidate.hearer);
    if (others.every((other) => supports(other, match, byHearer, nameSet))) return match;
  }
  return null;
}

function supports(
  hypothesis: Hypothesis, match: PhrasebookMatch, byHearer: Partial<Record<HearerName, PhrasebookMatch>>, nameSet: Set<string>,
): boolean {
  const text = hypothesis.text;
  const allNames = new Set([...nameSet, ...names(text)]);
  // The same garble the trusted recogniser heard.
  if (similarity(text, match.heard) >= strongMatchSimilarity && keyWordsAgree(text, match.heard, allNames)) return true;
  // Its own stored pair, for the same meaning.
  const own = byHearer[hypothesis.hearer];
  if (own && normalise(own.meant) === normalise(match.meant) && own.similarity >= strongMatchSimilarity
    && keyWordsAgree(text, own.heard, allNames)) return true;
  // Close to the meaning itself.
  return similarity(text, match.meant) >= supportSimilarity && keyWordsAgree(text, match.meant, allNames);
}
