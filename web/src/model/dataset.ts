// Filtering and wording for the dataset view. Pure functions, so they are tested on their own.

import type { DatasetClip, DatasetIndex, DatasetResult, DatasetSpeaker } from "../../shared/dataset";

export interface DatasetFilter {
  /** A speaker id, or "all". */
  speaker: string;
  kind: "all" | "word" | "sentence";
  split: "all" | "enrolment" | "test";
  /** Only clips the evaluation tested (so the page can show what the pipeline heard). */
  evaluatedOnly: boolean;
  /** Matched against the prompt and the clip id, ignoring case and punctuation. */
  query: string;
}

export const NO_FILTER: DatasetFilter = { speaker: "all", kind: "all", split: "all", evaluatedOnly: false, query: "" };

/** How many clips are shown at first, and added by "Show more". */
export const PAGE_SIZE = 40;

const plain = (text: string) =>
  text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, " ")
    .trim();

export function filterClips(index: Pick<DatasetIndex, "clips" | "results">, filter: DatasetFilter): DatasetClip[] {
  const query = plain(filter.query);
  return index.clips.filter(
    (clip) =>
      (filter.speaker === "all" || clip.speaker === filter.speaker) &&
      (filter.kind === "all" || clip.kind === filter.kind) &&
      (filter.split === "all" || clip.split === filter.split) &&
      (!filter.evaluatedOnly || Boolean(index.results[clip.id]?.length)) &&
      (query === "" || plain(clip.prompt).includes(query) || clip.id.toLowerCase().includes(query)),
  );
}

/** Speakers with dysarthria first, most severe first; then the control speakers. */
export function orderSpeakers(speakers: DatasetSpeaker[]): DatasetSpeaker[] {
  const rank = (s: DatasetSpeaker) => {
    if (s.group !== "dysarthric") return 9;
    const v = s.severity.toLowerCase();
    if (v.includes("severe") && !v.includes("moderate")) return 0;
    if (v.includes("severe")) return 1;
    if (v.includes("moderate")) return 2;
    if (v.includes("mild")) return 3;
    return 4;
  };
  return [...speakers].sort((a, b) => rank(a) - rank(b) || a.id.localeCompare(b.id));
}

/** "cerebral palsy, severe", or "no dysarthria (comparison speaker)". */
export function speakerDescription(s: DatasetSpeaker | undefined): string {
  if (!s) return "";
  if (s.group !== "dysarthric") return "no dysarthria (comparison speaker)";
  return [s.condition, s.severity].filter(Boolean).join(", ");
}

/** The decision, in the words the pipeline page uses. */
export function decisionWords(decision: string): string {
  switch (decision) {
    case "act":
      return "Acted";
    case "confirm":
      return "Asked a yes/no question";
    case "choose":
      return "Offered a choice";
    case "askAgain":
      return "Asked to say it again";
    case "cannotHear":
      return "Said it couldn't hear";
    default:
      return decision;
  }
}

export function hearerName(hearer: string): string {
  return { scribe: "Scribe", gemini: "Gemini", apple: "Apple on-device", realtime: "Live transcript" }[hearer] ?? hearer;
}

export function setupName(setup: string): string {
  return setup === "phrasebook" ? "Full pipeline" : setup === "scribe" ? "Scribe alone" : setup;
}

/**
 * Whether a result's final text says what the speaker was asked to say, ignoring case and
 * punctuation. Only meaningful when the pipeline acted or asked about a reading.
 */
export function matchesPrompt(result: DatasetResult, prompt: string): boolean {
  return result.finalText !== "" && plain(result.finalText) === plain(prompt);
}

/** "1.8 s" or "12 s". */
export function secondsLabel(seconds: number): string {
  return seconds < 10 ? `${seconds.toFixed(1)} s` : `${Math.round(seconds)} s`;
}
