// Small text helpers shared by the decider and the phrasebook, so "do these two transcripts say
// the same thing?" has one answer everywhere. Ported from the Swift SpeechText.swift
// (Packages/HFUnderstand), which the evaluation on real impaired speech ran against.
//
// Three ideas, each simple enough to explain in a sentence:
// - Normalise: lowercase, drop punctuation, fold "two" into "2". "Call Sam." and "call sam" are
//   the same sentence.
// - Content words: the words that change the meaning. "Open the WhatsApp please" and
//   "open WhatsApp" have the same content words, so two recognisers that differ only on "the"
//   still agree.
// - Similarity: an edit distance over words, where swapping one word for another costs less when
//   the two are spelled alike ("whatsap" for "whatsapp") or sound alike ("sum" for "some").
//   1 means identical, 0 means nothing in common.

/** Number words folded into digits, because recognisers write numbers either way. */
const numberWords: Record<string, string> = {
  zero: "0", one: "1", two: "2", three: "3", four: "4", five: "5", six: "6",
  seven: "7", eight: "8", nine: "9", ten: "10", eleven: "11", twelve: "12",
};

/**
 * Words that rarely change what a command means. Kept short on purpose: "on" and "off" are not
 * here, because "turn on" and "turn off" are opposites.
 */
export const fillerWords: ReadonlySet<string> = new Set([
  "a", "an", "the", "to", "please", "um", "umm", "uh", "er", "erm", "ah", "oh", "hey",
  "ok", "okay", "just", "so", "like", "and", "of", "for", "my", "can", "you", "could", "would",
]);

/** Words that turn a sentence into its opposite. After normalising, "don't" is "dont". */
export const negationWords: ReadonlySet<string> = new Set(["no", "not", "dont", "never", "cancel", "nope"]);

const letterOrDigit = /[\p{L}\p{N}\p{M}]/u;
const allDigits = /^\p{N}+$/u;

/** Lowercase words with punctuation removed and number words folded to digits. */
export function words(text: string): string[] {
  // NFC first: Swift treats "Zoë" typed as one character or as "e" plus a mark as the same word.
  const lowered = text.normalize("NFC").toLowerCase().replaceAll("&", " and ");
  let cleaned = "";
  for (const character of lowered) {
    if (letterOrDigit.test(character)) cleaned += character;
    else if (character === "'" || character === "’") continue; // "don't" becomes "dont"
    else cleaned += " ";
  }
  return cleaned.split(" ").filter((word) => word.length > 0).map((word) => numberWords[word] ?? word);
}

/** The normalised sentence as one string: "Call Sam!" becomes "call sam". */
export function normalise(text: string): string {
  return words(text).join(" ");
}

/** The words that carry meaning, in order. */
export function contentWords(text: string): string[] {
  return words(text).filter((word) => !fillerWords.has(word));
}

/** True when the text contains a negation word. */
export function containsNegation(text: string): boolean {
  return words(text).some((word) => negationWords.has(word));
}

function isUppercase(character: string | undefined): boolean {
  return character !== undefined && character !== character.toLowerCase() && character === character.toUpperCase();
}

/**
 * Names: words written with a capital that are not the first word ("message Mum" gives "mum"),
 * lowercased. Recognisers differ in casing, so callers pool names from every text.
 */
export function names(text: string): Set<string> {
  // Split as Swift does: on spaces and on "\n", but not inside "\r\n", which Swift treats as one
  // character that is neither. So "message\r\nMum" stays one word there, and here too.
  const raw = text.normalize("NFC").split(/ |(?<!\r)\n/).filter((part) => part.length > 0);
  return new Set(raw.slice(1).filter((part) => isUppercase([...part][0])).flatMap(words));
}

/**
 * True when the two texts have exactly the same negation words, digits and names (lowercased).
 * One of these words is enough to flip what a sentence means ("do not send" against "do send",
 * "2" against "3", "Sam" against "Mum"), so a near match that differs on one of them must never
 * be trusted as the same sentence.
 */
export function keyWordsAgree(first: string, second: string, nameSet: ReadonlySet<string>): boolean {
  const keyWords = (text: string) =>
    new Set(words(text).filter((word) => negationWords.has(word) || allDigits.test(word) || nameSet.has(word)));
  return sameSet(keyWords(first), keyWords(second));
}

export function sameSet<T>(first: ReadonlySet<T>, second: ReadonlySet<T>): boolean {
  if (first.size !== second.size) return false;
  for (const item of first) if (!second.has(item)) return false;
  return true;
}

export function sameWords(first: readonly string[], second: readonly string[]): boolean {
  return first.length === second.length && first.every((word, index) => word === second[index]);
}

/** How alike two transcripts are, from 0 to 1. See the comment at the top for the method. */
export function similarity(first: string, second: string): number {
  return similarityOfWords(words(first), words(second));
}

/** The same measure over word lists that are already normalised. */
export function similarityOfWords(first: readonly string[], second: readonly string[]): number {
  if (first.length === 0 && second.length === 0) return 1;
  const longest = Math.max(first.length, second.length);
  // Classic edit distance over words, with a cheaper substitution for near words.
  let previous = Array.from({ length: second.length + 1 }, (_, index) => index);
  first.forEach((firstWord, rowIndex) => {
    const current = [rowIndex + 1];
    second.forEach((secondWord, columnIndex) => {
      const substitution = previous[columnIndex] + substitutionCost(firstWord, secondWord);
      const deletion = previous[columnIndex + 1] + 1;
      const insertion = current[columnIndex] + 1;
      current.push(Math.min(substitution, deletion, insertion));
    });
    previous = current;
  });
  return Math.max(0, 1 - previous[second.length] / longest);
}

/**
 * 0 for the same word, 0.25 for words that sound alike, otherwise how different the spellings
 * are (0 to 1). The sound-alike cost stays well above zero so "son" is never treated as exactly
 * "some": sounding alike is a hint, not proof.
 */
export function substitutionCost(first: string, second: string): number {
  if (first === second) return 0;
  const spelling = 1 - characterSimilarity(first, second);
  const soundsAlike = characters(first).length > 1 && characters(second).length > 1 && soundKey(first) === soundKey(second);
  return soundsAlike ? Math.min(spelling, 0.25) : spelling;
}

/** 1 minus the character edit distance divided by the longer word's length. */
export function characterSimilarity(first: string, second: string): number {
  const a = characters(first), b = characters(second);
  const longest = Math.max(a.length, b.length);
  if (longest === 0) return 1;
  // Two reused rows instead of new arrays for every pair: this runs for every pair of words
  // between what was heard and every phrasebook entry, so it is the hot loop of a turn.
  if (rowA.length <= b.length) { rowA = new Int32Array(b.length * 2 + 2); rowB = new Int32Array(b.length * 2 + 2); }
  let previous = rowA, current = rowB;
  for (let column = 0; column <= b.length; column += 1) previous[column] = column;
  for (let row = 0; row < a.length; row += 1) {
    current[0] = row + 1;
    for (let column = 0; column < b.length; column += 1) {
      const cost = a[row] === b[column] ? 0 : 1;
      current[column + 1] = Math.min(previous[column] + cost, previous[column + 1] + 1, current[column] + 1);
    }
    [previous, current] = [current, previous];
  }
  return 1 - previous[b.length] / longest;
}

let rowA = new Int32Array(64), rowB = new Int32Array(64);
const characterCache = new Map<string, number[]>();
const characterIds = new Map<string, number>();
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });

/**
 * A word as its characters the way Swift counts them: whole visible letters (grapheme
 * clusters), so "i" with a combining dot is one character, as in Swift. Each character becomes a
 * small number so the hot loop compares numbers. Plain ASCII words skip the segmenter. Cached.
 */
function characters(word: string): number[] {
  let result = characterCache.get(word);
  if (result === undefined) {
    // Clear before numbering, never after, so two cached words never share a stale number.
    if (characterIds.size >= 50_000) { characterIds.clear(); characterCache.clear(); }
    if (characterCache.size >= 5_000) characterCache.clear();
    result = graphemeList(word).map((part) => {
      let id = characterIds.get(part);
      if (id === undefined) characterIds.set(part, (id = characterIds.size));
      return id;
    });
    characterCache.set(word, result);
  }
  return result;
}

/** The word split into whole visible letters, as Swift's Array(String) does. */
function graphemeList(word: string): string[] {
  return /^[\x00-\x7f]*$/.test(word) ? word.split("") : Array.from(graphemes.segment(word), (part) => part.segment);
}

const soundCodes: Record<string, string> = {
  b: "1", f: "1", p: "1", v: "1",
  c: "2", g: "2", j: "2", k: "2", q: "2", s: "2", x: "2", z: "2",
  d: "3", t: "3", l: "4", m: "5", n: "5", r: "6",
};

/**
 * A sound-alike key for one word: Soundex, after a few English spelling folds ("ph" sounds like
 * "f", the "k" in "kn" is silent). "sum" and "some" both give "S500". Digits are their own key,
 * so "2" only matches "2".
 */
export function soundKey(word: string): string {
  const known = soundKeyCache.get(word);
  if (known !== undefined) return known;
  const key = computeSoundKey(word);
  // A small cache: the same words are compared against every phrasebook entry. Cleared when full
  // so it never grows without bound.
  if (soundKeyCache.size >= 5_000) soundKeyCache.clear();
  soundKeyCache.set(word, key);
  return key;
}

const soundKeyCache = new Map<string, string>();

function computeSoundKey(word: string): string {
  let letters = word.toLowerCase();
  const first = graphemeList(letters)[0];
  if (first === undefined || !/^\p{L}/u.test(first)) return letters;
  for (const [spelling, sound] of [["ph", "f"], ["kn", "n"], ["wr", "r"], ["wh", "w"], ["ck", "k"]]) {
    if (letters.startsWith(spelling)) letters = sound + letters.slice(spelling.length);
  }
  if (letters.startsWith("c")) letters = "k" + letters.slice(1);
  // Whole visible letters, and the key's length in them, as Swift counts.
  const characters = graphemeList(letters);
  const key = graphemeList(characters[0].toUpperCase());
  let lastCode: string | undefined = soundCodes[characters[0]];
  for (const character of characters.slice(1)) {
    const code: string | undefined = soundCodes[character];
    if (code !== undefined && code !== lastCode) key.push(code);
    // "h" and "w" do not separate equal codes in Soundex; vowels do.
    if (character !== "h" && character !== "w") lastCode = code;
    if (key.length === 4) break;
  }
  while (key.length < 4) key.push("0");
  return key.slice(0, 4).join("");
}

/** Characters counted as Unicode code points, the way ElevenLabs counts keyterm length. */
export function codePointCount(text: string): number {
  let count = 0;
  for (const _ of text) count += 1;
  return count;
}
