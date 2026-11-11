// Compares dedicated speech recognisers on the same TORGO dev clips, with no hints: ElevenLabs
// Scribe (v2, v3, v3 with no_verbatim) called directly, and the transcription models OpenRouter
// serves on /api/v1/audio/transcriptions. Scored with the evaluation's word error rate; answers
// are cached.
//
//   npx tsx scripts/compareRecognisers.ts --per-speaker 6 [--models a,b] [--split dev]

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { countErrors, errorRate, sameWords } from "../shared/wordErrors";
import { acceptedKeyterms } from "../shared/rules/turn";
import { keytermsFrom } from "../src/model/voices";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const dataDir = repo("eval/data/torgo");
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) if (process.argv[i].startsWith("--")) args.set(process.argv[i].slice(2), process.argv[++i] ?? "1");
const perSpeaker = Number(args.get("per-speaker") ?? 6);
const split = args.get("split") ?? "dev";
const DEFAULT = [
  "scribe:scribe_v2",
  "scribe:scribe_v3",
  "scribe:scribe_v3:no_verbatim",
  "openai/gpt-transcribe",
  "openai/gpt-4o-transcribe",
  "google/gemini-3.5-transcribe",
  "google/chirp-3",
  "assemblyai/universal-3-6-pro",
  "deepgram/nova-3",
  "mistralai/voxtral-small-transcribe-3-0",
  "x-ai/grok-stt-2.0",
  "nvidia/nemotron-3.5-transcribe",
  "meta/muse-voice-transcribe-1.0",
  "openai/whisper-large-v3",
];
const models = args.get("models")?.split(",") ?? DEFAULT;
const cacheDir = process.env.EVAL_CACHE || path.join(tmpdir(), "understood-eval-cache");
mkdirSync(cacheDir, { recursive: true });

const env: Record<string, string> = {};
for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}

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

function clipsFor(speaker: string): Clip[] {
  const tests = manifest.clips.filter((c) => c.speaker === speaker && c.split === "test" && splitOf(c.id) === split).sort((a, b) => hash(a.id).localeCompare(hash(b.id)));
  const s = tests.filter((c) => c.kind === "sentence");
  const w = tests.filter((c) => c.kind !== "sentence");
  const nS = Math.min(s.length, Math.round(perSpeaker * 0.4));
  return [...s.slice(0, nS), ...w.slice(0, perSpeaker - nS)];
}

/** The speaker's set-up prompts, as the page's voice setup gives them to Scribe. */
function hintsFor(speaker: string): string[] {
  const enrol = manifest.clips.filter((c) => c.speaker === speaker && c.split === "enrolment");
  const chosen = [...enrol.filter((c) => c.repeatedLater), ...enrol.filter((c) => !c.repeatedLater)].slice(0, 20);
  return keytermsFrom(chosen.map((c) => c.prompt));
}

/** Scribe realtime, fed the clip at twice real time, as the page streams a recording. */
async function realtime(modelId: string, bytes: Buffer): Promise<string> {
  const tokenReply = await fetch("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", { method: "POST", headers: { "xi-api-key": env.ELEVENLABS_API_KEY } });
  const { token } = (await tokenReply.json()) as { token: string };
  const params = new URLSearchParams({ model_id: modelId, audio_format: "pcm_16000", commit_strategy: "manual", language_code: "en", token });
  const socket = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${params}`);
  const pcm = bytes.subarray(44);
  const committed: string[] = [];
  let partial = "";
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => resolve(), 20000);
    socket.onerror = () => reject(new Error("realtime socket error"));
    socket.onmessage = (event) => {
      const m = JSON.parse(String(event.data)) as { message_type?: string; text?: string; error?: string };
      const type = m.message_type ?? "";
      if (type === "partial_transcript") partial = m.text ?? "";
      else if (type.startsWith("committed_transcript") || type.startsWith("final_transcript")) {
        if (m.text?.trim()) committed.push(m.text.trim());
        partial = "";
        clearTimeout(timer);
        resolve();
      } else if (!["session_started", "edited_transcript"].includes(type)) {
        clearTimeout(timer);
        reject(new Error(`${type} ${m.error ?? ""}`));
      }
    };
    socket.onopen = async () => {
      for (let o = 0; o < pcm.length; o += 3200) {
        socket.send(JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: pcm.subarray(o, o + 3200).toString("base64"), commit: false, sample_rate: 16000 }));
        await new Promise((r) => setTimeout(r, 50));
      }
      socket.send(JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: "", commit: true, sample_rate: 16000 }));
    };
  });
  socket.close();
  return [...committed, partial].filter(Boolean).join(" ").trim();
}

async function transcribe(model: string, clip: Clip): Promise<{ text: string; ms: number }> {
  const file = path.join(cacheDir, `${hash(JSON.stringify(["recogniser", model, clip.id]))}.json`);
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8"));
  const bytes = readFileSync(path.join(dataDir, clip.audio));
  const started = Date.now();
  let text = "";
  try {
    if (model.startsWith("realtime:")) {
      text = await realtime(model.slice(9), bytes);
    } else if (model.startsWith("scribe:")) {
      const [, id, option] = model.split(":");
      const form = new FormData();
      form.append("model_id", id);
      form.append("language_code", "en");
      form.append("tag_audio_events", "false");
      form.append("timestamps_granularity", "none");
      if (model.includes("no_verbatim")) form.append("no_verbatim", "true");
      // "keyterms": the speaker's set-up prompts as hints, as the page sends them.
      if (model.endsWith(":keyterms")) for (const t of acceptedKeyterms(hintsFor(clip.speaker))) form.append("keyterms", t);
      form.append("file", new Blob([bytes]), "clip.wav");
      const r = await fetch("https://api.elevenlabs.io/v1/speech-to-text", { method: "POST", headers: { "xi-api-key": env.ELEVENLABS_API_KEY }, body: form, signal: AbortSignal.timeout(60000) });
      const j = (await r.json()) as { text?: string; detail?: unknown };
      if (!r.ok) throw new Error(`${r.status} ${JSON.stringify(j.detail ?? j).slice(0, 160)}`);
      text = (j.text ?? "").trim();
    } else {
      const r = await fetch("https://openrouter.ai/api/v1/audio/transcriptions", {
        method: "POST",
        headers: { Authorization: `Bearer ${env.OPENROUTER_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model, input_audio: { data: bytes.toString("base64"), format: "wav" }, language: "en", temperature: 0 }),
        signal: AbortSignal.timeout(60000),
      });
      const j = (await r.json().catch(() => ({}))) as { text?: string; error?: { message?: string } };
      if (!r.ok) throw new Error(`${r.status} ${j.error?.message ?? ""}`.slice(0, 200));
      text = (j.text ?? "").trim();
    }
  } catch (error) {
    const result = { text: `(error: ${(error as Error).message})`, ms: Date.now() - started };
    // Failures (credit, rate, service) are about the moment, not the clip: never cached.
    return result;
  }
  const result = { text, ms: Date.now() - started };
  writeFileSync(file, JSON.stringify(result));
  return result;
}

async function main() {
  const clips = manifest.speakers.flatMap((s) => clipsFor(s.id));
  console.log(`${clips.length} ${split} clips, ${models.length} recognisers`);
  const table = ["| recogniser | n | WER | words | sentences | dysarthric | control | exact | median s |", "|---|---|---|---|---|---|---|---|---|"];
  const detail: Record<string, unknown> = {};
  // One model at a time: OpenRouter reserves credit per request in flight.
  for (const model of models) {
    await (async () => {
      const rows: { clip: Clip; text: string; ms: number }[] = [];
      let next = 0;
      await Promise.all(
        Array.from({ length: 4 }, async () => {
          while (next < clips.length) {
            const clip = clips[next++];
            rows.push({ clip, ...(await transcribe(model, clip)) });
          }
        }),
      );
      const errors = rows.filter((r) => r.text.startsWith("(error")).length;
      const wer = (rs: typeof rows) => {
        const sum = rs.reduce((a, r) => {
          const c = countErrors(r.clip.prompt, r.text.startsWith("(error") ? "" : r.text);
          return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
        }, { errors: 0, referenceWords: 0 });
        return rs.length ? `${(errorRate(sum) * 100).toFixed(1)}%` : "–";
      };
      const dys = (r: (typeof rows)[0]) => manifest.speakers.find((s) => s.id === r.clip.speaker)?.group === "dysarthric";
      const ms = rows.map((r) => r.ms).sort((a, b) => a - b);
      table.push(
        `| ${model} | ${rows.length}${errors ? ` (${errors} failed)` : ""} | ${wer(rows)} | ${wer(rows.filter((r) => r.clip.kind !== "sentence"))} | ${wer(rows.filter((r) => r.clip.kind === "sentence"))} | ${wer(rows.filter(dys))} | ${wer(rows.filter((r) => !dys(r)))} | ${((rows.filter((r) => sameWords(r.clip.prompt, r.text)).length / rows.length) * 100).toFixed(0)}% | ${(ms[ms.length >> 1] / 1000).toFixed(1)} |`,
      );
      detail[model] = rows.map((r) => ({ id: r.clip.id, prompt: r.clip.prompt, text: r.text }));
      if (errors) console.log(`${model}: ${rows.find((r) => r.text.startsWith("(error"))?.text}`);
    })();
  }
  const [head, rule, ...body] = table;
  body.sort((a, b) => parseFloat(a.split("|")[3]) - parseFloat(b.split("|")[3]));
  console.log([head, rule, ...body].join("\n"));
  const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, `recognisers-${split}-${Date.now()}.json`), JSON.stringify({ table: [head, rule, ...body], detail }, null, 2));
}
main();
