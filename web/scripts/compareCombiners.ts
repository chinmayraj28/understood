// Compares ways of turning several recognisers' transcripts of one clip into one transcript,
// using the answers the bake-off scripts cached (no audio is sent again; only Claude is called).
//
//   npx tsx scripts/compareCombiners.ts --inputs scribe:scribe_v3:no_verbatim,google/gemini-4-argon|5,deepgram/nova-3 [--split dev]
//
// An input is a recogniser from compareRecognisers ("model") or a listener from compareListeners
// ("model|shots"). Strategies: each input alone, the medoid (the transcript closest to all the
// others), and Claude merging them (Haiku, Sonnet), with and without snapping to the nearest input.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { askClaude } from "../server/claude";
import { readingFrom, repairData, repairSchema, transcribeInstructions } from "../server/repair";
import type { Hypothesis } from "../shared/rules/types";
import { alignWords, countErrors, errorRate, sameWords, scoringWords } from "../shared/wordErrors";
import { keytermsFrom } from "../src/model/voices";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) if (process.argv[i].startsWith("--")) args.set(process.argv[i].slice(2), process.argv[++i] ?? "1");
const inputs = (args.get("inputs") ?? "scribe:scribe_v3:no_verbatim").split(",");
const split = args.get("split") ?? "dev";
const claudeModels = (args.get("claude") ?? "claude-haiku-5-5,claude-sonnet-5-5").split(",").filter(Boolean);
const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");

const env: Record<string, string> = {};
for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const manifest = JSON.parse(readFileSync(repo("eval/data/torgo/manifest.json"), "utf8")) as {
  clips: { id: string; speaker: string; kind: string; prompt: string; split: string; repeatedLater?: boolean }[];
  speakers: { id: string; group: string }[];
};
const clipById = new Map(manifest.clips.map((c) => [c.id, c]));

// ── the cached answers ──
const answers = new Map<string, Map<string, string>>(); // input -> clip id -> text
for (const file of readdirSync(outDir).sort()) {
  if (!file.endsWith(".json")) continue;
  const json = JSON.parse(readFileSync(path.join(outDir, file), "utf8")) as { detail?: Record<string, { id: string; text: string }[]> };
  if (!json.detail || Array.isArray(json.detail) || (file.startsWith("recognisers-") && !file.startsWith(`recognisers-${split}`))) continue;
  for (const [key, rows] of Object.entries(json.detail)) {
    if (!Array.isArray(rows)) continue; // other result files (repair runs) have a different shape
    const map = answers.get(key) ?? new Map();
    for (const r of rows) if (!r.text.startsWith("(error")) map.set(r.id, r.text);
    answers.set(key, map);
  }
}
for (const input of inputs) if (!answers.has(input)) throw new Error(`No cached answers for ${input}. Have: ${[...answers.keys()].join(", ")}`);
const clipIds = [...answers.get(inputs[0])!.keys()].filter((id) => inputs.every((i) => answers.get(i)!.has(id)));

function knownPhrases(speaker: string): string[] {
  const enrol = manifest.clips.filter((c) => c.speaker === speaker && c.split === "enrolment");
  return keytermsFrom([...enrol.filter((c) => c.repeatedLater), ...enrol.filter((c) => !c.repeatedLater)].slice(0, 20).map((c) => c.prompt)).slice(0, 40);
}

/** The pipeline lane an input corresponds to. */
function hearerOf(input: string): Hypothesis["hearer"] {
  if (input.startsWith("realtime:")) return "realtime";
  if (input.startsWith("scribe:")) return "scribe";
  if (input.includes("gemini-4")) return "gemini4";
  return "gemini";
}

const distance = (a: string, b: string) => alignWords(a, b).filter((w) => w.op !== "ok").length;
/** The transcript with the smallest total word distance to the others. */
function medoid(texts: string[]): string {
  let best = texts[0];
  let bestCost = Infinity;
  for (const t of texts) {
    const cost = texts.reduce((sum, o) => sum + distance(t, o), 0) + (scoringWords(t).length === 0 ? 1000 : 0);
    if (cost < bestCost) [best, bestCost] = [t, cost];
  }
  return best;
}
/** Snap a reading to the nearest input, unless it agrees with none and the inputs all disagree. */
function snap(reading: string, texts: string[]): string {
  return texts.reduce((best, t) => (distance(reading, t) < distance(reading, best) ? t : best), texts[0]);
}

async function claudeMerge(model: string, clipId: string, texts: string[], withPhrases: boolean): Promise<string> {
  const clip = clipById.get(clipId)!;
  // Each input is named by the recogniser it really is: the prompt says Scribe and realtime are one engine.
  const hypotheses: Hypothesis[] = texts.map((text, i) => ({ hearer: hearerOf(inputs[i]), text, seconds: 0 }));
  const input = { hypotheses, phrasebookMatch: null, context: {}, knownWords: withPhrases ? knownPhrases(clip.speaker) : [], purpose: "transcribe" as const };
  try {
    const answer = await askClaude(env.ANTHROPIC_API_KEY, {
      instructions: transcribeInstructions,
      input: repairData(input),
      schema: repairSchema,
      signal: AbortSignal.timeout(30000),
      seconds: 30,
      model,
    });
    return readingFrom(answer, input).text;
  } catch {
    return texts[0];
  }
}

async function main() {
  console.log(`${clipIds.length} clips with answers from every input: ${inputs.join(" + ")}`);
  const strategies: Record<string, Map<string, string>> = {};
  for (const input of inputs) strategies[`alone: ${input}`] = answers.get(input)!;
  strategies.medoid = new Map(clipIds.map((id) => [id, medoid(inputs.map((i) => answers.get(i)!.get(id)!))]));
  for (const model of claudeModels) {
    for (const withPhrases of [false, true]) {
      const merged = new Map<string, string>();
      let next = 0;
      await Promise.all(
        Array.from({ length: 6 }, async () => {
          while (next < clipIds.length) {
            const id = clipIds[next++];
            const texts = inputs.map((i) => answers.get(i)!.get(id)!);
            // Skip Claude when every input already agrees.
            merged.set(id, texts.every((t) => sameWords(t, texts[0])) ? texts[0] : await claudeMerge(model, id, texts, withPhrases));
          }
        }),
      );
      const name = `${model}${withPhrases ? " + known phrases" : ""}`;
      strategies[name] = merged;
      strategies[`${name}, snapped`] = new Map([...merged].map(([id, t]) => [id, snap(t, inputs.map((i) => answers.get(i)!.get(id)!))]));
    }
  }

  const table = ["| strategy | WER | words | sentences | dysarthric | exact |", "|---|---|---|---|---|---|"];
  const dys = (id: string) => manifest.speakers.find((s) => s.id === clipById.get(id)!.speaker)?.group === "dysarthric";
  for (const [name, map] of Object.entries(strategies)) {
    const wer = (ids: string[]) => {
      const sum = ids.reduce((a, id) => {
        const c = countErrors(clipById.get(id)!.prompt, map.get(id) ?? "");
        return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
      }, { errors: 0, referenceWords: 0 });
      return `${(errorRate(sum) * 100).toFixed(1)}%`;
    };
    const words = clipIds.filter((id) => clipById.get(id)!.kind !== "sentence");
    const sentences = clipIds.filter((id) => clipById.get(id)!.kind === "sentence");
    const exact = clipIds.filter((id) => sameWords(clipById.get(id)!.prompt, map.get(id) ?? "")).length / clipIds.length;
    table.push(`| ${name} | ${wer(clipIds)} | ${wer(words)} | ${wer(sentences)} | ${wer(clipIds.filter(dys))} | ${(exact * 100).toFixed(0)}% |`);
  }
  console.log(table.join("\n"));
  const detail = clipIds.map((id) => ({ id, prompt: clipById.get(id)!.prompt, ...Object.fromEntries(Object.entries(strategies).map(([k, m]) => [k, m.get(id)])) }));
  writeFileSync(path.join(outDir, `combiners-${Date.now()}.json`), JSON.stringify({ inputs, table, detail }, null, 2));
}
main();
