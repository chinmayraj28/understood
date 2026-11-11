// Filtering and wording for the recordings view.
import { describe, expect, it } from "vitest";
import type { DatasetClip, DatasetResult, DatasetSpeaker } from "../../shared/dataset";
import { decisionWords, filterClips, matchesPrompt, NO_FILTER, orderSpeakers, secondsLabel, speakerDescription } from "../../src/model/dataset";

const clip = (id: string, speaker: string, prompt: string, kind = "word", split = "test"): DatasetClip => ({ id, speaker, prompt, kind, split, seconds: 1, session: "Session1" });
const clips = [
  clip("F01-1", "F01", "stick"),
  clip("F01-2", "F01", "Except in the winter, when the ooze or snow prevents", "sentence", "enrolment"),
  clip("M04-1", "M04", "knew"),
  clip("FC01-1", "FC01", "stick", "word", "enrolment"),
];
const result = (finalText: string): DatasetResult => ({ setup: "phrasebook", decision: "act", finalText, heard: [], seconds: 1, promptSeen: false });
const index = { clips, results: { "M04-1": [result("knew")] } as Record<string, DatasetResult[]> };

describe("filterClips", () => {
  it("returns everything with no filter", () => {
    expect(filterClips(index, NO_FILTER)).toHaveLength(4);
  });

  it("filters by speaker, kind, split and evaluated", () => {
    expect(filterClips(index, { ...NO_FILTER, speaker: "F01" }).map((c) => c.id)).toEqual(["F01-1", "F01-2"]);
    expect(filterClips(index, { ...NO_FILTER, kind: "sentence" }).map((c) => c.id)).toEqual(["F01-2"]);
    expect(filterClips(index, { ...NO_FILTER, split: "enrolment" }).map((c) => c.id)).toEqual(["F01-2", "FC01-1"]);
    expect(filterClips(index, { ...NO_FILTER, evaluatedOnly: true }).map((c) => c.id)).toEqual(["M04-1"]);
  });

  it("searches the prompt ignoring case and punctuation, and the id", () => {
    expect(filterClips(index, { ...NO_FILTER, query: "STICK" }).map((c) => c.id)).toEqual(["F01-1", "FC01-1"]);
    expect(filterClips(index, { ...NO_FILTER, query: "winter when" }).map((c) => c.id)).toEqual(["F01-2"]);
    expect(filterClips(index, { ...NO_FILTER, query: "m04" }).map((c) => c.id)).toEqual(["M04-1"]);
    expect(filterClips(index, { ...NO_FILTER, query: "   " })).toHaveLength(4);
  });

  it("combines filters", () => {
    expect(filterClips(index, { ...NO_FILTER, speaker: "FC01", query: "stick" }).map((c) => c.id)).toEqual(["FC01-1"]);
    expect(filterClips(index, { ...NO_FILTER, speaker: "FC01", evaluatedOnly: true })).toEqual([]);
  });
});

describe("speakers", () => {
  const s = (id: string, group: string, severity: string): DatasetSpeaker => ({ id, group, severity, condition: group === "dysarthric" ? "cerebral palsy" : "", clipCount: 1 });

  it("orders severe first, then moderate, then mild, then comparison speakers", () => {
    const ordered = orderSpeakers([s("FC01", "control", "none"), s("F04", "dysarthric", "mild"), s("M05", "dysarthric", "moderate to severe"), s("F03", "dysarthric", "moderate"), s("M01", "dysarthric", "severe"), s("F01", "dysarthric", "severe")]);
    expect(ordered.map((x) => x.id)).toEqual(["F01", "M01", "M05", "F03", "F04", "FC01"]);
  });

  it("describes a speaker in plain words", () => {
    expect(speakerDescription(s("F01", "dysarthric", "severe"))).toBe("cerebral palsy, severe");
    expect(speakerDescription(s("FC01", "control", "none"))).toBe("no dysarthria (comparison speaker)");
    expect(speakerDescription(undefined)).toBe("");
  });
});

describe("wording", () => {
  it("names every decision the evaluation can record", () => {
    expect(["act", "confirm", "choose", "askAgain", "cannotHear"].map(decisionWords)).toEqual([
      "Acted", "Asked a yes/no question", "Offered a choice", "Asked to say it again", "Said it couldn't hear",
    ]);
  });

  it("compares the final text with the prompt, ignoring case and punctuation", () => {
    expect(matchesPrompt(result("Knew."), "knew")).toBe(true);
    expect(matchesPrompt(result("new"), "knew")).toBe(false);
    expect(matchesPrompt(result(""), "knew")).toBe(false);
  });

  it("writes durations briefly", () => {
    expect(secondsLabel(1.83)).toBe("1.8 s");
    expect(secondsLabel(12.4)).toBe("12 s");
  });
});
