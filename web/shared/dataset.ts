// What the local dataset route sends the page: the TORGO clips on this machine, and what the
// evaluation heard for the ones it tested. The audio itself is fetched one clip at a time.
//
// TORGO is free for academic, non-profit use and must not be redistributed, so its audio is only
// ever read from the person's own disk by the local Node server. It is never bundled into the
// page, never committed, and the route does not exist on a hosted copy of the site.

export interface DatasetSpeaker {
  id: string;
  /** "dysarthric" or "control" (a speaker without dysarthria, recorded for comparison). */
  group: string;
  /** For example "cerebral palsy". Empty for control speakers. */
  condition: string;
  /** As reported in the TORGO literature: "mild", "moderate", "severe", or "none" for controls. */
  severity: string;
  clipCount: number;
}

export interface DatasetClip {
  id: string;
  speaker: string;
  /** "word" or "sentence". */
  kind: string;
  /** What the speaker was asked to say. */
  prompt: string;
  seconds: number;
  session: string;
  /** "enrolment" (used to set the speaker up) or "test" (used to measure). */
  split: string;
}

export interface DatasetHeard {
  /** "scribe", "gemini" or "apple" (the evaluation ran in Swift, with Apple's recogniser as the third vote). */
  hearer: string;
  text: string;
  seconds: number;
  failure?: string;
}

/** What one evaluation setup did with one clip. */
export interface DatasetResult {
  setup: string;
  /** "act", "confirm", "choose", "askAgain" or "cannotHear". */
  decision: string;
  finalText: string;
  heard: DatasetHeard[];
  reading?: { text: string; confidence: string; alternatives: string[]; reason: string };
  phrasebook?: { heard: string; meant: string; timesConfirmed: number };
  seconds: number;
  /** True when the same prompt was among the speaker's set-up clips. */
  promptSeen: boolean;
}

export interface DatasetIndex {
  available: true;
  name: string;
  speakers: DatasetSpeaker[];
  clips: DatasetClip[];
  /** By clip id: the "scribe" (alone) and "phrasebook" (full pipeline) results, when evaluated. */
  results: Record<string, DatasetResult[]>;
  /** When the evaluation ran, if its results were found. */
  resultsDate?: string;
}

export interface DatasetMissing {
  available: false;
  /** A plain sentence the page can show. */
  reason: string;
}

export type DatasetResponse = DatasetIndex | DatasetMissing;

/** The evaluation setups the page shows: Scribe on its own, and the full pipeline. */
export const SHOWN_SETUPS = ["scribe", "phrasebook"] as const;

/** The URL of one clip's audio. */
export const clipAudioUrl = (id: string) => `/api/dataset/audio/${encodeURIComponent(id)}`;
