// Compares audio models reachable through OpenRouter as the "second listener", on the same TORGO
// dev clips, zero-shot and with the speaker's own set-up clips as examples. Scored with the
// evaluation's word error rate. Answers are cached like the main harness.
//
//   npx tsx scripts/compareListeners.ts --models google/gemini-3.8-flash,google/gemini-4-argon --per-speaker 6 [--shots 0,5] [--layout turns|single]

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cleanTranscript, geminiBody, geminiReplyText } from "../server/hearers";
import { countErrors, errorRate, sameWords } from "../shared/wordErrors";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const dataDir = repo("eval/data/torgo");
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) if (process.argv[i].startsWith("--")) args.set(process.argv[i].slice(2), process.argv[++i] ?? "1");
const models = (args.get("models") ?? "google/gemini-3.8-flash").split(",");
const shotsList = (args.get("shots") ?? "0,5").split(",").map(Number);
const perSpeaker = Number(args.get("per-speaker") ?? 6);
const layout = args.get("layout") ?? "turns";
const cacheDir = process.env.EVAL_CACHE || path.join(tmpdir(), "understood-eval-cache");
mkdirSync(cacheDir, { recursive: true });

const env: Record<string, string> = {};
for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const key = process.env.OPENROUTER_API_KEY || env.OPENROUTER_API_KEY;

interface Clip {
  id: string;
  speaker: string;
  kind: string;
  prompt: string;
  split: string;
  audio: string;
  repeatedLater?: boolean;
}
const manifest = JSON.parse(readFileSync(path.join(dataDir, "manifest.json"), "utf8")) as { clips: Clip[]; speakers: { id: string; group: string }[] };
const hash = (t: string) => createHash("sha256").update(t).digest("hex").slice(0, 24);
const splitOf = (id: string) => (parseInt(hash(`split:${id}`).slice(0, 8), 16) % 2 === 0 ? "dev" : "holdout");
const wav = (c: Clip) => readFileSync(path.join(dataDir, c.audio)).toString("base64");

function clipsFor(speaker: string): Clip[] {
  const tests = manifest.clips.filter((c) => c.speaker === speaker && c.split === "test" && splitOf(c.id) === "dev").sort((a, b) => hash(a.id).localeCompare(hash(b.id)));
  const s = tests.filter((c) => c.kind === "sentence");
  const w = tests.filter((c) => c.kind !== "sentence");
  const nS = Math.min(s.length, Math.round(perSpeaker * 0.4));
  return [...s.slice(0, nS), ...w.slice(0, perSpeaker - nS)];
}
/** The speaker's set-up clips the page would show Gemini: prompts said again first. */
function examplesFor(speaker: string, n: number) {
  const enrol = manifest.clips.filter((c) => c.speaker === speaker && c.split === "enrolment");
  const ordered = [...enrol.filter((c) => c.repeatedLater), ...enrol.filter((c) => !c.repeatedLater)].slice(0, 20);
  return ordered.slice(0, n).map((c) => ({ wavBase64: wav(c), text: c.prompt }));
}

const timings = new Map<string, number[]>();
async function hear(model: string, clip: Clip, shots: number): Promise<string> {
  const k = `${model}|${shots}`;
  const examples = examplesFor(clip.speaker, shots);
  const purpose = layout === "single" ? "transcribe" : undefined;
  const body = { ...geminiBody({ wavBase64: wav(clip), keyterms: [], examples, signal: new AbortController().signal, seconds: 30, purpose, model }), model } as Record<string, unknown>;
  if (!model.startsWith("google/")) delete body.reasoning;
  const file = path.join(cacheDir, `${hash(JSON.stringify(["listener", model, clip.id, shots, layout, hash(JSON.stringify(body))]))}.json`);
  if (existsSync(file)) {
    const saved = JSON.parse(readFileSync(file, "utf8"));
    timings.set(k, [...(timings.get(k) ?? []), saved.ms]);
    return saved.text;
  }
  const started = Date.now();
  const r = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60000),
  });
  const json = await r.json().catch(() => null);
  let text = "";
  try {
    text = cleanTranscript(geminiReplyText(json));
  } catch (error) {
    text = `(error: ${(error as Error).message})`;
  }
  timings.set(k, [...(timings.get(k) ?? []), Date.now() - started]);
  if (!text.startsWith("(error")) writeFileSync(file, JSON.stringify({ text, ms: Date.now() - started }));
  return text;
}

async function main() {
  const clips = manifest.speakers.flatMap((s) => clipsFor(s.id));
  console.log(`${clips.length} dev clips`);
  const results: string[] = ["| model | shots | median/p90 | n | WER | words WER | sentences WER | dysarthric WER | exact |", "|---|---|---|---|---|---|---|---|---|"];
  const detail: Record<string, unknown[]> = {};
  for (const model of models) {
    for (const shots of shotsList) {
      const rows: { clip: Clip; text: string }[] = [];
      let next = 0;
      await Promise.all(
        Array.from({ length: 6 }, async () => {
          while (next < clips.length) {
            const clip = clips[next++];
            rows.push({ clip, text: await hear(model, clip, shots).catch((e) => `(error: ${(e as Error).message})`) });
          }
        }),
      );
      const wer = (rs: typeof rows) => {
        const sum = rs.reduce((a, r) => {
          const c = countErrors(r.clip.prompt, r.text.startsWith("(") ? "" : r.text);
          return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
        }, { errors: 0, referenceWords: 0 });
        return `${(errorRate(sum) * 100).toFixed(1)}%`;
      };
      const dys = (r: (typeof rows)[0]) => manifest.speakers.find((s) => s.id === r.clip.speaker)?.group === "dysarthric";
      const exact = rows.filter((r) => sameWords(r.clip.prompt, r.text)).length / rows.length;
      const errors = rows.filter((r) => r.text.startsWith("(error")).length;
      const ms = [...(timings.get(`${model}|${shots}`) ?? [0])].sort((a, b) => a - b);
      results.push(
        `| ${model} | ${shots} | ${(ms[ms.length >> 1] / 1000).toFixed(1)}s/${(ms[Math.floor(ms.length * 0.9)] / 1000).toFixed(1)}s | ${rows.length}${errors ? ` (${errors} errors)` : ""} | ${wer(rows)} | ${wer(rows.filter((r) => r.clip.kind !== "sentence"))} | ${wer(rows.filter((r) => r.clip.kind === "sentence"))} | ${wer(rows.filter(dys))} | ${(exact * 100).toFixed(0)}% |`,
      );
      detail[`${model}|${shots}${layout === "single" ? "|single" : ""}`] = rows.map((r) => ({ id: r.clip.id, prompt: r.clip.prompt, text: r.text }));
      console.log(results.at(-1));
    }
  }
  console.log(results.join("\n"));
  const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, `listeners-${Date.now()}.json`), JSON.stringify({ results, detail }, null, 2));
}
main();
