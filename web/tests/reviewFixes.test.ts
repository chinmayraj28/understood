// Tests for the five fixes from the 9 Nov review of the web server.
import { describe, expect, it } from "vitest";
import type { PhrasebookEntry, UnderstandRequest } from "../shared/pipeline";
import { decide } from "../shared/rules/decider";
import { bestMatch, mayReachThreshold, minimumMatchSimilarity } from "../shared/rules/phrasebook";
import { characterSimilarity, contentWords, keyWordsAgree, names, similarity, similarityOfWords, words } from "../shared/rules/speechText";
import { actionFrom, contactFrom } from "../server/act";
import { isSupported, repairData, shownKnownWords } from "../server/repair";
import { RateLimiter, visitorKey } from "../server/app";
import { understandTurn, type UnderstandDeps } from "../server/understand";
import { checkUnderstand, maxPhrasebookEntries, maxRealtimeCharacters } from "../server/validate";
import { heard, startTime } from "./helpers";

// Words that differ in spelling and in sound, so no cache or shortcut makes the test easy.
const letters = "bdfgklmnprstvz";
const word = (seed: number, length: number) =>
  Array.from({ length }, (_, index) => letters[(seed * 7 + index * 13 + ((seed >> 3) % 5)) % letters.length] + "aeiou"[(seed + index) % 5]).join("").slice(0, length);
const sentence = (seed: number, count: number, length: number) => Array.from({ length: count }, (_, index) => word(seed * 31 + index, length)).join(" ");

function worstPhrasebook(): PhrasebookEntry[] {
  const hearers = ["scribe", "gemini", "realtime"] as const;
  return Array.from({ length: maxPhrasebookEntries }, (_, index) => ({
    id: `e${index}`, heard: sentence(index, 20, 14), meant: sentence(index + 1000, 20, 14), hearer: hearers[index % 3],
    timesConfirmed: 3, lastConfirmedAt: startTime, source: "confirmation" as const,
  }));
}

describe("1. the cost of matching is bounded", () => {
  it("skips only pairs that could never reach the match threshold", () => {
    expect(minimumMatchSimilarity).toBe(0.6); // mayReachThreshold's whole-number rule assumes 0.6
    for (let first = 1; first <= 30; first += 1) { // a heard text always has words
      for (let second = 0; second <= 30; second += 1) {
        if (mayReachThreshold(first, second)) continue;
        // Even word lists that share every word they can are below 0.6 when skipped.
        const a = Array.from({ length: first }, (_, index) => `w${index}`), b = Array.from({ length: second }, (_, index) => `w${index}`);
        expect(similarityOfWords(a, b)).toBeLessThan(minimumMatchSimilarity);
      }
    }
    expect(mayReachThreshold(3, 5)).toBe(true); // exactly 60%: compared
    expect(mayReachThreshold(2, 4)).toBe(false);
  });

  it("finds the same matches with the skip as by comparing everything", () => {
    const book = worstPhrasebook().slice(0, 30).concat([
      { id: "x", heard: "call some", meant: "call Sam", hearer: "scribe", timesConfirmed: 2, lastConfirmedAt: startTime, source: "confirmation" },
    ]);
    for (const text of ["call some", "call some now please", "call", "a b c d e f g h", sentence(5, 20, 14)]) {
      const brute = book.map((entry) => similarityOfWords(words(text), words(entry.heard))).filter((value) => value >= 0.6);
      const found = bestMatch(book, [text], startTime);
      expect(found === null).toBe(brute.length === 0);
    }
  });

  it("refuses a live transcript over 600 characters, more than 200 entries, or phrases over 20 words", () => {
    const base = { turnId: "t", wavBase64: "AAAA", phrasebook: [], examples: [], keyterms: [], context: {}, switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true } };
    expect(checkUnderstand({ ...base, realtimeText: "a ".repeat(maxRealtimeCharacters / 2) }).ok).toBe(true);
    expect(checkUnderstand({ ...base, realtimeText: "a ".repeat(maxRealtimeCharacters / 2 + 1) }).ok).toBe(false);
    expect(checkUnderstand({ ...base, phrasebook: worstPhrasebook() }).ok).toBe(true);
    expect(checkUnderstand({ ...base, phrasebook: [...worstPhrasebook(), worstPhrasebook()[0]] }).ok).toBe(false);
    const long = { ...worstPhrasebook()[0], heard: Array(21).fill("a").join(" ") };
    expect(checkUnderstand({ ...base, phrasebook: [long] })).toEqual({ ok: false, error: "phrasebook[0].heard has too many words." });
  });

  it("decides the worst allowed turn in well under 200 ms", async () => {
    const request: UnderstandRequest = {
      turnId: "worst", wavBase64: "AAAA", realtimeText: sentence(77, 20, 14).slice(0, maxRealtimeCharacters),
      phrasebook: worstPhrasebook(), examples: [], keyterms: [], context: {},
      switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: false },
    };
    expect(checkUnderstand(request).ok).toBe(true);
    const deps: UnderstandDeps = {
      hearScribe: async () => sentence(78, 20, 14), hearGemini: async () => sentence(79, 20, 14),
      repair: async () => { throw new Error("off"); }, now: Date.now, hearerSeconds: 4, repairSeconds: 3,
    };
    const oneLetterWords = { ...request, realtimeText: "a ".repeat(maxRealtimeCharacters / 2).trim() };
    for (const turn of [request, oneLetterWords]) {
      const start = performance.now();
      await understandTurn(turn, deps, () => {});
      expect(performance.now() - start).toBeLessThan(200);
    }
  });
});

describe("2. only a listed contact the person named", () => {
  const message = (to: string) => ({ kind: "message", to, text: "running late", minutes: 0, query: "", when: "", reply: "" });
  it("accepts a listed contact named in the sentence, written as listed", () => {
    expect(contactFrom("sam", "message Sam running late")).toBe("Sam");
    expect(actionFrom(message("SAM"), "message sam running late")).toMatchObject({ action: { kind: "message", to: "Sam" }, needsConfirmation: true });
  });

  it("refuses a contact the model chose", () => {
    expect(actionFrom(message("Mallory"), "message Mallory running late"))
      .toEqual({ action: { kind: "none" }, reply: "Who should I send it to? I can message Mum, Sam, Priya, Dad or Amma.", needsConfirmation: false });
    expect(actionFrom(message("Sam"), "tell her I'm running late").action).toEqual({ kind: "none" }); // a listed name nobody said
    expect(actionFrom({ ...message("Mum"), kind: "call" }, "call my mother").reply).toBe("Who should I call? I can call Mum, Sam, Priya, Dad or Amma.");
  });
});

describe("3. Unicode text matches as in Swift", () => {
  it("treats a composed and a decomposed letter as the same word", () => {
    expect(words("message Zoë")).toEqual(words("message Zoë"));
    expect(names("message Zoë")).toEqual(new Set(["zoë"]));
  });

  it("splits lines as Swift does: on \\n, but not inside \\r\\n", () => {
    expect(names("message\nMum")).toEqual(new Set(["mum"]));
    expect(names("message\r\nMum")).toEqual(new Set()); // Swift keeps "message\r\nMum" as one word
  });
});

describe("4. the realtime transcript is hint-free only when it was given no hinted words", () => {
  it("asks when the realtime recogniser was pushed towards the same name", () => {
    const hypotheses = heard("message Priya", "message Priya", "message Priya");
    const input = { hypotheses, hintedTerms: ["Priya", "Sam"] };
    expect(decide({ ...input, realtimeKeyterms: [] }).decision).toEqual({ kind: "act", text: "message Priya" });
    expect(decide({ ...input, realtimeKeyterms: ["call", "message"] }).decision).toEqual({ kind: "act", text: "message Priya" });
    expect(decide({ ...input, realtimeKeyterms: ["Priya"] }).decision).toEqual({ kind: "confirm", question: "Message Priya?", reading: "message Priya" });
    expect(checkUnderstand({ turnId: "t", wavBase64: "AAAA", phrasebook: [], examples: [], keyterms: [], context: {},
      realtimeKeyterms: Array(51).fill("x"), switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true } }).ok).toBe(false);
  });

  it("does the same for an expected answer given to every recogniser", () => {
    const context = { pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"] };
    const input = { hypotheses: heard("yes", "yes", "yes"), context, hintedTerms: ["yes", "no"] };
    expect(decide({ ...input, realtimeKeyterms: [] }).decision).toEqual({ kind: "act", text: "yes" });
    expect(decide({ ...input, realtimeKeyterms: ["yes", "no"] }).decision.kind).not.toBe("act");
  });
});

describe("5. the per-visitor limit", () => {
  it("counts IPv6 by its first 64 bits and IPv4 one by one", () => {
    expect(visitorKey("2001:db8:1:2:aaaa::1")).toBe("2001:db8:1:2::/64");
    expect(visitorKey("2001:db8:1:2:bbbb:cccc:dddd:eeee")).toBe("2001:db8:1:2::/64");
    expect(visitorKey("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(visitorKey("::ffff:203.0.113.7")).toBe("203.0.113.7");
    expect(visitorKey("203.0.113.7")).toBe("203.0.113.7");
  });

  it("forgets the visitor seen longest ago when full, not everyone", () => {
    const limiter = new RateLimiter(1, Date.now, 3);
    expect(limiter.allow("a")).toBe(true);
    limiter.allow("b");
    limiter.allow("c");
    limiter.allow("d"); // "a" is forgotten
    expect(limiter.visitorCount).toBe(3);
    expect(limiter.allow("d")).toBe(false); // "d" is still counted
    expect(limiter.allow("a")).toBe(true);
  });
});

describe("rest of the review: test gaps", () => {
  it("a) treats precomposed and decomposed Zoë alike everywhere, as Swift does", () => {
    const composed = "message Zoë", decomposed = "message Zoë";
    expect(similarity(composed, decomposed)).toBe(1);
    expect(contentWords(composed)).toEqual(contentWords(decomposed));
    expect(keyWordsAgree(composed, decomposed, new Set([...names(composed), ...names(decomposed)]))).toBe(true);
  });

  it("a) counts characters as whole visible letters, as Swift does", () => {
    // "İ" lowercases to "i" plus a combining dot: one letter in Swift, two code points.
    expect(similarity("Call Sam.", "\u0130stanbul")).toBeCloseTo(0.125, 6); // Swift's value
    expect(characterSimilarity("i\u0307s", "is")).toBeCloseTo(1 - 1 / 2, 6);
  });

  it("b) never sends to a contact the model chose against the sentence", () => {
    const answer = (to: string) => ({ kind: "message", to, text: "running late", minutes: 0, query: "", when: "", reply: "Sent" });
    expect(actionFrom(answer("Mallory"), "message Mallory running late").action).toEqual({ kind: "none" });
    expect(actionFrom(answer("Mum"), "message Sam running late")).toMatchObject({ action: { kind: "none" }, needsConfirmation: false });
  });

  it("c) refuses the 22-second request at validation", () => {
    const base = { turnId: "t", wavBase64: "AAAA", examples: [], keyterms: [], context: {}, switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true } };
    const entries = Array.from({ length: 500 }, (_, index) => ({ id: `e${index}`, heard: "x".repeat(300), meant: "y", hearer: "scribe", timesConfirmed: 1, lastConfirmedAt: 0, source: "confirmation" }));
    expect(checkUnderstand({ ...base, phrasebook: [], realtimeText: "a ".repeat(500) }).ok).toBe(false); // 1,000 characters
    expect(checkUnderstand({ ...base, phrasebook: entries, realtimeText: "a" }).ok).toBe(false); // 500 entries
  });

  it("e) stops the hearers and Claude when the visitor goes away", async () => {
    const signals: AbortSignal[] = [];
    const hang = (signal: AbortSignal) => new Promise<never>((_, reject) => {
      signals.push(signal);
      signal.addEventListener("abort", () => reject(signal.reason));
    });
    const base: UnderstandRequest = {
      turnId: "t", wavBase64: "AAAA", realtimeText: "", phrasebook: [], examples: [], keyterms: [], context: {},
      switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true },
    };
    // While hearing.
    const leaving = new AbortController();
    const hearing = understandTurn(base, {
      hearScribe: (request) => hang(request.signal), hearGemini: (request) => hang(request.signal),
      repair: async () => { throw new Error("unused"); }, now: Date.now, hearerSeconds: 4, repairSeconds: 3,
    }, () => {}, leaving.signal);
    setTimeout(() => leaving.abort(), 20);
    await hearing;
    expect(signals).toHaveLength(2);
    expect(signals.every((signal) => signal.aborted)).toBe(true);

    // While repairing.
    const leavingAgain = new AbortController();
    const repairing = understandTurn(base, {
      hearScribe: async () => "call some", hearGemini: async () => "cool sum",
      repair: (_, signal) => hang(signal), now: Date.now, hearerSeconds: 4, repairSeconds: 3,
    }, () => {}, leavingAgain.signal);
    setTimeout(() => leavingAgain.abort(), 20);
    const start = Date.now();
    await repairing;
    expect(Date.now() - start).toBeLessThan(1000);
    expect(signals[2].aborted).toBe(true);
  });

  it("7) checks Claude's reading only against the known words Claude was shown", () => {
    const knownWords = [...Array.from({ length: 40 }, (_, index) => `word${index}`), "Zebedee"];
    const input = { hypotheses: [{ hearer: "scribe" as const, text: "call", seconds: 1 }], phrasebookMatch: null, context: {}, knownWords };
    expect(shownKnownWords(input)).toHaveLength(40);
    expect(isSupported("call Zebedee", input)).toBe(false); // the 41st word was never shown
    expect(repairData(input)).not.toContain("Zebedee");
  });

  it("7) stores confirmation counts as whole numbers", () => {
    const entry = { id: "e", heard: "call some", meant: "call Sam", hearer: "scribe", timesConfirmed: 2.7, lastConfirmedAt: 0, source: "confirmation" };
    const checked = checkUnderstand({ turnId: "t", wavBase64: "AAAA", phrasebook: [entry], examples: [], keyterms: [], context: {}, switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true } });
    expect(checked.ok && checked.value.phrasebook[0].timesConfirmed).toBe(2);
  });
});
