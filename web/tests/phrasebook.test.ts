// Ported from PhrasebookTests.swift. The SQLite file became a list the browser keeps, so the
// file-privacy and many-threads tests have no web equivalent; the rest are case for case.
import { describe, expect, it } from "vitest";
import { strongMatchSimilarity } from "../shared/rules/evidence";
import { addPair, bestMatch, learnFromTurn, phrasebookKeyterms } from "../shared/rules/phrasebook";
import { days, heard, makeId, startTime } from "./helpers";
import type { PhrasebookEntry } from "../shared/pipeline";

const add = (book: PhrasebookEntry[], heardText: string, meant: string, hearer: PhrasebookEntry["hearer"], at = startTime) =>
  addPair(book, { heard: heardText, meant, hearer, source: "confirmation" }, at, makeId);

describe("Phrasebook", () => {
  it("counts confirmations when the same pair is added again", () => {
    let book = add([], "call some", "call Sam", "scribe");
    book = add(book, "Call some.", "call sam", "scribe");
    book = add(book, "call some", "call Sam", "realtime");
    expect(book).toHaveLength(2);
    expect(book.find((entry) => entry.hearer === "scribe")?.timesConfirmed).toBe(2);
  });

  it("does not store empty text", () => {
    let book = add([], "  ", "call Sam", "scribe");
    book = add(book, "call some", "...", "scribe");
    expect(book).toHaveLength(0);
  });

  it("matches exact and sound-alike transcripts", () => {
    const book = addPair([], { heard: "call some", meant: "call Sam", hearer: "scribe", source: "correction" }, startTime, makeId);
    const exact = bestMatch(book, ["Call some!"], startTime);
    expect(exact?.meant).toBe("call Sam");
    expect(exact?.similarity).toBe(1);
    expect(exact?.entryId).toBe(book[0].id);
    const soundAlike = bestMatch(book, ["open spotify", "call sum"], startTime);
    expect(soundAlike?.meant).toBe("call Sam");
    expect(soundAlike!.similarity).toBeLessThan(strongMatchSimilarity); // a hint, never strong on its own
    expect(bestMatch(book, ["open spotify"], startTime)).toBeNull();
    expect(bestMatch(book, ["", " "], startTime)).toBeNull();
  });

  it("prefers recent pairs to old ones", () => {
    let book = add([], "message mom", "message Mum", "scribe", startTime);
    book = add(book, "message mom", "message Tom", "gemini", startTime + days(90));
    expect(bestMatch(book, ["message mom"], startTime + days(90))?.meant).toBe("message Tom");
  });

  it("counts old confirmations for less", () => {
    let book: PhrasebookEntry[] = [];
    for (let index = 0; index < 4; index += 1) book = add(book, "call some", "call Sam", "scribe");
    expect(bestMatch(book, ["call some"], startTime)?.timesConfirmed).toBe(4);
    expect(bestMatch(book, ["call some"], startTime + days(60))?.timesConfirmed).toBe(1); // two half-lives
  });

  it("gives keyterms most used first, with their words", () => {
    let book = add([], "scroll town", "scroll down", "scribe");
    for (const hearer of ["scribe", "realtime", "gemini"] as const) book = add(book, "message mom", "message Mum", hearer);
    expect(phrasebookKeyterms(book, 10, startTime)).toEqual(["message Mum", "message", "Mum", "scroll down", "scroll", "down"]);
    expect(phrasebookKeyterms(book, 2, startTime)).toEqual(["message Mum", "message"]);
  });

  it("learns one pair per recogniser that got it wrong, or one meant→meant pair when all were right", () => {
    const wrong = learnFromTurn([], heard("message mom", "message Mum", null), { kind: "corrected", meant: "message Mum" }, startTime, makeId);
    expect(wrong).toHaveLength(1);
    expect(wrong[0]).toMatchObject({ heard: "message mom", meant: "message Mum", hearer: "scribe", source: "correction" });

    const right = learnFromTurn([], heard("scroll down", "Scroll down.", null), { kind: "confirmed", meant: "scroll down" }, startTime, makeId);
    expect(right).toHaveLength(1);
    expect(right[0]).toMatchObject({ heard: "scroll down", meant: "scroll down", hearer: "scribe", source: "confirmation" });
  });
});
