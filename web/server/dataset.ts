// The local dataset route: lists the TORGO clips on this machine and serves their audio, one
// clip at a time, so the page can play them. Node only (it reads files); `dev.ts` mounts it and
// the hosted app never does.
//
// TORGO must not be redistributed, so three checks keep the audio on this machine:
//   1. Only requests from this machine are answered: the socket address must be loopback, the
//      Host header must name localhost (which also stops a web page on another site from reaching
//      it through DNS tricks), and the address the Vite proxy saw must be loopback too.
//   2. Only clips listed in the manifest are served, by id; a path is never taken from the request.
//   3. The resolved file must sit inside the dataset folder and be a .wav.

import { readFile, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { Hono } from "hono";
import type { DatasetClip, DatasetIndex, DatasetResponse, DatasetResult, DatasetSpeaker } from "../shared/dataset";
import { SHOWN_SETUPS } from "../shared/dataset";

export interface DatasetOptions {
  /** The folder holding manifest.json and the raw/ audio (eval/data/torgo). */
  dataDir: string;
  /** The evaluation's results.json, if any. */
  resultsPath?: string;
}

type Bindings = { REMOTE_ADDRESS?: string };

interface ManifestClip extends DatasetClip {
  audio: string;
}

interface Loaded {
  index: DatasetIndex;
  audioById: Map<string, string>;
}

const loopbackAddresses = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
const localHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
const clipId = /^[A-Za-z0-9-]{1,40}$/;

const missingReason =
  "The TORGO recordings aren't on this computer. Run eval/scripts/fetch_torgo.sh from the repo, then reload. They are about 1 GB.";

/**
 * True when the request came from this machine: the socket address, the Host header, and, when it
 * came through the Vite proxy, the address the proxy saw (`peer`, from `x-understood-peer`). The
 * proxy always connects from this machine, so without `peer` a request from the network that
 * reached Vite (started with --host) would look local.
 */
export function isLocalRequest(remoteAddress: string | undefined, host: string | undefined, peer?: string): boolean {
  if (!remoteAddress || !loopbackAddresses.has(remoteAddress)) return false;
  if (peer !== undefined && !loopbackAddresses.has(peer)) return false;
  if (!host) return false;
  const name = host.startsWith("[") ? host.slice(0, host.indexOf("]") + 1) : host.split(":")[0];
  return localHosts.has(name.toLowerCase());
}

/** The file for a clip's audio path, or null if it would leave the dataset folder or is not a .wav. */
export function safeAudioPath(dataDir: string, relative: string): string | null {
  const root = path.resolve(dataDir);
  const full = path.resolve(root, relative);
  if (!full.startsWith(root + path.sep)) return null;
  if (path.extname(full).toLowerCase() !== ".wav") return null;
  return full;
}

/** Builds the index from the manifest and the evaluation results. Exported for tests. */
export function buildIndex(manifest: unknown, results: unknown): Loaded {
  const m = manifest as { name?: string; clips?: ManifestClip[]; speakers?: Omit<DatasetSpeaker, "clipCount">[] };
  if (!m || !Array.isArray(m.clips)) throw new Error("manifest has no clips");

  const audioById = new Map<string, string>();
  const clips: DatasetClip[] = [];
  const counts = new Map<string, number>();
  for (const c of m.clips) {
    if (typeof c?.id !== "string" || !clipId.test(c.id) || typeof c.audio !== "string") continue;
    audioById.set(c.id, c.audio);
    clips.push({
      id: c.id, speaker: String(c.speaker ?? ""), kind: String(c.kind ?? ""), prompt: String(c.prompt ?? ""),
      seconds: Number(c.seconds) || 0, session: String(c.session ?? ""), split: String(c.split ?? ""),
      ...(c.repeatedLater === true ? { repeatedLater: true } : {}),
    });
    counts.set(c.speaker, (counts.get(c.speaker) ?? 0) + 1);
  }

  const speakers: DatasetSpeaker[] = (m.speakers ?? []).map((s) => ({
    id: String(s.id), group: String(s.group ?? ""), condition: String(s.condition ?? ""), severity: String(s.severity ?? ""),
    clipCount: counts.get(s.id) ?? 0,
  }));

  const byClip: Record<string, DatasetResult[]> = {};
  const r = results as { date?: string; records?: Record<string, unknown>[] } | null;
  for (const rec of r?.records ?? []) {
    const setup = String(rec.setup ?? "");
    if (!(SHOWN_SETUPS as readonly string[]).includes(setup)) continue;
    const id = String(rec.clip ?? "");
    if (!audioById.has(id)) continue;
    const reading = rec.reading as DatasetResult["reading"] | undefined;
    const pb = rec.phrasebookMatch as { heard?: string; meant?: string; timesConfirmed?: number } | undefined;
    (byClip[id] ??= []).push({
      setup,
      decision: String(rec.decision ?? ""),
      finalText: String(rec.finalText ?? ""),
      heard: ((rec.hypotheses as DatasetResult["heard"]) ?? []).map((h) => ({
        hearer: String(h.hearer), text: String(h.text ?? ""), seconds: Number(h.seconds) || 0, ...(h.failure ? { failure: String(h.failure) } : {}),
      })),
      ...(reading ? { reading: { text: String(reading.text ?? ""), confidence: String(reading.confidence ?? ""), alternatives: (reading.alternatives ?? []).map(String), reason: String(reading.reason ?? "") } } : {}),
      ...(pb ? { phrasebook: { heard: String(pb.heard ?? ""), meant: String(pb.meant ?? ""), timesConfirmed: Number(pb.timesConfirmed) || 0 } } : {}),
      seconds: Number(rec.seconds) || 0,
      promptSeen: Boolean(rec.promptSeen),
    });
  }

  return {
    index: { available: true, name: m.name ?? "TORGO", speakers, clips, results: byClip, ...(r?.date ? { resultsDate: String(r.date) } : {}) },
    audioById,
  };
}

/** Parses a single "bytes=start-end" range against a file of `size` bytes. Null when absent or unusable. */
export function parseRange(header: string | undefined, size: number): { start: number; end: number } | null {
  const match = header?.match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (match[1] === "" && match[2] === "")) return null;
  let start: number, end: number;
  if (match[1] === "") {
    const suffix = Number(match[2]);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  }
  if (start > end || start >= size) return null;
  return { start, end };
}

export function createDatasetApp(options: DatasetOptions) {
  const app = new Hono<{ Bindings: Bindings }>();
  let loaded: Loaded | null = null;

  // Loaded on first use and kept. A failure is not kept, so fetching the data and reloading works.
  async function load(): Promise<Loaded | null> {
    if (loaded) return loaded;
    try {
      const manifest = JSON.parse(await readFile(path.join(options.dataDir, "manifest.json"), "utf8"));
      let results: unknown = null;
      if (options.resultsPath) {
        try {
          results = JSON.parse(await readFile(options.resultsPath, "utf8"));
        } catch {
          results = null; // the clips are still worth listing without the evaluation
        }
      }
      loaded = buildIndex(manifest, results);
      return loaded;
    } catch {
      return null;
    }
  }

  app.use("*", async (c, next) => {
    // A request through a tunnel or proxy (Cloudflare adds cf-connecting-ip and cf-ray, others
    // x-forwarded-for) comes from outside even though it reaches us from this machine; and the
    // host the visitor typed (x-understood-host, set by the Vite proxy) must be this machine too.
    const forwarded = ["cf-connecting-ip", "cf-ray", "x-forwarded-for", "forwarded"].some((h) => c.req.header(h) !== undefined);
    const originalHost = c.req.header("x-understood-host");
    if (
      forwarded ||
      (originalHost !== undefined && !isLocalRequest("127.0.0.1", originalHost)) ||
      !isLocalRequest(c.env?.REMOTE_ADDRESS, c.req.header("host"), c.req.header("x-understood-peer"))
    ) {
      return c.json({ error: "The dataset is only available on the computer it is stored on." }, 403);
    }
    await next();
  });

  app.get("/api/dataset", async (c) => {
    const data = await load();
    const body: DatasetResponse = data ? data.index : { available: false, reason: missingReason };
    c.header("cache-control", "no-store");
    return c.json(body);
  });

  app.get("/api/dataset/audio/:id", async (c) => {
    const id = c.req.param("id");
    const data = clipId.test(id) ? await load() : null;
    const relative = data?.audioById.get(id);
    const file = relative ? safeAudioPath(options.dataDir, relative) : null;
    if (!file) return c.json({ error: "No such clip." }, 404);

    let bytes: Buffer;
    try {
      // Follow any symlink, then check again that the real file is inside the real data folder.
      const [real, realRoot] = await Promise.all([realpath(file), realpath(options.dataDir)]);
      if (!real.startsWith(realRoot + path.sep) || !(await stat(real)).isFile()) return c.json({ error: "No such clip." }, 404);
      bytes = await readFile(real);
    } catch {
      return c.json({ error: "That clip's file is missing." }, 404);
    }

    const headers: Record<string, string> = {
      "content-type": "audio/wav",
      "accept-ranges": "bytes",
      "cache-control": "private, max-age=3600",
      "x-content-type-options": "nosniff",
    };
    // Several ranges at once are not supported, so that request gets the whole file (allowed by
    // the HTTP standard); a single range past the end gets 416.
    const rangeHeader = c.req.header("range");
    const range = rangeHeader?.includes(",") ? null : parseRange(rangeHeader, bytes.length);
    if (rangeHeader && !rangeHeader.includes(",") && !range) {
      return new Response(null, { status: 416, headers: { ...headers, "content-range": `bytes */${bytes.length}` } });
    }
    if (range) {
      const part = bytes.subarray(range.start, range.end + 1);
      return new Response(new Uint8Array(part), {
        status: 206,
        headers: { ...headers, "content-range": `bytes ${range.start}-${range.end}/${bytes.length}`, "content-length": String(part.length) },
      });
    }
    return new Response(new Uint8Array(bytes), { status: 200, headers: { ...headers, "content-length": String(bytes.length) } });
  });

  app.all("*", (c) => c.json({ error: "Not found." }, 404));
  return app;
}
