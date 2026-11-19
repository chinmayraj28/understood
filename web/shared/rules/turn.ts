// Helpers around one turn: how the hearers' words compare (for the page's agreement view), and
// the one place failed tries are counted.

import type { Decision, HearerName } from "../pipeline";
import { contentWords, containsNegation, sameWords } from "./speechText";
import type { Hypothesis } from "./types";

export interface AgreementSummary {
  contentWords: Partial<Record<HearerName, string[]>>;
  agreeing: HearerName[];
  disputedWords: string[];
}

/**
 * How the hearers' words compare, for the page. `agreeing` is the largest group of hearers with
 * identical content words (ties go to the group with Scribe). `disputedWords` are content words
 * some hearers heard and others did not. This is for showing; the decider has its own, stricter
 * rules in evidence.ts.
 */
export function agreementSummary(hypotheses: readonly Hypothesis[]): AgreementSummary {
  const usable = hypotheses.filter((hypothesis) => contentWords(hypothesis.text).length > 0);
  const byHearer: Partial<Record<HearerName, string[]>> = {};
  for (const hypothesis of usable) byHearer[hypothesis.hearer] = contentWords(hypothesis.text);

  let agreeing: HearerName[] = [];
  for (const hypothesis of usable) {
    const group = usable.filter((other) => sameWords(byHearer[other.hearer]!, byHearer[hypothesis.hearer]!)).map((other) => other.hearer);
    const better = group.length > agreeing.length || (group.length === agreeing.length && group.includes("scribe") && !agreeing.includes("scribe"));
    if (better) agreeing = group;
  }

  const lists = Object.values(byHearer);
  const all = new Set(lists.flat());
  const disputedWords = [...all].filter((word) => !lists.every((list) => list.includes(word)));
  return { contentWords: byHearer, agreeing, disputedWords };
}

/**
 * The one place failed tries are counted. The page keeps the count and the last question it
 * asked, and calls this once per decided turn.
 * - A turn that ends in a question (confirm, choose, ask again) or "can't hear" counts as a failure.
 * - A turn that acts resets the count, unless it is a "no" to the question asked just before
 *   ("Message Mum?" answered "no"), which counts as one more failure.
 */
export function nextFailedTries(
  state: { failedTries: number; lastQuestion: string | null }, decision: Decision, pendingQuestion: string | undefined,
): { failedTries: number; lastQuestion: string | null } {
  switch (decision.kind) {
    case "act": {
      const answersOurQuestion = state.lastQuestion !== null && pendingQuestion === state.lastQuestion;
      return { failedTries: answersOurQuestion && containsNegation(decision.text) ? state.failedTries + 1 : 0, lastQuestion: null };
    }
    case "confirm":
    case "choose":
    case "askAgain":
      return { failedTries: state.failedTries + 1, lastQuestion: decision.question };
    case "cannotHear":
      return { failedTries: state.failedTries + 1, lastQuestion: null };
  }
}
