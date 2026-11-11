// Writes public/eval/transcription.json for the landing page: the website pipeline before and
// after the 11 Nov transcription work, on the same held-out TORGO clips, from the rows
// evalTranscription.ts saved. Numbers only: no audio, no transcripts, no prompts.
//
//   npx tsx scripts/exportTranscription.ts <before-holdout.json> <after-holdout.json>

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { errorRate, sameWords } from "../shared/wordErrors";

interface Row {
  speaker: string;
  kind: string;
  prompt: string;
  final: string;
  errors: Record<string, { errors: number; referenceWords: number }>;
}
const [beforeFile, afterFile] = process.argv.slice(2);
const load = (f: string) => (JSON.parse(readFileSync(f, "utf8")) as { rows: Row[] }).rows;
const before = load(beforeFile);
const after = load(afterFile);
const manifest = JSON.parse(readFileSync(fileURLToPath(new URL("../../eval/data/torgo/manifest.json", import.meta.url)), "utf8")) as { speakers: { id: string; group: string }[] };
const dysarthric = (r: Row) => manifest.speakers.find((s) => s.id === r.speaker)?.group === "dysarthric";

function wer(rows: Row[], column = "final"): number {
  const sum = rows.reduce((a, r) => ({ errors: a.errors + r.errors[column].errors, referenceWords: a.referenceWords + r.errors[column].referenceWords }), { errors: 0, referenceWords: 0 });
  return errorRate(sum);
}
function summary(rows: Row[]) {
  return {
    wordErrorRate: wer(rows),
    words: wer(rows.filter((r) => r.kind !== "sentence")),
    sentences: wer(rows.filter((r) => r.kind === "sentence")),
    dysarthric: wer(rows.filter(dysarthric)),
    control: wer(rows.filter((r) => !dysarthric(r))),
    exact: rows.filter((r) => sameWords(r.prompt, r.final)).length / rows.length,
  };
}

const output = {
  title: "Transcription accuracy of this website's pipeline",
  date: "2026-11-11",
  clips: after.length,
  speakers: new Set(after.map((r) => r.speaker)).size,
  note: "Held-out TORGO test clips: a fixed half of the test clips, split by a hash of the clip id before any change was made, and never used to choose anything. Each speaker's voice was set up only from their own earlier clips. Scored with the evaluation's word error rate; fillers are not forgiven. Before: the pipeline as it was on 11 Nov morning (Scribe v2 with hints, Gemini 3.8 Flash, Scribe v2 realtime, a repair prompt written for phone commands). After: Scribe v3, Gemini 3.1 Pro and Gemini 4 Carbon shown five of the speaker's clips, Scribe v3 live, and Claude Opus 5.5 merging them.",
  before: summary(before),
  after: summary(after),
  alone: {
    "Scribe v3 alone": wer(after, "scribe"),
    "Gemini 3.1 Pro alone": wer(after, "gemini"),
    "Live transcript alone": wer(after, "realtime"),
  },
};
writeFileSync(fileURLToPath(new URL("../public/eval/transcription.json", import.meta.url)), `${JSON.stringify(output, null, 2)}\n`);
console.log(JSON.stringify(output, null, 2));
