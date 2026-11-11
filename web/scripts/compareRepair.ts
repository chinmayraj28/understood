// Re-runs only the repair step on the transcripts an evalTranscription run saved, with different
// instructions, to compare them on the same evidence. The final text is Claude's reading where the
// pipeline asked Claude, and the pipeline's own final text where it did not (the recognisers agreed).
//
//   npx tsx scripts/compareRepair.ts --rows new-dev.json

import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { askClaude } from "../server/claude";
import { readingFrom, repairData, repairSchema, transcribeInstructions } from "../server/repair";
import type { HearerName } from "../shared/pipeline";
import type { Hypothesis } from "../shared/rules/types";
import { countErrors, errorRate, sameWords } from "../shared/wordErrors";
import { keytermsFrom, setupClipsFor } from "../src/model/voices";
import type { DatasetIndex } from "../shared/dataset";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) if (process.argv[i].startsWith("--")) args.set(process.argv[i].slice(2), process.argv[++i] ?? "1");
const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");
const rowsFile = path.join(outDir, args.get("rows") ?? "new-dev.json");
const variants = (args.get("variants") ?? "current,strict").split(",");
const env: Record<string, string> = {};
for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const manifest = JSON.parse(readFileSync(repo("eval/data/torgo/manifest.json"), "utf8"));
const index = { available: true, name: "TORGO", speakers: manifest.speakers, clips: manifest.clips, results: {} } as DatasetIndex;

interface Row {
  id: string;
  speaker: string;
  kind: string;
  prompt: string;
  heard: Record<string, string>;
  final: string;
}
const rows = (JSON.parse(readFileSync(rowsFile, "utf8")) as { rows: Row[] }).rows;

/** Candidate instructions. "current" is what the server sends now. */
const INSTRUCTIONS: Record<string, string> = {
  current: transcribeInstructions,
  strict: process.env.STRICT_PROMPT ? readFileSync(process.env.STRICT_PROMPT, "utf8") : transcribeInstructions,
};

async function repair(variant: string, row: Row, withPhrases: boolean): Promise<string | null> {
  const hypotheses: Hypothesis[] = (["scribe", "gemini", "gemini4", "realtime"] as HearerName[]).map((hearer) => {
    const text = row.heard[hearer] ?? "";
    return text.startsWith("(") ? { hearer, text: "", seconds: 0, failure: text.slice(1, -1) } : { hearer, text, seconds: 0 };
  });
  if (!row.heard.claude) return null; // the pipeline did not ask Claude: keep its own final text
  const knownWords = withPhrases ? keytermsFrom(setupClipsFor(index, row.speaker).map((c) => c.prompt)).slice(0, 40) : [];
  const input = { hypotheses, phrasebookMatch: null, context: {}, knownWords, purpose: "transcribe" as const, examplesShown: 5 };
  try {
    const answer = await askClaude(env.ANTHROPIC_API_KEY, { instructions: INSTRUCTIONS[variant], input: repairData(input), schema: repairSchema, signal: AbortSignal.timeout(40000), seconds: 40, model: "claude-opus-5-5" });
    return readingFrom(answer, input).text;
  } catch {
    return null;
  }
}

async function main() {
  const table = ["| repair | WER | words | sentences | exact |", "|---|---|---|---|---|"];
  const score = (name: string, finals: Map<string, string>) => {
    const sel = (f: (r: Row) => boolean) => rows.filter(f);
    const wer = (rs: Row[]) => {
      const sum = rs.reduce((a, r) => {
        const c = countErrors(r.prompt, finals.get(r.id) ?? "");
        return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
      }, { errors: 0, referenceWords: 0 });
      return `${(errorRate(sum) * 100).toFixed(1)}%`;
    };
    const exact = rows.filter((r) => sameWords(r.prompt, finals.get(r.id) ?? "")).length / rows.length;
    table.push(`| ${name} | ${wer(rows)} | ${wer(sel((r) => r.kind !== "sentence"))} | ${wer(sel((r) => r.kind === "sentence"))} | ${(exact * 100).toFixed(0)}% |`);
  };
  score("as run", new Map(rows.map((r) => [r.id, r.final])));
  score("Gemini 3.1 Pro alone", new Map(rows.map((r) => [r.id, r.heard.gemini?.startsWith("(") ? "" : r.heard.gemini])));
  const detail: Record<string, Record<string, string>> = {};
  for (const variant of variants) {
    for (const withPhrases of [true, false]) {
      const finals = new Map<string, string>();
      let next = 0;
      await Promise.all(
        Array.from({ length: 6 }, async () => {
          while (next < rows.length) {
            const row = rows[next++];
            finals.set(row.id, (await repair(variant, row, withPhrases)) ?? row.final);
          }
        }),
      );
      const name = `${variant}${withPhrases ? " + known phrases" : ""}`;
      score(name, finals);
      detail[name] = Object.fromEntries(finals);
    }
  }
  console.log(table.join("\n"));
  writeFileSync(path.join(outDir, `repair-${Date.now()}.json`), JSON.stringify({ table, detail }, null, 2));
}
main();
