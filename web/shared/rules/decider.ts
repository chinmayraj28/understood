// Decides, in code, whether to act on a turn or ask first. Ported from the Swift Decider.swift
// (docs/SPEECH_PLAN.md, stage 4), with one addition for the website: each decision comes with
// the rule that fired, in plain words, so the page can show why.
//
// Why code and not the prompt: the rule "ask when unsure" must hold when the model is wrong. A
// person who cannot use their hands cannot undo a wrong action, so Claude's confidence is never
// enough on its own: a reading is acted on only when the recognisers or the phrasebook back it
// up word for word.

import type { Decision } from "../pipeline";
import { agreedText, distinguishingParts, trustedExpectedAnswer, trustedPhrasebookMatch } from "./evidence";
import { contentWords, fillerWords, normalise, sameWords, words } from "./speechText";
import { atLeast, type DecisionInput, type Hypothesis } from "./types";

/** After this many failed tries in a row, only yes/no questions are asked: they are the easiest to say. */
export const yesNoOnlyAfterFailedTries = 2;
/** What is said when nothing usable was heard. */
export const cannotHearMessage = "I can't hear properly right now.";
/** Single words that always act at once. Stopping is always safe, so it is never delayed. */
export const stopWords: ReadonlySet<string> = new Set(["stop", "cancel"]);

export interface Decided {
  decision: Decision;
  /** The rule that fired, in plain words, for the page. */
  rule: string;
}

/** The decision for one turn. The rules run in order; the first that applies wins. */
export function decide(input: DecisionInput): Decided {
  const heard = input.hypotheses.filter((hypothesis) => words(hypothesis.text).length > 0);
  // 1. Nothing usable from any recogniser.
  if (heard.length === 0) {
    return { decision: { kind: "cannotHear", message: cannotHearMessage }, rule: "No recogniser heard any words, so it says it can't hear." };
  }

  // 2. "Stop" from any recogniser, or from the reading, acts immediately.
  for (const text of [...heard.map((hypothesis) => hypothesis.text), input.reading?.text ?? ""]) {
    const stop = stopCommand(text);
    if (stop) return { decision: { kind: "act", text: stop }, rule: `"${capitalise(stop)}" on its own always acts at once, because stopping is always safe.` };
  }

  // 3. Answering a question with fixed answers, when the evidence is clean.
  const answer = trustedExpectedAnswer(heard, input);
  if (answer !== null) {
    return {
      decision: { kind: "act", text: answer },
      rule: "Two recognisers, Scribe among them, heard the same answer to the question, and none heard a different answer or a \"no\", so it acts.",
    };
  }

  const agreed = agreedText(heard, input);
  const strongMatch = trustedPhrasebookMatch(heard, input.matchesByHearer ?? {});
  const scribeHeard = heard.some((hypothesis) => hypothesis.hearer === "scribe");
  const failedTries = input.failedTries ?? 0;
  const mayChoose = failedTries < yesNoOnlyAfterFailedTries;
  const mayAskAgain = failedTries === 0; // "say it again" is asked at most once in a row

  // 4. No reading (fast path, or Claude was down): agreement or the phrasebook may act;
  //    otherwise confirm what the main recogniser heard.
  const reading = input.reading;
  if (!reading || words(reading.text).length === 0) {
    if (strongMatch) {
      return {
        decision: { kind: "act", text: strongMatch.meant },
        rule: `What was heard matches a phrasebook entry confirmed ${strongMatch.timesConfirmed} times, from the same recogniser, and no recogniser heard otherwise, so it acts.`,
      };
    }
    if (agreed !== null) {
      return { decision: { kind: "act", text: agreed }, rule: "The recognisers that heard something, Scribe among them, heard the same words, so it acts." };
    }
    const best = heard.find((hypothesis) => hypothesis.hearer === "scribe") ?? heard[0];
    return {
      decision: confirm(best.text),
      rule: `${whyNoAgreement(heard)}, and there was no reading from Claude, so it asks about what ${hearerLabel(best)} heard.`,
    };
  }

  // 5. A reading. High confidence acts only when the evidence says the same words, and only with
  //    the main recogniser working (with Scribe down, everything above low asks).
  const readingWords = contentWords(reading.text);
  const backedByAgreement = agreed !== null && sameWords(contentWords(agreed), readingWords);
  const backedByPhrasebook = strongMatch !== null && sameWords(contentWords(strongMatch.meant), readingWords);
  if (reading.confidence === "high" && scribeHeard && (backedByAgreement || backedByPhrasebook)) {
    return {
      decision: { kind: "act", text: reading.text },
      rule: backedByAgreement
        ? "The recognisers heard the same words and Claude was sure, so it acts."
        : "A phrasebook entry confirmed more than once backs Claude's reading, and Claude was sure, so it acts.",
    };
  }
  if (atLeast(reading.confidence, "medium")) {
    let why: string;
    if (reading.confidence === "medium") why = "Claude thought this likely but was not sure of a word that matters";
    else if (!scribeHeard) why = "Claude was sure, but Scribe, the main recogniser, heard nothing";
    else why = `Claude was sure, but ${lowerFirst(whyNoAgreement(heard, readingWords))}`;
    return { decision: confirm(reading.text), rule: `${why}, so it asks one yes/no question first.` };
  }

  // 6. Low confidence: offer the likely readings, or ask for it once more, or (after repeated
  //    failures) fall back to a yes/no question about the best guess.
  const options = distinctOptions([reading.text, ...reading.alternatives]);
  if (options.length >= 2 && mayChoose) {
    return {
      decision: { kind: "choose", question: choiceQuestion(options), options },
      rule: "Claude was guessing between likely readings, so it offers a short choice.",
    };
  }
  if (mayAskAgain) {
    return { decision: { kind: "askAgain", question: askAgainQuestion(heard) }, rule: "Claude was guessing, so it asks once to say it again." };
  }
  return {
    decision: confirm(reading.text),
    rule: "Claude was guessing, and it has already asked, so it asks a yes/no question about its best guess: the easiest answer to say.",
  };
}

/** "stop" or "cancel" when the whole turn is just that word (repeats allowed: "stop stop"). */
export function stopCommand(text: string): string | null {
  const list = words(text);
  if (list.length === 0 || !stopWords.has(list[0]) || new Set(list).size !== 1) return null;
  return list[0];
}

// MARK: Building questions

/** "Message Mum?": the reading with a capital and a question mark, nothing else. */
export function confirm(text: string): Decision {
  return { kind: "confirm", question: questionForm(text), reading: text };
}

export function questionForm(text: string): string {
  const trimmed = text.trim().replace(/[.!?,;:]+$/, "");
  return trimmed ? capitalise(trimmed) + "?" : "";
}

/** "Mum or Sam?" for ["message Mum", "message Sam"]: only the words that differ are said. */
export function choiceQuestion(options: string[]): string {
  const parts = distinguishingParts(options);
  const spoken = parts.length <= 2 ? parts.join(" or ") : parts.slice(0, -1).join(", ") + " or " + parts[parts.length - 1];
  return questionForm(spoken);
}

/** Readings that differ once normalised, most likely first, at most three. */
export function distinctOptions(candidates: string[]): string[] {
  const seen = new Set<string>();
  const options: string[] = [];
  for (const candidate of candidates) {
    const key = normalise(candidate);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    options.push(candidate.trim());
  }
  return options.slice(0, 3);
}

/**
 * "Message what? Say just that part." when every recogniser caught the same first word;
 * otherwise a plain request to say it once more.
 */
export function askAgainQuestion(heard: Hypothesis[]): string {
  const firstWords = heard.map((hypothesis) => hypothesis.text.split(" ").filter((word) => word.length > 0)[0] ?? "");
  const first = firstWords[0];
  if (heard.length >= 2 && first && new Set(firstWords.map(normalise)).size === 1 && !fillerWords.has(normalise(first))) {
    const word = first.replace(/^\p{P}+|\p{P}+$/gu, "");
    return capitalise(word.toLowerCase()) + " what? Say just that part.";
  }
  return "Sorry, say it once more?";
}

function capitalise(text: string): string {
  const [first, ...rest] = [...text];
  return first === undefined ? "" : first.toUpperCase() + rest.join("");
}

/**
 * Why the evidence did not back the reading, naming who heard differently:
 * "the live recogniser heard different words (\"massage mum…\")". Only explains; it decides nothing.
 */
function whyNoAgreement(heard: Hypothesis[], readingWords?: string[]): string {
  const scribe = heard.find((hypothesis) => hypothesis.hearer === "scribe");
  const target = scribe ? contentWords(scribe.text) : readingWords;
  if (heard.length < 2) return `Only ${hearerLabel(heard[0])} heard anything`;
  if (target) {
    const differing = heard.filter((hypothesis) => !sameWords(contentWords(hypothesis.text), target));
    if (differing.length > 0) {
      const quoted = differing.map((hypothesis) => `${hearerLabel(hypothesis)} heard "${hypothesis.text.trim()}"`);
      return `The recognisers disagreed: ${quoted.join(" and ")}`;
    }
    if (readingWords && !sameWords(target, readingWords)) return "The recognisers all heard different words from Claude's reading";
  }
  // Same words everywhere, yet no agreement: a hinted name the hint-free live recogniser didn't confirm.
  return "The recognisers agreed on a name they were hinted towards, but the live recogniser, which had no hint, didn't confirm it";
}

const lowerFirst = (text: string) => text.charAt(0).toLowerCase() + text.slice(1);

function hearerLabel(hypothesis: Hypothesis): string {
  return { scribe: "Scribe", gemini: "Gemini", realtime: "the live recogniser" }[hypothesis.hearer];
}

