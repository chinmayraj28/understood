// The local research route: the TORGO clips used to fine-tune a speech model, with what the
// untuned and the tuned model wrote for each, and a way to have the tuned model (running on this
// computer as train/serve.py) hear a clip now. Node only (it reads files); `dev.ts` mounts it and
// the hosted app never does.
//
// TORGO text and audio must not leave this machine, so the same local-only checks as the dataset
// route apply, and nothing from the request ever becomes a path: a clip id is only looked up in
// the list read from clips.jsonl, and its audio comes from `audioFor`, which looks it up in the
// dataset's manifest.

import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import type {
  ResearchClip,
  ResearchClipsResponse,
  ResearchStatus,
  ResearchTranscribeRequest,
  ResearchTranscribeResponse,
} from "../shared/research";
import { RESEARCH_MODEL_URL } from "../shared/research";
import { isLocalRequest } from "./dataset";

export interface ResearchOptions {
  /** train/data/clips.jsonl: every clip with its role in the fine-tuning. */
  clipsPath: string;
  /** train/runs: one folder per training or scoring run, holding predictions-*.jsonl files. */
  runsDir: string;
  /** A clip's WAV bytes by id (wired in dev.ts to the dataset's manifest), or null if not here. */
  audioFor: (id: string) => Promise<Buffer | null>;
  /** The local model service; tests point it at a fake. */
  modelUrl?: string;
  /** Used for every call to the model service, so tests need no network. */
  fetch?: typeof fetch;
}

type Bindings = { REMOTE_ADDRESS?: string };

/** What the untuned and the tuned Whisper wrote, per run. Any of these may be missing. */
const untunedFiles = ["base-whisper/predictions-dev-val.jsonl", "final-untuned-whisper/predictions-holdout.jsonl"];
const tunedFiles = ["whisper-s2/predictions-dev.jsonl", "final-tuned-whisper-s2/predictions-holdout.jsonl"];

// The same rule for clip ids as the dataset route, so an id can never carry a path.
const clipId = /^[A-Za-z0-9-]{1,40}$/;
const roles = new Set<ResearchClip["role"]>(["train", "val", "dev", "holdout"]);

const missingReason = "The fine-tuning results aren't on this computer.";
const notRunning = "The tuned model isn't running on this computer. Start it with: cd train && uv run python serve.py";
const healthMs = 800;
const transcribeMs = 30_000;

/** Reads a JSON-lines file into objects; blank and broken lines are skipped. Null when missing. */
async function readJsonLines(file: string): Promise<Record<string, unknown>[] | null> {
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch {
    return null;
  }
  const rows: Record<string, unknown>[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const value = JSON.parse(line);
      if (value && typeof value === "object" && !Array.isArray(value)) rows.push(value);
    } catch {
      // One bad line should not hide the other few thousand.
    }
  }
  return rows;
}

/** A clip from one line of clips.jsonl, or null if the line can't be trusted. The FLAC path is dropped. */
function toClip(row: Record<string, unknown>): ResearchClip | null {
  const id = row.id;
  const role = row.role as ResearchClip["role"];
  if (typeof id !== "string" || !clipId.test(id) || !roles.has(role)) return null;
  return {
    id,
    speaker: String(row.speaker ?? ""),
    kind: String(row.kind ?? ""),
    prompt: String(row.prompt ?? ""),
    seconds: Number(row.seconds) || 0,
    role,
    seen: row.seen === true,
    dysarthric: row.dysarthric === true,
  };
}

/** Builds the clip list from clips.jsonl and the prediction files' rows. Exported for tests. */
export function mergeClips(
  clipRows: Record<string, unknown>[],
  untuned: (Record<string, unknown>[] | null)[],
  tuned: (Record<string, unknown>[] | null)[],
): ResearchClip[] {
  const byId = new Map<string, ResearchClip>();
  for (const row of clipRows) {
    const clip = toClip(row);
    if (clip && !byId.has(clip.id)) byId.set(clip.id, clip);
  }
  const fill = (files: (Record<string, unknown>[] | null)[], field: "untuned" | "tuned") => {
    for (const rows of files) {
      for (const row of rows ?? []) {
        const clip = typeof row.id === "string" ? byId.get(row.id) : undefined;
        if (clip && typeof row.heard === "string") clip[field] = row.heard;
      }
    }
  };
  fill(untuned, "untuned");
  fill(tuned, "tuned");
  return [...byId.values()];
}

/** A file's modification time, or -1 when it isn't there; used to notice new results. */
async function mtimeOf(file: string): Promise<number> {
  try {
    return (await stat(file)).mtimeMs;
  } catch {
    return -1;
  }
}

/** True for base64 text whose bytes start like a WAV file ("RIFF", size, "WAVE"). */
export function isWavBase64(value: string): boolean {
  if (value.length < 16 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  // Only the first 12 bytes are needed: 16 base64 characters.
  const head = Buffer.from(value.slice(0, 16), "base64");
  return head.subarray(0, 4).toString("latin1") === "RIFF" && head.subarray(8, 12).toString("latin1") === "WAVE";
}

export function createResearchApp(options: ResearchOptions) {
  const app = new Hono<{ Bindings: Bindings }>();
  const modelUrl = (options.modelUrl ?? RESEARCH_MODEL_URL).replace(/\/+$/, "");
  const doFetch = options.fetch ?? fetch;
  const sources = [options.clipsPath, ...[...untunedFiles, ...tunedFiles].map((f) => path.join(options.runsDir, f))];

  // The parsed list is kept until any source file changes (or appears, or goes), so copying new
  // results from Colab shows up on the next reload without restarting the server.
  let cache: { stamp: string; clips: ResearchClip[] | null; byId: Map<string, ResearchClip> } | null = null;

  async function load() {
    const stamp = (await Promise.all(sources.map(mtimeOf))).join(",");
    if (cache && cache.stamp === stamp) return cache;
    const [clipRows, ...predictions] = await Promise.all(sources.map(readJsonLines));
    const clips = clipRows ? mergeClips(clipRows, predictions.slice(0, untunedFiles.length), predictions.slice(untunedFiles.length)) : null;
    cache = { stamp, clips, byId: new Map((clips ?? []).map((c) => [c.id, c])) };
    return cache;
  }

  app.use("*", async (c, next) => {
    // The same checks as the dataset route: no tunnel or proxy headers, the host the visitor typed
    // is this machine, and the socket and the Vite proxy's peer are both loopback.
    const forwarded = ["cf-connecting-ip", "cf-ray", "x-forwarded-for", "forwarded"].some((h) => c.req.header(h) !== undefined);
    const originalHost = c.req.header("x-understood-host");
    if (
      forwarded ||
      (originalHost !== undefined && !isLocalRequest("127.0.0.1", originalHost)) ||
      !isLocalRequest(c.env?.REMOTE_ADDRESS, c.req.header("host"), c.req.header("x-understood-peer"))
    ) {
      return c.json({ error: "The research data is only available on the computer it is stored on." }, 403);
    }
    c.header("cache-control", "no-store");
    await next();
  });

  app.get("/api/research/status", async (c) => {
    const [clipsTime, ...tunedTimes] = await Promise.all(
      [options.clipsPath, ...tunedFiles.map((f) => path.join(options.runsDir, f))].map(mtimeOf),
    );
    const status: ResearchStatus = { saved: clipsTime >= 0 && tunedTimes.some((t) => t >= 0), live: false };
    try {
      const response = await doFetch(`${modelUrl}/health`, { signal: AbortSignal.timeout(healthMs) });
      if (response.ok) {
        const body = (await response.json().catch(() => null)) as { ok?: unknown; model?: unknown } | null;
        // A reply that says ok: false is a service that is up but not ready to hear anything.
        if (body?.ok !== false) {
          status.live = true;
          if (typeof body?.model === "string") status.model = body.model.slice(0, 200);
        }
      }
    } catch {
      // Not running, or too slow: the page shows the saved results only.
    }
    return c.json(status);
  });

  app.get("/api/research/clips", async (c) => {
    const { clips } = await load();
    const body: ResearchClipsResponse = clips ? { available: true, clips } : { available: false, reason: missingReason };
    return c.json(body);
  });

  const tooBig = (c: Context) => c.json({ error: "That recording is too large. Keep it under 4 MB." }, 413);

  app.post("/api/research/transcribe", bodyLimit({ maxSize: 4 * 1024 * 1024, onError: tooBig }), async (c) => {
    const request = (await c.req.json().catch(() => null)) as ResearchTranscribeRequest | null;
    if (!request || typeof request !== "object" || Array.isArray(request)) return c.json({ error: "Send a clip id or a recording." }, 400);
    const { clipId: id, wavBase64 } = request;
    const hasId = id !== undefined && id !== null;
    const hasWav = wavBase64 !== undefined && wavBase64 !== null;
    if (hasId === hasWav) return c.json({ error: "Send either a clip id or a recording, not both." }, 400);

    let audio: string;
    let speaker: string | null;
    if (hasId) {
      const clip = typeof id === "string" && clipId.test(id) ? (await load()).byId.get(id) : undefined;
      if (!clip) return c.json({ error: "No such clip." }, 404);
      const bytes = await options.audioFor(clip.id);
      if (!bytes) return c.json({ error: "That clip's recording isn't on this computer." }, 404);
      audio = bytes.toString("base64");
      speaker = clip.speaker;
    } else {
      if (typeof wavBase64 !== "string" || !isWavBase64(wavBase64)) return c.json({ error: "That recording isn't a WAV file." }, 400);
      audio = wavBase64;
      speaker = null; // heard by the model tuned on all speakers together
    }

    let response: Response;
    try {
      response = await doFetch(`${modelUrl}/transcribe`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ wavBase64: audio, speaker }),
        signal: AbortSignal.timeout(transcribeMs),
      });
    } catch (error) {
      const name = (error as { name?: string })?.name;
      if (name === "TimeoutError" || name === "AbortError") return c.json({ error: "The tuned model took too long to answer." }, 502);
      return c.json({ error: notRunning }, 503);
    }

    const reply = (await response.json().catch(() => null)) as Record<string, unknown> | null;
    if (response.status === 400) {
      // The service's own words about what was wrong with the audio (FastAPI calls it "detail").
      const message = reply?.error ?? reply?.detail;
      return c.json({ error: typeof message === "string" && message.trim() ? message.slice(0, 300) : "The tuned model couldn't use that recording." }, 400);
    }
    if (!response.ok) return c.json({ error: "The tuned model had a problem hearing that recording." }, 502);
    if (typeof reply?.text !== "string") return c.json({ error: "The tuned model gave an answer I didn't expect." }, 502);
    const body: ResearchTranscribeResponse = {
      text: reply.text,
      seconds: Number(reply.seconds) || 0,
      voice: typeof reply.voice === "string" ? reply.voice : speaker ?? "all speakers",
    };
    return c.json(body);
  });

  app.all("*", (c) => c.json({ error: "Not found." }, 404));
  return app;
}
