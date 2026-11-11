// Writes the website's copy of the TORGO evaluation results (public/eval/results.json) from the
// evaluation run's results.json and the dataset manifest. Text and numbers only: no audio, no
// transcripts, nothing from TORGO beyond counts.
//
//   npx tsx scripts/exportEval.ts [results.json] [manifest.json]

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const resultsPath = process.argv[2] ?? repo("eval/results/2026-11-09-second-run/results.json");
const manifestPath = process.argv[3] ?? repo("eval/data/torgo/manifest.json");
const outPath = fileURLToPath(new URL("../public/eval/results.json", import.meta.url));

interface Summary {
  setup: string;
  scope: string;
  clips: number;
  finalWER: number;
  exactMatchRate: number;
  correctActionRate: number;
  wrongActionRate: number;
  askRate: number;
  cannotHearRate: number;
  meanSeconds: number;
  p90Seconds: number;
}

const NAMES: Record<string, string> = {
  scribe: "Scribe alone",
  keyterms: "+ the speaker's phrases as hints",
  gemini: "+ Gemini, shown the speaker's own clips",
  repair: "+ a third recogniser and Claude's repair",
  phrasebook: "+ the phrasebook (the full pipeline)",
};

const results = JSON.parse(readFileSync(resultsPath, "utf8")) as { date: string; setups: Record<string, string>; summaries: Summary[]; records: { speaker: string; clip: string }[] };
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { speakers: { id: string; group: string }[] };
const order = Object.keys(NAMES).filter((id) => results.summaries.some((s) => s.setup === id));
const pick = (setup: string, scope: string) => results.summaries.find((s) => s.setup === setup && s.scope === scope);

const speakers = new Set(results.records.map((r) => r.speaker));
const dysarthric = [...speakers].filter((id) => manifest.speakers.find((s) => s.id === id)?.group === "dysarthric").length;
const clips = new Set(results.records.map((r) => r.clip)).size;

const setups = order.map((id) => {
  const all = pick(id, "all")!;
  return {
    id,
    name: NAMES[id],
    n: all.clips,
    wordErrorRate: all.finalWER,
    seenWordErrorRate: pick(id, "seen")?.finalWER ?? null,
    unseenWordErrorRate: pick(id, "unseen")?.finalWER ?? null,
    dysarthricWordErrorRate: pick(id, "dysarthric")?.finalWER ?? null,
    exactMatchRate: all.exactMatchRate,
    correctActionRate: all.correctActionRate,
    wrongActionRate: all.wrongActionRate,
    askRate: all.askRate,
    meanSeconds: all.meanSeconds,
  };
});

const output = {
  title: "Measured on real recordings of people with dysarthria",
  dataset: `TORGO (University of Toronto and Holland Bloorview): ${speakers.size} speakers, ${dysarthric} with dysarthria from cerebral palsy and ${speakers.size - dysarthric} without, ${clips} test recordings, each heard by every setup.`,
  note: "Each speaker's setup was learned only from their own earlier recordings; no recording is used for both setup and test. In the evaluation the third recogniser was Apple's on-device one; the website uses ElevenLabs realtime in its place. One run, a handful of speakers, mostly single words: treat the numbers as a first measurement, not a benchmark.",
  date: results.date,
  speakers: speakers.size,
  utterances: clips,
  setups,
};
writeFileSync(outPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Wrote ${outPath}: ${setups.length} setups over ${clips} clips.`);
for (const s of setups) console.log(`  ${s.name}: ${(s.wordErrorRate * 100).toFixed(0)}% words wrong, ${(s.exactMatchRate * 100).toFixed(0)}% exactly right`);
