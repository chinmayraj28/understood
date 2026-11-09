// Ported from ReviewFindingsTests.swift: one test per finding of the 9 Nov review, each a way a
// wrong reading could have become an action without a question. Finding 7 (file permissions)
// has no web equivalent: the phrasebook lives only in the browser.
import { describe, expect, it } from "vitest";
import type { TurnContext } from "../shared/pipeline";
import { isStrong } from "../shared/rules/evidence";
import { bestMatch, learnFromTurn, matchesByHearer, addPair } from "../shared/rules/phrasebook";
import { keyWordsAgree, similarity } from "../shared/rules/speechText";
import { nextFailedTries } from "../shared/rules/turn";
import { decideInput, heard, isAct, makeId, match, startTime } from "./helpers";

describe("Review findings", () => {
  // 1. Fixed answers: the other recognisers must not out-vote Scribe, and a negation blocks.
  it("needs Scribe and no contradiction for a fixed answer", () => {
    const yesNo: TurnContext = { pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"] };
    expect(isAct(decideInput({ hypotheses: heard("no", "yes", "yes"), context: yesNo }))).toBe(false);
    expect(isAct(decideInput({ hypotheses: heard("yes", "yes", "yes but don't send"), context: yesNo }))).toBe(false);
    expect(decideInput({ hypotheses: heard("No.", "no", "no"), context: yesNo })).toEqual({ kind: "act", text: "no" });

    const names: TurnContext = { pendingQuestion: "Message Mum or message Sam?", expectedAnswers: ["message Mum", "message Sam"] };
    expect(isAct(decideInput({ hypotheses: heard("not Mum", "message Mum", "message Mum"), context: names }))).toBe(false);
    expect(isAct(decideInput({ hypotheses: heard("Mum", "Sam", "Mum"), context: names }))).toBe(false);
    expect(decideInput({ hypotheses: heard("Mum", "mum", null), context: names })).toEqual({ kind: "act", text: "message Mum" });
  });

  // 2. A phrasebook pair counts only for the recogniser that stored it, and only when nobody heard otherwise.
  it("counts a phrasebook pair only for its own recogniser", () => {
    let book = addPair([], { heard: "mess a mum", meant: "message Mum", hearer: "realtime", source: "confirmation" }, startTime, makeId);
    book = addPair(book, { heard: "mess a mum", meant: "message Mum", hearer: "realtime", source: "confirmation" }, startTime, makeId);
    book = addPair(book, { heard: "mess a mum", meant: "message Mum", hearer: "realtime", source: "confirmation" }, startTime, makeId);
    expect(Object.keys(matchesByHearer(book, heard("mess a mum", null, null), startTime))).toEqual([]); // Scribe never stored that pair
    expect(bestMatch(book, ["mess a mum"], startTime)?.meant).toBe("message Mum"); // still a hint for repair

    const contradicted = heard("message Sam", null, "mess a mum");
    const byHearer = matchesByHearer(book, contradicted, startTime);
    expect(byHearer.realtime?.meant).toBe("message Mum");
    expect(decideInput({ hypotheses: contradicted, matchesByHearer: byHearer }))
      .toEqual({ kind: "confirm", question: "Message Sam?", reading: "message Sam" });

    const supported = heard(null, "message mum", "mess a mum");
    expect(decideInput({ hypotheses: supported, matchesByHearer: matchesByHearer(book, supported, startTime) }))
      .toEqual({ kind: "act", text: "message Mum" });
  });

  // 3. A near match that differs on a negation, a number or a name is never strong.
  it("requires negations, numbers and names to be identical", () => {
    const stored = "please do send the message to sam right now";
    const negated = "please do not send the message to sam right now";
    const near = match(stored, stored, similarity(negated, stored), 5);
    expect(isStrong(near)).toBe(true); // close enough on spelling alone...
    expect(decideInput({ hypotheses: heard(negated, null, null), matchesByHearer: { scribe: near } }))
      .toEqual({ kind: "confirm", question: "Please do not send the message to sam right now?", reading: negated }); // ...but never trusted

    expect(keyWordsAgree("set a timer for 2 minutes", "set a timer for 3 minutes", new Set())).toBe(false);
    expect(keyWordsAgree("message Sam that I am running late tonight", "message Tom that I am running late tonight", new Set(["sam", "tom"]))).toBe(false);
    expect(keyWordsAgree("Message mum.", "message Mum", new Set(["mum"]))).toBe(true);
  });

  // 4. Only a spoken yes, a chosen option or a correction is learned; a rejection is not.
  it("learns only from confirmations and corrections", () => {
    const hypotheses = heard("call some", null, null);
    expect(learnFromTurn([], hypotheses, { kind: "rejected" }, startTime, makeId)).toHaveLength(0);
    expect(learnFromTurn([], hypotheses, { kind: "confirmed", meant: "call Sam" }, startTime, makeId)).toHaveLength(1);
  });

  // 5. Hints can push Scribe and Gemini into agreeing on a hinted name: the realtime transcript must agree too.
  it("needs the least-hinted transcript for agreement on a hinted name", () => {
    const input = { hypotheses: heard("message Priya", "message Priya.", null), hintedTerms: ["Priya", "Sam"] };
    expect(decideInput(input)).toEqual({ kind: "confirm", question: "Message Priya?", reading: "message Priya" });
    expect(decideInput({ ...input, hypotheses: heard("message Priya", "message Priya.", "message priya") }))
      .toEqual({ kind: "act", text: "message Priya" });
    expect(decideInput({ ...input, hintedTerms: [] })).toEqual({ kind: "act", text: "message Priya" });

    const yesNo: TurnContext = { pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"] };
    const hintedYes = { hypotheses: heard("yes", "yes", "yet"), context: yesNo, hintedTerms: ["yes", "no"] };
    expect(isAct(decideInput(hintedYes))).toBe(false);
    expect(decideInput({ ...hintedYes, hypotheses: heard("yes", "yes", "yes") })).toEqual({ kind: "act", text: "yes" });
  });

  // 6. A rejected confirmation counts as one failed try, not two.
  it("counts a rejected confirmation once", () => {
    let state = { failedTries: 0, lastQuestion: null as string | null };
    const first = decideInput({ hypotheses: heard("call some", null, "cool sum") });
    expect(first.kind).toBe("confirm");
    state = nextFailedTries(state, first, undefined);
    expect(state.failedTries).toBe(1);

    const answer: TurnContext = { pendingQuestion: state.lastQuestion!, expectedAnswers: ["yes", "no"] };
    const no = decideInput({ hypotheses: heard("no", null, "no"), context: answer });
    expect(no).toEqual({ kind: "act", text: "no" });
    state = nextFailedTries(state, no, answer.pendingQuestion);
    expect(state.failedTries).toBe(2); // one for the question, one for the "no"; learning counts nothing

    const yes = decideInput({ hypotheses: heard("yes", null, "yes"), context: { pendingQuestion: "Send it?", expectedAnswers: ["yes", "no"] } });
    expect(yes).toEqual({ kind: "act", text: "yes" });
    expect(nextFailedTries(state, yes, "Send it?").failedTries).toBe(0);
  });
});
