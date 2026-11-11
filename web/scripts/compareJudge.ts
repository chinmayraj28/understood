// Tries an audio "judge": an audio model hears the clip again (with the speaker's examples) and
// is shown the other recognisers' transcripts as candidates, then writes what was said. Compared
// with Opus merging the same transcripts as text. Uses the cached bake-off answers.
//
//   npx tsx scripts/compareJudge.ts --inputs a,b,c --judge google/gemini-3.1-pro-preview

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cleanTranscript, geminiBody, geminiReplyText } from "../server/hearers";
import { countErrors, errorRate, sameWords } from "../shared/wordErrors";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) if (process.argv[i].startsWith("--")) args.set(process.argv[i].slice(2), process.argv[++i] ?? "1");
const inputs = (args.get("inputs") ?? "").split(",");
const judge = args.get("judge") ?? "google/gemini-3.1-pro-preview";
const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");
const cacheDir = process.env.EVAL_CACHE || path.join(tmpdir(), "understood-eval-cache");
mkdirSync(cacheDir, { recursive: true });
const env: Record<string, string> = {};
for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const dataDir = repo("eval/data/torgo");
const manifest = JSON.parse(readFileSync(path.join(dataDir, "manifest.json"), "utf8")) as {
  clips: { id: string; speaker: string; kind: string; prompt: string; split: string; audio: string; repeatedLater?: boolean }[];
};
const clipById = new Map(manifest.clips.map((c) => [c.id, c]));
const hash = (t: string) => createHash("sha256").update(t).digest("hex").slice(0, 24);

const answers = new Map<string, Map<string, string>>();
for (const file of readdirSync(outDir).sort()) {
  if (!file.endsWith(".json")) continue;
  const json = JSON.parse(readFileSync(path.join(outDir, file), "utf8")) as { detail?: unknown };
  if (!json.detail || Array.isArray(json.detail) || file.startsWith("recognisers-holdout")) continue;
  for (const [key, rows] of Object.entries(json.detail as Record<string, { id: string; text: string }[]>)) {
    if (!Array.isArray(rows)) continue; // other result files (repair runs) have a different shape
    const map = answers.get(key) ?? new Map();
    for (const r of rows) if (!r.text.startsWith("(error")) map.set(r.id, r.text);
    answers.set(key, map);
  }
}
// The latest combiner run with Opus and known phrases, for comparison.
const combiner = readdirSync(outDir).filter((f) => f.startsWith("combiners-")).sort().at(-1);
const opus = new Map<string, string>();
if (combiner) {
  for (const row of (JSON.parse(readFileSync(path.join(outDir, combiner), "utf8")) as { detail: Record<string, string>[] }).detail) {
    if (row["claude-opus-5-5 + known phrases"]) opus.set(row.id, row["claude-opus-5-5 + known phrases"]);
  }
}
const ids = [...answers.get(inputs[0])!.keys()].filter((id) => inputs.every((i) => answers.get(i)?.has(id)));

function examplesFor(speaker: string) {
  const enrol = manifest.clips.filter((c) => c.speaker === speaker && c.split === "enrolment");
  return [...enrol.filter((c) => c.repeatedLater), ...enrol.filter((c) => !c.repeatedLater)]
    .slice(0, 5)
    .map((c) => ({ wavBase64: readFileSync(path.join(dataDir, c.audio)).toString("base64"), text: c.prompt }));
}

async function judged(id: string): Promise<string> {
  const clip = clipById.get(id)!;
  const candidates = [...new Set(inputs.map((i) => answers.get(i)!.get(id)!))];
  const body = geminiBody({ wavBase64: readFileSync(path.join(dataDir, clip.audio)).toString("base64"), keyterms: [], examples: examplesFor(clip.speaker), signal: new AbortController().signal, seconds: 30, purpose: "transcribe", model: judge });
  const messages = body.messages as { role: string; content: unknown[] }[];
  const user = messages[1].content;
  user.splice(user.length - 1, 0, {
    type: "text",
    text: `Other speech recognisers transcribed this last recording as: ${candidates.map((c) => JSON.stringify(c)).join(", ")}. They are often wrong for this speaker. Listen to the recording yourself and write what is actually said; use a candidate only if it matches what you hear.`,
  });
  const file = path.join(cacheDir, `${hash(JSON.stringify(["judge", judge, id, candidates]))}.json`);
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8")).text;
  const r = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENROUTER_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60000),
  });
  try {
    const text = cleanTranscript(geminiReplyText(await r.json()));
    writeFileSync(file, JSON.stringify({ text }));
    return text;
  } catch {
    return candidates[0];
  }
}

async function main() {
  const out = new Map<string, string>();
  let next = 0;
  await Promise.all(
    Array.from({ length: 4 }, async () => {
      while (next < ids.length) {
        const id = ids[next++];
        out.set(id, await judged(id));
      }
    }),
  );
  writeFileSync(path.join(outDir, `judge-${Date.now()}.json`), JSON.stringify({ detail: { [`judge:${judge}`]: ids.map((id) => ({ id, prompt: clipById.get(id)!.prompt, text: out.get(id) })) } }, null, 2));
  const score = (map: Map<string, string>, filter: (id: string) => boolean) => {
    const sel = ids.filter(filter).filter((id) => map.has(id));
    const sum = sel.reduce((a, id) => {
      const c = countErrors(clipById.get(id)!.prompt, map.get(id)!);
      return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
    }, { errors: 0, referenceWords: 0 });
    const exact = sel.filter((id) => sameWords(clipById.get(id)!.prompt, map.get(id)!)).length / Math.max(1, sel.length);
    return `${(errorRate(sum) * 100).toFixed(1)}% (exact ${(exact * 100).toFixed(0)}%, n=${sel.length})`;
  };
  const word = (id: string) => clipById.get(id)!.kind !== "sentence";
  for (const [name, map] of [["judge " + judge, out], ["opus + known phrases", opus]] as const) {
    console.log(`${name}: all ${score(map, () => true)} | words ${score(map, word)} | sentences ${score(map, (id) => !word(id))}`);
  }
}
main();
