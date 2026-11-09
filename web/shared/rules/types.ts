// Types the rules use that are not part of the page/server contract in ../pipeline.ts.

import type { HearerName, PhrasebookMatch, Reading, TurnContext } from "../pipeline";

/** What one recogniser heard. A failed or slow recogniser has empty text and `failure` set. */
export interface Hypothesis {
  hearer: HearerName;
  text: string;
  seconds: number;
  failure?: string;
}

/** Everything the decider looks at for one turn. */
export interface DecisionInput {
  /** What each recogniser heard, including failed ones. */
  hypotheses: Hypothesis[];
  /**
   * Each recogniser's closest pair among the pairs it stored itself (`matchesByHearer`).
   * Only these can let the decider act.
   */
  matchesByHearer?: Partial<Record<HearerName, PhrasebookMatch>>;
  /**
   * The keyterms the recognisers were given. Agreement on a hinted name needs the realtime
   * (least-hinted) transcript as well.
   */
  hintedTerms?: string[];
  /**
   * The keyterms the page gave the realtime recogniser. When they share a word with the hinted
   * words, the realtime transcript no longer counts as hint-free.
   */
  realtimeKeyterms?: string[];
  /** The repair stage's reading. Missing when repair was skipped (fast path) or failed. */
  reading?: Reading;
  context?: TurnContext;
  /** How many turns in a row ended without the person being understood. */
  failedTries?: number;
}

/** How a turn ended, for learning. Only a spoken yes, a chosen option or a correction teaches. */
export type TurnOutcome =
  | { kind: "confirmed"; meant: string }
  | { kind: "corrected"; meant: string }
  | { kind: "rejected" };

const confidenceRank = { low: 0, medium: 1, high: 2 } as const;

/** True when `confidence` is at least `minimum`. */
export function atLeast(confidence: Reading["confidence"], minimum: Reading["confidence"]): boolean {
  return confidenceRank[confidence] >= confidenceRank[minimum];
}
