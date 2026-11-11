// The page scores a recording's transcript the way the TORGO evaluation did (WordErrorRate.swift),
// so the same clip gets the same number in both places.
import { describe, expect, it } from "vitest";
import { alignWords, countErrors, errorRate, sameWords, scoringWords } from "../shared/wordErrors";

describe("word error rate, as the evaluation scored it", () => {
  it("counts one substitution in two words", () => {
    expect(countErrors("Message Mum", "message some")).toEqual({ errors: 1, referenceWords: 2 });
    expect(errorRate(countErrors("Message Mum", "message some"))).toBe(0.5);
  });

  it("ignores case and punctuation, and drops apostrophes", () => {
    expect(scoringWords("Don't STOP, now!")).toEqual(["dont", "stop", "now"]);
    expect(sameWords("Message Mum.", "message mum")).toBe(true);
    expect(sameWords("I’m late", "im late")).toBe(true);
  });

  it("writes numbers as words, splitting digits from letters", () => {
    expect(scoringWords("at 3pm")).toEqual(["at", "three", "pm"]);
    expect(scoringWords("10 minutes")).toEqual(["ten", "minutes"]);
    expect(scoringWords("21")).toEqual(["twenty", "one"]);
    expect(scoringWords("105")).toEqual(["one", "hundred", "five"]);
    expect(scoringWords("2026")).toEqual(["two", "thousand", "twenty", "six"]);
    expect(scoringWords("12345")).toEqual(["12345"]);
    expect(sameWords("set a timer for 10 minutes", "Set a timer for ten minutes")).toBe(true);
  });

  it("an empty reference is 0 when nothing was heard and 1 otherwise", () => {
    expect(errorRate(countErrors("", ""))).toBe(0);
    expect(errorRate(countErrors("", "hello"))).toBe(1);
    expect(errorRate(countErrors("hello", ""))).toBe(1);
  });

  it("can be more than 1 when many words are added", () => {
    expect(errorRate(countErrors("up", "uh up up up"))).toBe(3);
  });

  it("aligns word by word: right, swapped, missed and added", () => {
    expect(alignWords("call mum now", "call some")).toEqual([
      { op: "ok", word: "call" },
      { op: "sub", word: "mum", heard: "some" },
      { op: "del", word: "now" },
    ]);
    expect(alignWords("stop", "okay stop")).toEqual([{ op: "ins", heard: "okay" }, { op: "ok", word: "stop" }]);
  });

  it("the alignment's mistakes always equal the error count", () => {
    const pairs: [string, string][] = [
      ["If you destroy confidence in banks, you do something to the economy, he said.", "Okay. If you destroy the-- if you destroy confidence in banks, you do something to the economy, he said"],
      ["The quick brown fox jumps over the lazy dog.", "the quick brown fox jumped over a lazy dog"],
      ["stubble", "Stabber."],
    ];
    for (const [reference, heard] of pairs) {
      const wrong = alignWords(reference, heard).filter((w) => w.op !== "ok").length;
      expect(wrong).toBe(countErrors(reference, heard).errors);
    }
    // Five added words ("okay" and the restart "if you destroy the") in fourteen: the 36% the page showed.
    expect(countErrors(pairs[0][0], pairs[0][1])).toEqual({ errors: 5, referenceWords: 14 });
  });
});
