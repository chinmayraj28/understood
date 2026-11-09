// Ported from Packages/HFUnderstand/Tests/HFUnderstandTests/DeciderTests.swift, case for case.
// Apple's on-device recogniser there is the realtime recogniser here.
import { describe, expect, it } from "vitest";
import { cannotHearMessage, decide as decideFull } from "../shared/rules/decider";
import { strongMatchSimilarity } from "../shared/rules/evidence";
import { normalise, similarity, soundKey } from "../shared/rules/speechText";
import { decide, heard, match, reading } from "./helpers";

describe("Decider: the stage 4 table", () => {
  it("acts on agreement and a high reading", () => {
    expect(decide(heard("Volume up", "volume up.", "volume up"), { reading: reading("volume up", "high") }))
      .toEqual({ kind: "act", text: "volume up" });
  });

  it("acts on a strong phrasebook match and a high reading", () => {
    const scribeMatch = match("call Sam", "call some", 1, 3);
    const gemini = match("call Sam", "cool sum", 1, 2);
    expect(decide(heard("call some", "cool sum", "call some"), { reading: reading("call Sam", "high"), scribeMatch, own: { gemini } }))
      .toEqual({ kind: "act", text: "call Sam" });
  });

  it("still asks when the phrasebook pair was confirmed only once", () => {
    const scribeMatch = match("call Sam", "call some", 1, 1);
    expect(decide(heard("call some", "cool sum", "call some"), { reading: reading("call Sam", "high"), scribeMatch }))
      .toEqual({ kind: "confirm", question: "Call Sam?", reading: "call Sam" });
  });

  it("asks when a high reading changes the agreed words (Claude alone never acts)", () => {
    expect(decide(heard("call some", "call some", null), { reading: reading("call Sam", "high") }))
      .toEqual({ kind: "confirm", question: "Call Sam?", reading: "call Sam" });
  });

  it("asks on disagreement over a content word even when high", () => {
    expect(decide(heard("message Mum", "message Sam", "message Mum"), { reading: reading("message Mum", "high") }))
      .toEqual({ kind: "confirm", question: "Message Mum?", reading: "message Mum" });
  });

  it("still acts when they differ only on filler words", () => {
    expect(decide(heard("open WhatsApp", "open the WhatsApp please", "Open WhatsApp."), { reading: reading("open WhatsApp", "high") }))
      .toEqual({ kind: "act", text: "open WhatsApp" });
  });

  it("asks one yes/no question on medium", () => {
    expect(decide(heard("message mum", "message mum", "message mum"), { reading: reading("message Mum.", "medium") }))
      .toEqual({ kind: "confirm", question: "Message Mum?", reading: "message Mum." });
  });

  it("offers a short choice on low with alternatives", () => {
    expect(decide(heard("message mom", "message some", null), { reading: reading("message Mum", "low", ["message Sam"]) }))
      .toEqual({ kind: "choose", question: "Mum or Sam?", options: ["message Mum", "message Sam"] });
  });

  it("lists three options", () => {
    expect(decide(heard("call", "call", null), { reading: reading("call Mum", "low", ["call Sam", "call Tom"]) }))
      .toEqual({ kind: "choose", question: "Mum, Sam or Tom?", options: ["call Mum", "call Sam", "call Tom"] });
  });

  it("asks for the part it missed on low without alternatives", () => {
    expect(decide(heard("message blur", "message mrr", null), { reading: reading("message", "low") }))
      .toEqual({ kind: "askAgain", question: "Message what? Say just that part." });
  });

  it("asks once more when there is nothing in common", () => {
    expect(decide(heard("blur", "mrr hmm", null), { reading: reading("blur", "low") }))
      .toEqual({ kind: "askAgain", question: "Sorry, say it once more?" });
  });

  it("never asks to say it again twice in a row", () => {
    expect(decide(heard("blur", "mrr", null), { reading: reading("open Spotify", "low"), failedTries: 1 }))
      .toEqual({ kind: "confirm", question: "Open Spotify?", reading: "open Spotify" });
  });

  it("asks only yes/no questions after two failed tries", () => {
    expect(decide(heard("message mom", "message some", null), { reading: reading("message Mum", "low", ["message Sam"]), failedTries: 2 }))
      .toEqual({ kind: "confirm", question: "Message Mum?", reading: "message Mum" });
  });
});

describe("Decider: stop, answers and failures", () => {
  it("acts at once on stop from any recogniser", () => {
    expect(decide(heard("open safari", "stop", "open safari"))).toEqual({ kind: "act", text: "stop" });
    expect(decide(heard("Stop!", null, null), { expected: ["yes", "no"] })).toEqual({ kind: "act", text: "stop" });
    expect(decide(heard("cancel cancel", null, null), { failedTries: 5 })).toEqual({ kind: "act", text: "cancel" });
  });

  it("treats stop inside a sentence as an ordinary turn", () => {
    expect(decide(heard("stop the music", "stop the music", null), { reading: reading("stop the music", "medium") }))
      .toEqual({ kind: "confirm", question: "Stop the music?", reading: "stop the music" });
    // "don't stop" is not a stop command either.
    expect(decide(heard("don't stop", null, null))).toEqual({ kind: "confirm", question: "Don't stop?", reading: "don't stop" });
  });

  it("acts when two recognisers hear an expected answer", () => {
    expect(decide(heard("Yes.", "yes please", "yeah"), { expected: ["yes", "no"] })).toEqual({ kind: "act", text: "yes" });
    expect(decide(heard("Sam", "sam", null), { expected: ["message Mum", "message Sam"] })).toEqual({ kind: "act", text: "message Sam" });
  });

  it("does not act when only one recogniser hears an expected answer", () => {
    expect(decide(heard("yes", "yet", null), { reading: reading("yes", "medium"), expected: ["yes", "no"] }))
      .toEqual({ kind: "confirm", question: "Yes?", reading: "yes" });
  });

  it("cannot hear when every recogniser failed", () => {
    expect(decide(heard(null, null, null))).toEqual({ kind: "cannotHear", message: "I can't hear properly right now." });
    expect(decide(heard("", "  ", "..."))).toEqual({ kind: "cannotHear", message: "I can't hear properly right now." });
    expect(decide([])).toEqual({ kind: "cannotHear", message: cannotHearMessage });
  });

  it("acts on agreement with Gemini down, but medium asks", () => {
    expect(decide(heard("scroll down", null, "scroll down"), { reading: reading("scroll down", "high") })).toEqual({ kind: "act", text: "scroll down" });
    expect(decide(heard("scroll down", null, "scroll down"), { reading: reading("scroll down", "medium") }))
      .toEqual({ kind: "confirm", question: "Scroll down?", reading: "scroll down" });
  });

  it("asks about everything above low when Scribe is down", () => {
    expect(decide(heard(null, "scroll down", "scroll down"), { reading: reading("scroll down", "high") }))
      .toEqual({ kind: "confirm", question: "Scroll down?", reading: "scroll down" });
  });

  it("falls back to agreement, then the phrasebook, then Scribe without a reading", () => {
    expect(decide(heard("volume up", "volume up", "Volume up."))).toEqual({ kind: "act", text: "volume up" });
    const scribeMatch = match("call Sam", "call some", 0.95, 2);
    const gemini = match("call Sam", "cool sum", 1, 2);
    expect(decide(heard("call some", "cool sum", null), { scribeMatch, own: { gemini } })).toEqual({ kind: "act", text: "call Sam" });
    expect(decide(heard("call some", "cool sum", null))).toEqual({ kind: "confirm", question: "Call some?", reading: "call some" });
    expect(decide(heard(null, "cool sum", null))).toEqual({ kind: "confirm", question: "Cool sum?", reading: "cool sum" });
  });

  it("asks when the live recogniser alone heard a different word, and says so", () => {
    // From the page's live test: punctuation (":" and ",") is ignored, but "massage" is a different word.
    const result = decideFull({
      hypotheses: heard("Message Mum: I'm running late", "Message Mum, I'm running late.", "massage mum I'm running late"),
      reading: reading("Message Mum, I'm running late", "high"), hintedTerms: ["Mum"],
    });
    expect(result.decision).toEqual({ kind: "confirm", question: "Message Mum, I'm running late?", reading: "Message Mum, I'm running late" });
    expect(result.rule).toBe("Claude was sure, but the recognisers disagreed: the live recogniser heard \"massage mum I'm running late\", so it asks one yes/no question first.");
    const agreeing = decideFull({
      hypotheses: heard("Message Mum: I'm running late", "Message Mum, I'm running late.", "message mum I'm running late"),
      reading: reading("Message Mum, I'm running late", "high"), hintedTerms: ["Mum"],
    });
    expect(agreeing.decision).toEqual({ kind: "act", text: "Message Mum, I'm running late" });
  });

  it("says which rule fired, in plain words", () => {
    const acted = decideFull({ hypotheses: heard("volume up", "volume up", "volume up"), reading: reading("volume up", "high") });
    expect(acted.rule).toBe("The recognisers heard the same words and Claude was sure, so it acts.");
    const asked = decideFull({ hypotheses: heard("message Mum", "message Sam", null), reading: reading("message Mum", "high") });
    expect(asked.rule).toContain("asks one yes/no question first");
  });
});

describe("SpeechText", () => {
  it("normalises case, punctuation and numbers", () => {
    expect(normalise("Call Sam, at TWO!")).toBe("call sam at 2");
    expect(normalise("Don’t")).toBe("dont");
  });

  it("gives sound-alike words the same key", () => {
    expect(soundKey("some")).toBe(soundKey("sum"));
    expect(soundKey("phone")).toBe(soundKey("fone"));
    expect(soundKey("mum")).not.toBe(soundKey("sam"));
    expect(soundKey("sum")).toBe("S500");
  });

  it("ranks close transcripts higher", () => {
    expect(similarity("call some", "Call some.")).toBe(1);
    const soundAlike = similarity("call some", "call sum");
    expect(soundAlike).toBeGreaterThan(0.8);
    expect(soundAlike).toBeLessThan(strongMatchSimilarity);
    expect(similarity("call some", "open spotify")).toBeLessThan(0.5);
  });
});
