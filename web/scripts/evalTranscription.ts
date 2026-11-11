// Measures transcription accuracy of the website's own pipeline on TORGO, the way the pipeline
// page hears a clip: the speaker's voice is set up from their own enrolment clips (never test
// clips), the clip is heard by Scribe, Gemini and Scribe realtime, then the phrasebook, Claude's
// repair and the decider run, and the page's final text is scored against the prompt with the
// evaluation's word error rate.
//
//   npx tsx scripts/evalTranscription.ts --split dev --tag baseline [--per-speaker 10] [--speakers F01,M05]
//
// Test clips are split once, by a hash of the clip id, into "dev" (used while improving the
// pipeline) and "holdout" (run only at the end, to report). Recogniser answers are cached on disk
// (EVAL_CACHE, default the system temp folder), so changing the repair or the combination does
// not pay for the audio again; a changed request (hints, examples, prompt) is a new cache entry.
// Never prints a key. Audio never leaves this computer except to the recognition services.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { DatasetClip, DatasetIndex } from "../shared/dataset";
import type { PipelineEvent, UnderstandRequest } from "../shared/pipeline";
import { countErrors, errorRate, sameWords, scoringWords } from "../shared/wordErrors";
import { realDeps, type Env } from "../server/app";
import { geminiBody, scribeForm, type HearingRequest } from "../server/hearers";
import { understandTurn, type UnderstandDeps } from "../server/understand";
import { bestText, HEARERS, newTurn, reduceTurn } from "../src/model/turn";
import { setUpSpeaker, type Voice } from "../src/model/voices";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const dataDir = process.env.DATASET_DIR || repo("eval/data/torgo");

// ── arguments ──
const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i++) {
  const key = process.argv[i];
  if (key.startsWith("--")) args.set(key.slice(2), process.argv[i + 1]?.startsWith("--") || process.argv[i + 1] === undefined ? "1" : process.argv[++i]);
}
const split = args.get("split") ?? "dev";
const tag = args.get("tag") ?? "run";
const perSpeaker = Number(args.get("per-speaker") ?? 10);
const onlySpeakers = args.get("speakers")?.split(",");
const concurrency = Number(args.get("concurrency") ?? 4);
const noRealtime = args.has("no-realtime");
const cacheDir = process.env.EVAL_CACHE || path.join(tmpdir(), "understood-eval-cache");
mkdirSync(cacheDir, { recursive: true });

// ── keys, from the repo's .env, never printed ──
function loadEnv(): Env {
  const file: Record<string, string> = {};
  try {
    for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
      if (m) file[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {
    /* only the environment */
  }
  const pick = (name: string) => process.env[name] || file[name] || undefined;
  return { ELEVENLABS_API_KEY: pick("ELEVENLABS_API_KEY"), OPENROUTER_API_KEY: pick("OPENROUTER_API_KEY"), ANTHROPIC_API_KEY: pick("ANTHROPIC_API_KEY") };
}
const env = loadEnv();

// ── the dataset ──
interface ManifestClip extends DatasetClip {
  audio: string;
}
const manifest = JSON.parse(readFileSync(path.join(dataDir, "manifest.json"), "utf8")) as { clips: ManifestClip[]; speakers: DatasetIndex["speakers"] };
const index: DatasetIndex = {
  available: true,
  name: "TORGO",
  speakers: manifest.speakers,
  clips: manifest.clips.map(({ audio: _audio, ...c }) => c),
  results: {},
};
const audioOf = new Map(manifest.clips.map((c) => [c.id, c.audio]));
const wavBase64 = (id: string) => readFileSync(path.join(dataDir, audioOf.get(id)!)).toString("base64");
const hash = (text: string) => createHash("sha256").update(text).digest("hex").slice(0, 24);
const splitOf = (id: string) => (parseInt(hash(`split:${id}`).slice(0, 8), 16) % 2 === 0 ? "dev" : "holdout");

/** Per speaker, up to perSpeaker test clips of this split: sentences and words in proportion, in a fixed order. */
function chosenClips(): DatasetClip[] {
  const out: DatasetClip[] = [];
  const speakers = onlySpeakers ?? manifest.speakers.map((s) => s.id);
  for (const speaker of speakers) {
    const tests = index.clips.filter((c) => c.speaker === speaker && c.split === "test" && splitOf(c.id) === split && c.prompt.trim());
    const ordered = [...tests].sort((a, b) => hash(a.id).localeCompare(hash(b.id)));
    const sentences = ordered.filter((c) => c.kind === "sentence");
    const wordsOnly = ordered.filter((c) => c.kind !== "sentence");
    const nSent = Math.min(sentences.length, Math.round(perSpeaker * 0.4));
    out.push(...sentences.slice(0, nSent), ...wordsOnly.slice(0, perSpeaker - nSent));
  }
  return out;
}

// ── cached recognisers ──
function cached<T>(key: string, make: () => Promise<T>): Promise<T> {
  const file = path.join(cacheDir, `${hash(key)}.json`);
  if (existsSync(file)) {
    const saved = JSON.parse(readFileSync(file, "utf8")) as { ok: boolean; value?: T; error?: string };
    return saved.ok ? Promise.resolve(saved.value as T) : Promise.reject(new Error(saved.error));
  }
  return make().then(
    (value) => (writeFileSync(file, JSON.stringify({ ok: true, value })), value),
    (error: Error) => {
      // Only "heard nothing" is an answer about the clip; timeouts, credit and service errors are
      // about the moment, so they are never cached.
      if (/heard no words|no speech/i.test(error.message)) writeFileSync(file, JSON.stringify({ ok: false, error: error.message }));
      throw error;
    },
  );
}

const real = realDeps(env);
const wavHash = new Map<string, string>();
const keyOf = (name: string, r: HearingRequest, extra: unknown) => {
  let wh = wavHash.get(r.wavBase64);
  if (!wh) wavHash.set(r.wavBase64, (wh = hash(r.wavBase64)));
  return JSON.stringify([name, wh, r.keyterms, r.examples.map((e) => hash(e.wavBase64) + e.text), extra]);
};
const deps: UnderstandDeps = {
  ...real,
  // The Scribe model and options (v2 or v3, no_verbatim) are part of the key.
  hearScribe: (r) => {
    const form = scribeForm({ ...r, wavBase64: "" });
    return cached(keyOf("scribe", r, [form.get("model_id"), form.get("no_verbatim")]), () => real.hearScribe(r));
  },
  // The Gemini request body (instruction, model, example layout) is part of the key.
  hearGemini: (r) => cached(keyOf("gemini", r, hash(JSON.stringify(geminiBody({ ...r, wavBase64: "", examples: r.examples.map((e) => ({ ...e, wavBase64: "" })) })))), () => real.hearGemini(r)),
};

async function* understand(request: UnderstandRequest): AsyncGenerator<PipelineEvent> {
  const events: PipelineEvent[] = [];
  await understandTurn(request, deps, (e) => events.push(e));
  yield* events;
}

// ── Scribe realtime, fed the clip as fast as it accepts it ──
async function realtimeText(id: string): Promise<string> {
  if (noRealtime) return "";
  const realtimeModel = process.env.REALTIME_MODEL || "scribe_v3_live";
  return cached(JSON.stringify(["realtime", id, realtimeModel]), async () => {
    const tokenReply = await fetch("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", { method: "POST", headers: { "xi-api-key": env.ELEVENLABS_API_KEY ?? "" } });
    const { token } = (await tokenReply.json()) as { token: string };
    const params = new URLSearchParams({ model_id: realtimeModel, audio_format: "pcm_16000", commit_strategy: "manual", language_code: "en", token });
    const socket = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${params}`);
    const bytes = readFileSync(path.join(dataDir, audioOf.get(id)!));
    const pcm = bytes.subarray(44);
    const committed: string[] = [];
    let partial = "";
    await new Promise<void>((resolve, reject) => {
      // No final text in 20 s is a failure, not an empty answer: it must not be cached as one.
      const timer = setTimeout(() => reject(new Error("realtime timed out")), 20000);
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
          // auth, quota, rate limits: an error, never cached as an answer
          clearTimeout(timer);
          reject(new Error(`realtime ${type} ${m.error ?? ""}`));
        }
      };
      socket.onopen = async () => {
        // 100 ms pieces, sent at twice real time.
        for (let o = 0; o < pcm.length; o += 3200) {
          socket.send(JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: pcm.subarray(o, o + 3200).toString("base64"), commit: false, sample_rate: 16000 }));
          await new Promise((r) => setTimeout(r, 50));
        }
        socket.send(JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: "", commit: true, sample_rate: 16000 }));
      };
    });
    socket.close();
    return [...committed, partial].filter(Boolean).join(" ").trim();
  });
}

// ── run ──
interface Row {
  id: string;
  speaker: string;
  kind: string;
  prompt: string;
  seen: boolean;
  heard: Record<string, string>;
  final: string;
  decision: string;
  errors: Record<string, { errors: number; referenceWords: number }>;
  seconds: number;
}

async function main() {
  const clips = chosenClips();
  console.log(`${clips.length} ${split} clips from ${new Set(clips.map((c) => c.speaker)).size} speakers; tag ${tag}; cache ${cacheDir}`);
  const voices = new Map<string, Voice>();
  for (const speaker of [...new Set(clips.map((c) => c.speaker))]) {
    const description = manifest.speakers.find((s) => s.id === speaker);
    voices.set(
      speaker,
      await setUpSpeaker(index, speaker, `${speaker} (${description?.severity ?? ""})`, {
        understand,
        loadWav: async (clip) => wavBase64(clip.id),
        onProgress: () => {},
      }),
    );
  }
  const switches = { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true };
  const rows: Row[] = [];
  let next = 0;
  const worker = async () => {
    while (next < clips.length) {
      const clip = clips[next++];
      const voice = voices.get(clip.speaker)!;
      const rt = await realtimeText(clip.id).catch(() => "");
      const request: UnderstandRequest = {
        turnId: clip.id,
        wavBase64: wavBase64(clip.id),
        realtimeText: rt || undefined,
        realtimeKeyterms: [],
        phrasebook: voice.phrasebook,
        examples: voice.examples,
        keyterms: voice.keyterms,
        context: { recentTurns: [] },
        switches,
        purpose: "transcribe",
      };
      const started = Date.now();
      let turn = newTurn({ turnId: clip.id, origin: "file", switches });
      await understandTurn(request, deps, (e) => (turn = reduceTurn(turn, e, 0)));
      const final = turn.failed ? "" : bestText(turn);
      const heard: Record<string, string> = {};
      const errors: Row["errors"] = {};
      for (const h of HEARERS) {
        const lane = turn.lanes[h];
        heard[h] = lane.status === "done" ? (lane.text ?? "") : `(${lane.failure ?? lane.status})`;
        errors[h] = countErrors(clip.prompt, lane.status === "done" ? (lane.text ?? "") : "");
      }
      if (turn.repair.reading) heard.claude = turn.repair.reading.text;
      if (turn.match) heard.phrasebook = `${turn.match.heard} -> ${turn.match.meant}${turn.match.strong ? " (strong)" : ""}`;
      errors.final = countErrors(clip.prompt, final);
      const seen = voice.setupPrompts.includes(scoringWords(clip.prompt).join(" "));
      rows.push({ id: clip.id, speaker: clip.speaker, kind: clip.kind, prompt: clip.prompt, seen, heard, final, decision: turn.decision?.decision.kind ?? "failed", errors, seconds: (Date.now() - started) / 1000 });
      process.stdout.write(sameWords(clip.prompt, final) ? "." : "x");
    }
  };
  await Promise.all(Array.from({ length: concurrency }, worker));
  console.log("");

  // ── summary ──
  const groups: Record<string, (r: Row) => boolean> = {
    all: () => true,
    words: (r) => r.kind !== "sentence",
    sentences: (r) => r.kind === "sentence",
    dysarthric: (r) => manifest.speakers.find((s) => s.id === r.speaker)?.group === "dysarthric",
    control: (r) => manifest.speakers.find((s) => s.id === r.speaker)?.group !== "dysarthric",
  };
  const columns = ["scribe", "gemini", "realtime", "final"];
  const lines = [`| ${tag} (${split}) | n | ${columns.join(" WER | ")} WER | final exact |`, `|---|---|${columns.map(() => "---|").join("")}---|`];
  for (const [name, test] of Object.entries(groups)) {
    const rs = rows.filter(test);
    if (!rs.length) continue;
    const wer = (col: string) => {
      const sum = rs.reduce((a, r) => ({ errors: a.errors + r.errors[col].errors, referenceWords: a.referenceWords + r.errors[col].referenceWords }), { errors: 0, referenceWords: 0 });
      return `${(errorRate(sum) * 100).toFixed(1)}%`;
    };
    const exact = rs.filter((r) => sameWords(r.prompt, r.final)).length / rs.length;
    lines.push(`| ${name} | ${rs.length} | ${columns.map(wer).join(" | ")} | ${(exact * 100).toFixed(0)}% |`);
  }
  console.log(lines.join("\n"));
  const outDir = process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out");
  mkdirSync(outDir, { recursive: true });
  const out = path.join(outDir, `${tag}-${split}.json`);
  writeFileSync(out, JSON.stringify({ tag, split, date: new Date().toISOString(), summary: lines, rows }, null, 2));
  console.log(`Rows: ${out}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
