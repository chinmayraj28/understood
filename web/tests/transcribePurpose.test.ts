// A recording sent with purpose "transcribe": the demo phone's contacts are not hints, the
// recognisers and Claude get longer, and the field is checked like every other.
import { describe, expect, it } from "vitest";
import { DEMO_CONTACTS, type PipelineEvent, type UnderstandRequest } from "../shared/pipeline";
import type { HearingRequest } from "../server/hearers";
import { hintsFor, TRANSCRIBE_LIMITS, understandTurn, type UnderstandDeps } from "../server/understand";
import { checkUnderstand } from "../server/validate";

function request(change: Partial<UnderstandRequest> = {}): UnderstandRequest {
  return {
    turnId: "t1", wavBase64: "AAAA", phrasebook: [], examples: [], keyterms: ["stubble"], context: {},
    switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true }, ...change,
  };
}

describe("purpose: transcribe", () => {
  it("gives the recognisers no hints for a recording (they hurt on TORGO), but keeps them for speech", () => {
    expect(hintsFor(request(), 0)).toEqual(expect.arrayContaining([...DEMO_CONTACTS, "stubble"]));
    expect(hintsFor(request({ purpose: "transcribe" }), 0)).toEqual([]);
  });

  it("gives the recognisers and Claude the longer limits", async () => {
    const seen: HearingRequest[] = [];
    let repairSeconds = 0;
    const deps: UnderstandDeps = {
      hearScribe: async (r) => (seen.push(r), "uh"),
      hearGemini: async (r) => (seen.push(r), "up"),
      repair: async (_, __, seconds) => {
        repairSeconds = seconds;
        return { text: "up", confidence: "medium", alternatives: [], reason: "" };
      },
      now: Date.now, hearerSeconds: 4, repairSeconds: 3,
    };
    const events: PipelineEvent[] = [];
    await understandTurn(request({ purpose: "transcribe" }), deps, (e) => events.push(e));
    // Scribe, Gemini 3.1 Pro and Gemini 4 Carbon, each with the longer limit and the transcription prompt.
    expect(seen.map((r) => r.seconds)).toEqual([15, 15, 15].map(() => TRANSCRIBE_LIMITS.hearerSeconds));
    expect(seen.map((r) => r.model ?? "default")).toEqual(["default", "google/gemini-3.1-pro-preview", "google/gemini-4-carbon"]);
    expect(seen.every((r) => r.purpose === "transcribe")).toBe(true);
    expect(events.filter((e) => e.type === "hear.done").map((e) => (e as { hearer: string }).hearer).sort()).toEqual(["gemini", "gemini4", "realtime", "scribe"]);
    expect(repairSeconds).toBe(TRANSCRIBE_LIMITS.repairSeconds);

    seen.length = 0;
    await understandTurn(request(), deps, () => {});
    // A spoken turn is unchanged: Scribe and Gemini Flash, 4 seconds each.
    expect(seen.map((r) => r.seconds)).toEqual([4, 4]);
    expect(seen.every((r) => r.model === undefined && r.purpose === undefined)).toBe(true);
    expect(repairSeconds).toBe(3);
  });

  it("does not show Claude the demo contacts as known words", async () => {
    let known: string[] = [];
    const deps: UnderstandDeps = {
      hearScribe: async () => "uh", hearGemini: async () => "up",
      repair: async (input) => {
        known = input.knownWords;
        return { text: "up", confidence: "medium", alternatives: [], reason: "" };
      },
      now: Date.now, hearerSeconds: 4, repairSeconds: 3,
    };
    await understandTurn(request({ purpose: "transcribe" }), deps, () => {});
    expect(known).toEqual(["stubble"]);
  });

  it("accepts only conversation or transcribe", () => {
    const body = { ...request(), wavBase64: "AAAA" };
    expect(checkUnderstand({ ...body, purpose: "transcribe" })).toMatchObject({ ok: true, value: { purpose: "transcribe" } });
    expect(checkUnderstand(body)).toMatchObject({ ok: true });
    expect(checkUnderstand({ ...body, purpose: "act now" })).toMatchObject({ ok: false });
  });
});
