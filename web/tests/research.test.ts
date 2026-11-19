// The local research route: TORGO text and audio stay on this machine, so these check it only
// answers this machine, merges what the models wrote into the clip list, and talks to the local
// model service (faked here: no network) with the right audio and speaker.
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { ResearchClipsResponse, ResearchStatus, ResearchTranscribeResponse } from "../shared/research";
import { createResearchApp, isWavBase64, mergeClips, type ResearchOptions } from "../server/research";

let root: string;
let clipsPath: string;
let runsDir: string;
const wav = Buffer.from("RIFF\x24\x00\x00\x00WAVEfmt fake audio bytes for the test", "latin1");
const wavBase64 = wav.toString("base64");

const clipLines = [
  { id: "F01-S1-0001", speaker: "F01", kind: "word", prompt: "stick", seconds: 1.8, role: "train", seen: true, dysarthric: true, audio: "F01/F01-S1-0001.flac" },
  { id: "F01-S1-0002", speaker: "F01", kind: "word", prompt: "meat", seconds: 1.1, role: "dev", seen: false, dysarthric: true, audio: "F01/F01-S1-0002.flac" },
  { id: "M02-S2-0003", speaker: "M02", kind: "sentence", prompt: "The quick brown fox.", seconds: 4, role: "holdout", seen: false, dysarthric: true, audio: "x.flac" },
  { id: "FC01-S1-0004", speaker: "FC01", kind: "word", prompt: "yes", seconds: 1, role: "val", seen: true, dysarthric: false, audio: "y.flac" },
];

function writeLines(file: string, rows: unknown[], extra = "") {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, rows.map((r) => JSON.stringify(r)).join("\n") + "\n" + extra);
}

beforeAll(() => {
  root = mkdtempSync(path.join(tmpdir(), "research-test-"));
  clipsPath = path.join(root, "data", "clips.jsonl");
  runsDir = path.join(root, "runs");
  // A broken line and a clip with an unsafe id must be skipped, not stop the rest.
  writeLines(clipsPath, [...clipLines, { id: "../etc", role: "train" }, { id: "BAD-ROLE", role: "test" }], "{not json\n");
  writeLines(path.join(runsDir, "base-whisper", "predictions-dev-val.jsonl"), [
    { id: "F01-S1-0002", speaker: "F01", role: "dev", seen: false, prompt: "meat", heard: "Neat." },
    { id: "FC01-S1-0004", speaker: "FC01", role: "val", seen: true, prompt: "yes", heard: "Yes." },
    { id: "NOT-A-CLIP", heard: "ignored" },
  ], "oops\n");
  writeLines(path.join(runsDir, "final-untuned-whisper", "predictions-holdout.jsonl"), [
    { id: "M02-S2-0003", heard: "The quick brown socks." },
  ]);
  writeLines(path.join(runsDir, "whisper-s2", "predictions-dev.jsonl"), [{ id: "F01-S1-0002", heard: "meat" }]);
  // final-tuned-whisper-s2 is left missing on purpose.
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

interface Call {
  url: string;
  body?: { wavBase64: string; speaker: string | null };
}

/** A fake model service: answers /health and /transcribe as told, and records each call. */
function fakeService(behaviour: { health?: "up" | "down" | "not-ready"; transcribe?: (body: Call["body"]) => Response | Promise<Response> } = {}) {
  const calls: Call[] = [];
  const fake: typeof fetch = async (input, init) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ url, body });
    if (url.endsWith("/health")) {
      if (behaviour.health === "down" || behaviour.health === undefined) throw new TypeError("fetch failed");
      return Response.json(behaviour.health === "up" ? { ok: true, model: "openai/whisper-large-v3-turbo, tuned" } : { ok: false });
    }
    if (url.endsWith("/transcribe") && behaviour.transcribe) return behaviour.transcribe(body);
    throw new TypeError("fetch failed");
  };
  return { fake, calls };
}

const audioStore = new Map([["F01-S1-0002", wav]]);
function makeApp(overrides: Partial<ResearchOptions> = {}) {
  return createResearchApp({
    clipsPath,
    runsDir,
    audioFor: async (id) => audioStore.get(id) ?? null,
    modelUrl: "http://model.test",
    fetch: fakeService().fake,
    ...overrides,
  });
}

const local = { REMOTE_ADDRESS: "127.0.0.1" };
type App = ReturnType<typeof createResearchApp>;
const get = (app: App, url: string, headers: Record<string, string> = {}, env = local) =>
  app.request(url, { headers: { host: "localhost:5173", ...headers } }, env);
const post = (app: App, body: unknown, headers: Record<string, string> = {}, env = local) =>
  app.request(
    "/api/research/transcribe",
    { method: "POST", headers: { host: "localhost:5173", "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) },
    env,
  );

describe("only this machine is answered", () => {
  const routes: [string, (app: App, headers?: Record<string, string>, env?: typeof local) => Response | Promise<Response>][] = [
    ["status", (app, h, e) => get(app, "/api/research/status", h, e)],
    ["clips", (app, h, e) => get(app, "/api/research/clips", h, e)],
    ["transcribe", (app, h, e) => post(app, { clipId: "F01-S1-0002" }, h, e)],
  ];

  for (const [name, call] of routes) {
    it(`refuses ${name} from another machine, a foreign Host, a network peer, or a tunnel host`, async () => {
      const { fake, calls } = fakeService({ health: "up", transcribe: () => Response.json({ text: "x", seconds: 1, voice: "F01" }) });
      const app = makeApp({ fetch: fake });
      expect((await call(app, {}, { REMOTE_ADDRESS: "10.0.0.5" })).status).toBe(403);
      expect((await call(app, { host: "rebind.example:5173" })).status).toBe(403);
      expect((await call(app, { "x-understood-peer": "192.168.1.20" })).status).toBe(403);
      expect((await call(app, { "x-understood-host": "demo.trycloudflare.com" })).status).toBe(403);
      expect((await call(app, { "cf-connecting-ip": "1.2.3.4" })).status).toBe(403);
      const refused = await call(app, {}, { REMOTE_ADDRESS: "10.0.0.5" });
      expect(await refused.json()).toEqual({ error: expect.stringContaining("only available on the computer") });
      // Nothing reached the model service from a refused request.
      expect(calls).toHaveLength(0);
      expect((await call(app, { "x-understood-peer": "::1", "x-understood-host": "localhost:5173" })).status).toBe(200);
    });
  }
});

describe("GET /api/research/status", () => {
  it("is saved and live when the results are here and the service answers", async () => {
    const { fake, calls } = fakeService({ health: "up" });
    const body = (await (await get(makeApp({ fetch: fake }), "/api/research/status")).json()) as ResearchStatus;
    expect(body).toEqual({ saved: true, live: true, model: "openai/whisper-large-v3-turbo, tuned" });
    expect(calls[0].url).toBe("http://model.test/health");
  });

  it("is not live when the service is down or not ready, and never fails", async () => {
    for (const health of ["down", "not-ready"] as const) {
      const response = await get(makeApp({ fetch: fakeService({ health }).fake }), "/api/research/status");
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ saved: true, live: false });
    }
  });

  it("is not live when the service is too slow", async () => {
    const slow: typeof fetch = (_input, init) =>
      new Promise((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal?.reason)));
    expect(await (await get(makeApp({ fetch: slow }), "/api/research/status")).json()).toEqual({ saved: true, live: false });
  });

  it("is not saved without clips.jsonl, or without any tuned predictions", async () => {
    const noClips = makeApp({ clipsPath: path.join(root, "nowhere.jsonl") });
    expect(((await (await get(noClips, "/api/research/status")).json()) as ResearchStatus).saved).toBe(false);
    const emptyRuns = path.join(root, "empty-runs");
    writeLines(path.join(emptyRuns, "base-whisper", "predictions-dev-val.jsonl"), [{ id: "F01-S1-0002", heard: "x" }]);
    const noTuned = makeApp({ runsDir: emptyRuns });
    expect(((await (await get(noTuned, "/api/research/status")).json()) as ResearchStatus).saved).toBe(false);
  });
});

describe("GET /api/research/clips", () => {
  it("lists every good clip with what each model wrote, where it was scored", async () => {
    const response = await get(makeApp(), "/api/research/clips");
    expect(response.status).toBe(200);
    const body = (await response.json()) as ResearchClipsResponse;
    if (!body.available) throw new Error("expected clips");
    expect(body.clips.map((c) => c.id)).toEqual(["F01-S1-0001", "F01-S1-0002", "M02-S2-0003", "FC01-S1-0004"]);
    const byId = Object.fromEntries(body.clips.map((c) => [c.id, c]));
    expect(byId["F01-S1-0001"]).toEqual({ id: "F01-S1-0001", speaker: "F01", kind: "word", prompt: "stick", seconds: 1.8, role: "train", seen: true, dysarthric: true });
    expect(byId["F01-S1-0002"]).toMatchObject({ untuned: "Neat.", tuned: "meat" });
    expect(byId["M02-S2-0003"].untuned).toBe("The quick brown socks.");
    expect(byId["M02-S2-0003"].tuned).toBeUndefined(); // its tuned file is missing
    expect(byId["FC01-S1-0004"]).toMatchObject({ untuned: "Yes.", dysarthric: false });
  });

  it("never sends a file path to the page", async () => {
    const text = await (await get(makeApp(), "/api/research/clips")).text();
    expect(text).not.toContain(".flac");
    expect(text).not.toContain(root);
  });

  it("works with no prediction files at all", async () => {
    const body = (await (await get(makeApp({ runsDir: path.join(root, "no-runs") }), "/api/research/clips")).json()) as ResearchClipsResponse;
    if (!body.available) throw new Error("expected clips");
    expect(body.clips.every((c) => c.untuned === undefined && c.tuned === undefined)).toBe(true);
  });

  it("says the results aren't here when clips.jsonl is missing", async () => {
    const body = await (await get(makeApp({ clipsPath: path.join(root, "nowhere.jsonl") }), "/api/research/clips")).json();
    expect(body).toEqual({ available: false, reason: "The fine-tuning results aren't on this computer." });
  });

  it("re-reads when a results file changes", async () => {
    const runs = path.join(root, "changing-runs");
    const tunedFile = path.join(runs, "final-tuned-whisper-s2", "predictions-holdout.jsonl");
    writeLines(tunedFile, [{ id: "M02-S2-0003", heard: "first" }]);
    const app = makeApp({ runsDir: runs });
    const tunedOf = async () => {
      const body = (await (await get(app, "/api/research/clips")).json()) as ResearchClipsResponse;
      return body.available ? body.clips.find((c) => c.id === "M02-S2-0003")?.tuned : undefined;
    };
    expect(await tunedOf()).toBe("first");
    writeLines(tunedFile, [{ id: "M02-S2-0003", heard: "second" }]);
    const later = new Date(Date.now() + 5000);
    utimesSync(tunedFile, later, later);
    expect(await tunedOf()).toBe("second");
  });

  it("mergeClips skips bad rows and non-text predictions", () => {
    const clips = mergeClips(
      [{ id: "A-1", role: "dev" }, { id: "A 2", role: "dev" }, { id: "A-3", role: "nope" }, { id: 5, role: "dev" }],
      [[{ id: "A-1", heard: 42 }], null],
      [[{ id: "A-1", heard: "a" }]],
    );
    expect(clips).toEqual([{ id: "A-1", speaker: "", kind: "", prompt: "", seconds: 0, role: "dev", seen: false, dysarthric: false, tuned: "a" }]);
  });
});

describe("POST /api/research/transcribe", () => {
  const answer = () => Response.json({ text: "meat", seconds: 0.4, voice: "F01" });

  it("sends a TORGO clip's audio with its speaker, and returns what the model heard", async () => {
    const { fake, calls } = fakeService({ transcribe: answer });
    const response = await post(makeApp({ fetch: fake }), { clipId: "F01-S1-0002" });
    expect(response.status).toBe(200);
    expect((await response.json()) as ResearchTranscribeResponse).toEqual({ text: "meat", seconds: 0.4, voice: "F01" });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("http://model.test/transcribe");
    expect(calls[0].body).toEqual({ wavBase64, speaker: "F01" });
  });

  it("sends an uploaded WAV with no speaker", async () => {
    const { fake, calls } = fakeService({ transcribe: () => Response.json({ text: "hello", seconds: 1.2, voice: "all speakers" }) });
    const response = await post(makeApp({ fetch: fake }), { wavBase64 });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello", seconds: 1.2, voice: "all speakers" });
    expect(calls[0].body).toEqual({ wavBase64, speaker: null });
  });

  it("needs exactly one of clipId and wavBase64", async () => {
    const { fake, calls } = fakeService({ transcribe: answer });
    const app = makeApp({ fetch: fake });
    expect((await post(app, { clipId: "F01-S1-0002", wavBase64 })).status).toBe(400);
    expect((await post(app, {})).status).toBe(400);
    expect((await post(app, "not json")).status).toBe(400);
    expect((await post(app, [1, 2])).status).toBe(400);
    expect(calls).toHaveLength(0);
  });

  it("answers 404 for an unknown or odd clip id, and for a clip whose audio is missing", async () => {
    const { fake, calls } = fakeService({ transcribe: answer });
    const app = makeApp({ fetch: fake });
    for (const clipId of ["NOPE-1", "../../.env", "F01-S1-0002/../x", "", 42]) {
      expect((await post(app, { clipId })).status, String(clipId)).toBe(404);
    }
    // In clips.jsonl but its WAV isn't in the dataset folder.
    expect((await post(app, { clipId: "F01-S1-0001" })).status).toBe(404);
    expect(calls).toHaveLength(0);
  });

  it("refuses base64 that isn't a WAV file", async () => {
    const { fake, calls } = fakeService({ transcribe: answer });
    const app = makeApp({ fetch: fake });
    for (const value of [Buffer.from("ID3 this is an mp3 file, not a wav").toString("base64"), "!!!not base64!!!", "", 7]) {
      expect((await post(app, { wavBase64: value })).status, String(value)).toBe(400);
    }
    expect(calls).toHaveLength(0);
  });

  it("says how to start the model when it isn't running", async () => {
    const response = await post(makeApp(), { clipId: "F01-S1-0002" });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "The tuned model isn't running on this computer. Start it with: cd train && uv run python serve.py" });
  });

  it("passes the service's own 400 message through", async () => {
    const { fake } = fakeService({ transcribe: () => Response.json({ error: "The recording must be 16 kHz mono." }, { status: 400 }) });
    const response = await post(makeApp({ fetch: fake }), { wavBase64 });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "The recording must be 16 kHz mono." });
    const detail = fakeService({ transcribe: () => Response.json({ detail: "Too short." }, { status: 400 }) });
    expect(await (await post(makeApp({ fetch: detail.fake }), { wavBase64 })).json()).toEqual({ error: "Too short." });
  });

  it("turns any other failure into a 502 with a plain sentence and no internals", async () => {
    const crashes = fakeService({ transcribe: () => new Response("Traceback (most recent call last): /Users/x/train/serve.py", { status: 500 }) });
    const crashed = await post(makeApp({ fetch: crashes.fake }), { wavBase64 });
    expect(crashed.status).toBe(502);
    const text = await crashed.text();
    expect(text).not.toContain("Traceback");
    expect(text).not.toContain("serve.py");
    const odd = fakeService({ transcribe: () => Response.json({ nothing: true }) });
    expect((await post(makeApp({ fetch: odd.fake }), { wavBase64 })).status).toBe(502);
  });

  it("refuses a body over 4 MB", async () => {
    const { fake, calls } = fakeService({ transcribe: answer });
    const big = "RIFF" + "A".repeat(4 * 1024 * 1024 + 10);
    const response = await post(makeApp({ fetch: fake }), { wavBase64: big });
    expect(response.status).toBe(413);
    expect(calls).toHaveLength(0);
  });
});

describe("isWavBase64", () => {
  it("checks the RIFF and WAVE marks in the first bytes", () => {
    expect(isWavBase64(wavBase64)).toBe(true);
    expect(isWavBase64(Buffer.from("RIFF\0\0\0\0AVI LIST....").toString("base64"))).toBe(false);
    expect(isWavBase64("UklGRg==")).toBe(false); // just "RIFF"
    expect(isWavBase64(wavBase64.slice(0, -1))).toBe(false);
  });
});
