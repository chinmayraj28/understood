// Word error rate: how many words a transcript gets wrong compared with what was said.
//
// A port of Packages/HFUnderstand/Sources/HFUnderstand/Evaluation/WordErrorRate.swift, the
// scoring the TORGO evaluation used, so a clip scored on the page gets the same number the
// evaluation gave it. Both texts are made comparable first (lower case, no punctuation,
// apostrophes dropped, digits written as words), then the fewest insertions, deletions and
// substitutions are counted. Example: "Message Mum" heard as "message some" is 1 error in 2 words.

export interface WordCount {
  errors: number;
  referenceWords: number;
}

/** One word of the alignment: right, swapped for another, missed, or added. */
export type AlignedWord =
  | { op: "ok"; word: string }
  | { op: "sub"; word: string; heard: string }
  | { op: "del"; word: string }
  | { op: "ins"; heard: string };

export function errorRate(count: WordCount): number {
  if (count.referenceWords === 0) return count.errors === 0 ? 0 : 1;
  return count.errors / count.referenceWords;
}

export function countErrors(reference: string, hypothesis: string): WordCount {
  const ref = scoringWords(reference);
  return { errors: align(ref, scoringWords(hypothesis)).filter((w) => w.op !== "ok").length, referenceWords: ref.length };
}

/** True when the two texts are the same after normalising ("Message Mum." and "message mum"). */
export function sameWords(a: string, b: string): boolean {
  return scoringWords(a).join(" ") === scoringWords(b).join(" ");
}

/** The normalised words of a text, as the evaluation scored them. */
export function scoringWords(text: string): string[] {
  const cleaned = [...text.toLowerCase()]
    .filter((c) => c !== "'" && c !== "’")
    .map((c) => (/[\p{L}\p{M}\p{N}]/u.test(c) ? c : " "))
    .join("");
  // Split digits from letters ("3pm" -> "3 pm") so numbers can be written as words.
  const spaced = cleaned.replace(/(\d)(?=[^\d\s])|([^\d\s])(?=\d)/g, "$1$2 ");
  return spaced
    .split(/\s+/)
    .filter(Boolean)
    .flatMap((token) => (/^\d+$/.test(token) ? numberWords(Number(token), token) : [token]));
}

const ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];

/** 0 to 9999 as English words; larger numbers stay as digits. */
function numberWords(value: number, digits = String(value)): string[] {
  if (!Number.isSafeInteger(value) || value >= 10_000) return [digits];
  if (value < 20) return [ONES[value]];
  if (value < 100) return value % 10 === 0 ? [TENS[value / 10]] : [TENS[Math.floor(value / 10)], ONES[value % 10]];
  if (value < 1000) {
    const rest = value % 100;
    return [ONES[Math.floor(value / 100)], "hundred", ...(rest === 0 ? [] : numberWords(rest))];
  }
  const rest = value % 1000;
  return [...numberWords(Math.floor(value / 1000)), "thousand", ...(rest === 0 ? [] : numberWords(rest))];
}

/** The fewest-edit alignment of the reference words with the heard words, in order. */
export function alignWords(reference: string, hypothesis: string): AlignedWord[] {
  return align(scoringWords(reference), scoringWords(hypothesis));
}

function align(ref: string[], hyp: string[]): AlignedWord[] {
  // cost[i][j]: fewest edits turning ref[0..i) into hyp[0..j).
  const cost = Array.from({ length: ref.length + 1 }, (_, i) => Array.from({ length: hyp.length + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)));
  for (let i = 1; i <= ref.length; i++) {
    for (let j = 1; j <= hyp.length; j++) {
      cost[i][j] = Math.min(cost[i - 1][j - 1] + (ref[i - 1] === hyp[j - 1] ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1);
    }
  }
  const out: AlignedWord[] = [];
  let i = ref.length;
  let j = hyp.length;
  // Walking back from the end: a matching word first, then a missed or added word, then a swap.
  // Among equally short alignments this keeps words matched in order ("call mum now" heard as
  // "call some" reads as mum -> some, now missed).
  while (i > 0 || j > 0) {
    const same = i > 0 && j > 0 && ref[i - 1] === hyp[j - 1];
    if (same && cost[i][j] === cost[i - 1][j - 1]) {
      out.push({ op: "ok", word: ref[i - 1] });
      i--;
      j--;
    } else if (i > 0 && cost[i][j] === cost[i - 1][j] + 1) {
      out.push({ op: "del", word: ref[i - 1] });
      i--;
    } else if (j > 0 && cost[i][j] === cost[i][j - 1] + 1) {
      out.push({ op: "ins", heard: hyp[j - 1] });
      j--;
    } else {
      out.push({ op: "sub", word: ref[i - 1], heard: hyp[j - 1] });
      i--;
      j--;
    }
  }
  return out.reverse();
}
