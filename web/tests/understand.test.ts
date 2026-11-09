// Ported from UnderstanderTests.swift (and finding 5 of ReviewFindingsTests.swift): the whole turn
// with fake hearers and a fake Claude, checking the events and the decision.
import { describe, expect, it } from "vitest";
import type { PipelineEvent, Reading, UnderstandRequest } from "../shared/pipeline";
import { learnFromTurn } from "../shared/rules/phrasebook";
import type { Hypothesis } from "../shared/rules/types";
import type { HearingRequest } from "../server/hearers";
import { understandTurn, type UnderstandDeps } from "../server/understand";
import { makeId } from "./helpers";

type Hear = (request: HearingRequest) => Promise<string>;
const says = (text: string, delayMs = 0): Hear => (request) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => resolve(text), delayMs);
  request.signal.addEventListener("abort", () => { clearTimeout(timer); reject(request.signal.reason); });
});
const fails = (message: string): Hear => async () => { throw new Error(message); };

function fakeClaude(reading: Reading | null, delayMs = 0) {
  const calls: string[] = [];
  const repair: UnderstandDeps["repair"] = (input, signal) => new Promise((resolve, reject) => {
    calls.push(JSON.stringify(input));
    const timer = setTimeout(() => (reading ? resolve(reading) : reject(new Error("down"))), delayMs);
    signal.addEventListener("abort", () => { clearTimeout(timer); reject(signal.reason); });
  });
  return { repair, calls };
}

function request(change: Partial<UnderstandRequest> = {}): UnderstandRequest {
  return {
    turnId: "t1", wavBase64: "AAAA", realtimeText: "", phrasebook: [], examples: [], keyterms: [], context: {},
    switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true }, ...change,
  };
}

async function run(req: UnderstandRequest, scribe: Hear, gemini: Hear, claude = fakeClaude(null), seen: HearingRequest[] = []) {
  const events: PipelineEvent[] = [];
  const record = (hear: Hear): Hear => (r) => { seen.push(r); return hear(r); };
  const deps: UnderstandDeps = {
    hearScribe: record(scribe), hearGemini: record(gemini), repair: claude.repair, now: Date.now, hearerSeconds: 0.3, repairSeconds: 0.3,
  };
  const start = Date.now();
  await understandTurn(req, deps, (event) => events.push(event));
  const decision = events.find((event) => event.type === "decision");
  const hypotheses: Hypothesis[] = events.flatMap((event) => (event.type === "hear.done"
    ? [{ hearer: event.hearer, text: event.text, seconds: event.seconds, ...(event.failure ? { failure: event.failure } : {}) }] : []));
  return { events, types: events.map((event) => event.type), decision: decision?.type === "decision" ? decision.decision : null, hypotheses, ms: Date.now() - start };
}

const high = (text: string): Reading => ({ text, confidence: "high", alternatives: [], reason: "" });

describe("understandTurn", () => {
  it("takes the fast path on agreement, without asking Claude, with events in order", async () => {
    const claude = fakeClaude(high("volume up"));
    const result = await run(request({ realtimeText: "volume up" }), says("Volume up"), says("volume up."), claude);
    expect(result.decision).toEqual({ kind: "act", text: "Volume up" });
    expect(claude.calls).toHaveLength(0);
    expect(result.types).toEqual([
      "turn.started", "hear.started", "hear.started", "hear.started", "hear.done", "hear.done", "hear.done",
      "agreement", "phrasebook", "repair.skipped", "decision", "turn.done",
    ]);
    const agreement = result.events.find((event) => event.type === "agreement");
    expect(agreement).toMatchObject({ agreeing: ["scribe", "gemini", "realtime"], disputedWords: [] });
  });

  it("repairs disagreement, then decides in code", async () => {
    const claude = fakeClaude({ text: "message Mum", confidence: "medium", alternatives: [], reason: "" });
    const result = await run(request(), says("message mom"), says("massage Mum"), claude);
    expect(result.decision).toEqual({ kind: "confirm", question: "Message Mum?", reading: "message Mum" });
    expect(claude.calls).toHaveLength(1);
    expect(result.types).toContain("repair.started");
    expect(result.types).toContain("repair.done");
  });

  it("leaves a slow recogniser behind", async () => {
    const result = await run(request({ realtimeText: "scroll down" }), says("scroll down"), says("scroll down", 3000));
    expect(result.ms).toBeLessThan(2000);
    const gemini = result.hypotheses.find((hypothesis) => hypothesis.hearer === "gemini")!;
    expect(gemini.text).toBe("");
    expect(gemini.failure).toContain("timed out");
    expect(result.decision).toEqual({ kind: "act", text: "scroll down" }); // the other two agree
  });

  it("turns a failing recogniser into a failed hypothesis", async () => {
    const result = await run(request({ realtimeText: "open mail", switches: { keyterms: true, gemini: false, examples: true, phrasebook: true, repair: false } }),
      fails("boom"), says("unused"));
    expect(result.hypotheses.find((hypothesis) => hypothesis.hearer === "scribe")?.failure).toBeTruthy();
    expect(result.decision).toEqual({ kind: "confirm", question: "Open mail?", reading: "open mail" });
    expect(result.events.some((event) => event.type === "hear.started" && event.hearer === "gemini")).toBe(false);
  });

  it("cannot hear when everything is down, without asking Claude", async () => {
    const claude = fakeClaude(high("x"));
    const result = await run(request(), fails("down"), says("late", 2000), claude);
    expect(result.decision).toEqual({ kind: "cannotHear", message: "I can't hear properly right now." });
    expect(claude.calls).toHaveLength(0);
    expect(result.events.find((event) => event.type === "repair.skipped")).toMatchObject({ why: "Nothing was heard, so there was nothing to repair." });
  });

  it("falls back to the Scribe text when repair fails or is slow", async () => {
    for (const claude of [fakeClaude(null), fakeClaude(high("call Sam"), 3000)]) {
      const result = await run(request(), says("call some"), says("cool sum"), claude);
      expect(result.ms).toBeLessThan(2000);
      expect(claude.calls).toHaveLength(1);
      expect(result.decision).toEqual({ kind: "confirm", question: "Call some?", reading: "call some" });
      expect(result.types.slice(-4)).toEqual(["repair.started", "repair.skipped", "decision", "turn.done"]);
    }
  });

  it("never delays stop for repair", async () => {
    const claude = fakeClaude(null, 5000);
    const result = await run(request({ context: { pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"] } }), says("stop"), says("top hmm"), claude);
    expect(result.decision).toEqual({ kind: "act", text: "stop" });
    expect(claude.calls).toHaveLength(0);
    expect(result.ms).toBeLessThan(1000);
  });

  it("catches a confirmed garble the next time, and acts without Claude the third time", async () => {
    const claude = fakeClaude(high("call Sam"));
    let book = request().phrasebook;
    const turn = async () => run(request({ phrasebook: book, realtimeText: "call some" }), says("call some"), says("cool sum"), claude);

    const first = await turn();
    expect(first.events.find((event) => event.type === "phrasebook")).toMatchObject({ match: null });
    expect(first.decision).toEqual({ kind: "confirm", question: "Call Sam?", reading: "call Sam" });
    book = learnFromTurn(book, first.hypotheses, { kind: "confirmed", meant: "call Sam" }, Date.now(), makeId);

    const second = await turn();
    expect(second.events.find((event) => event.type === "phrasebook")).toMatchObject({ match: { meant: "call Sam", timesConfirmed: 1, strong: false } });
    expect(second.decision).toEqual({ kind: "confirm", question: "Call Sam?", reading: "call Sam" }); // learned once: asked once more
    book = learnFromTurn(book, second.hypotheses, { kind: "confirmed", meant: "call Sam" }, Date.now(), makeId);

    const callsBefore = claude.calls.length;
    const third = await turn();
    expect(third.decision).toEqual({ kind: "act", text: "call Sam" }); // learned twice: acts, without asking Claude
    expect(claude.calls.length).toBe(callsBefore);
    expect(third.events.find((event) => event.type === "phrasebook")).toMatchObject({ match: { meant: "call Sam", strong: true } });
  });

  it("needs the realtime transcript for agreement on a hinted name (review finding 5)", async () => {
    const result = await run(request({ keyterms: ["Priya"] }), says("message Priya"), says("message Priya"));
    expect(result.decision).toEqual({ kind: "confirm", question: "Message Priya?", reading: "message Priya" });
    const withLive = await run(request({ keyterms: ["Priya"], realtimeText: "message priya" }), says("message Priya"), says("message Priya"));
    expect(withLive.decision).toEqual({ kind: "act", text: "message Priya" });
  });
});

describe("understandTurn: hints and stage switches", () => {
  const entry = { id: "e1", heard: "call some", meant: "call Sam", hearer: "scribe" as const, timesConfirmed: 1, lastConfirmedAt: Date.now(), source: "enrolment" as const };

  it("combines expected answers, the phrasebook, the page's words and the contacts", async () => {
    const seen: HearingRequest[] = [];
    const result = await run(request({ phrasebook: [entry], keyterms: ["Send", "", "sam"], context: { expectedAnswers: ["yes", "no"] } }),
      says("hi"), says("hi"), fakeClaude(null), seen);
    const expected = ["yes", "no", "call Sam", "call", "Sam", "Send", "Mum", "Priya", "Dad", "Amma"];
    expect(seen[0].keyterms).toEqual(expected);
    expect(result.events[0]).toMatchObject({ type: "turn.started", keyterms: expected });
  });

  it("turns each stage off with its switch", async () => {
    const seen: HearingRequest[] = [];
    const claude = fakeClaude(high("call Sam"));
    const off = { keyterms: false, gemini: false, examples: false, phrasebook: false, repair: false };
    const example = { wavBase64: "AAAA", text: "call Sam" };
    const result = await run(request({ phrasebook: [entry], examples: [example], switches: off }), says("call some"), says("cool sum"), claude, seen);
    expect(seen).toHaveLength(1); // Gemini not called
    expect(seen[0].keyterms).toEqual([]);
    expect(seen[0].examples).toEqual([]);
    expect(result.events.find((event) => event.type === "phrasebook")).toMatchObject({ match: null });
    expect(result.events.find((event) => event.type === "repair.skipped")).toMatchObject({ why: "Repair is switched off." });
    expect(claude.calls).toHaveLength(0);

    const noPhrasebook: HearingRequest[] = [];
    await run(request({ phrasebook: [entry], examples: [example], keyterms: ["Priya"], switches: { ...off, keyterms: true, gemini: true, examples: true } }),
      says("hi"), says("hi"), fakeClaude(null), noPhrasebook);
    expect(noPhrasebook[0].keyterms).toEqual(["Priya", "Mum", "Sam", "Dad", "Amma"]);
    expect(noPhrasebook[1].examples).toHaveLength(1);
  });
});
