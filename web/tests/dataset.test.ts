// The local dataset route: TORGO audio may not be redistributed, so these check that it is only
// served to this machine, only for clips in the manifest, and never from outside the data folder.
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { DatasetIndex, DatasetResponse } from "../shared/dataset";
import { buildIndex, createDatasetApp, isLocalRequest, parseRange, safeAudioPath } from "../server/dataset";

let root: string;
let dataDir: string;
let resultsPath: string;
const wav = Buffer.from("RIFF....WAVEfmt fake audio bytes for the test");

beforeAll(() => {
  root = mkdtempSync(path.join(tmpdir(), "dataset-test-"));
  dataDir = path.join(root, "torgo");
  mkdirSync(path.join(dataDir, "raw", "F01"), { recursive: true });
  writeFileSync(path.join(dataDir, "raw", "F01", "0001.wav"), wav);
  writeFileSync(path.join(root, "secret.wav"), Buffer.from("outside the dataset"));
  writeFileSync(path.join(root, ".env"), "ELEVENLABS_API_KEY=never-served");
  writeFileSync(
    path.join(dataDir, "manifest.json"),
    JSON.stringify({
      name: "TORGO",
      speakers: [
        { id: "F01", group: "dysarthric", condition: "cerebral palsy", severity: "severe" },
        { id: "FC01", group: "control", condition: "", severity: "none" },
      ],
      clips: [
        { id: "F01-S1-0001", speaker: "F01", kind: "word", prompt: "stick", seconds: 1.8, session: "Session1", split: "test", audio: "raw/F01/0001.wav" },
        { id: "F01-S1-0002", speaker: "F01", kind: "word", prompt: "meat", seconds: 1.1, session: "Session1", split: "enrolment", audio: "raw/F01/missing.wav" },
        // A manifest entry pointing outside the folder must never be served.
        { id: "F01-S1-0003", speaker: "F01", kind: "word", prompt: "escape", seconds: 1, session: "Session1", split: "test", audio: "../secret.wav" },
        { id: "F01-S1-0004", speaker: "F01", kind: "word", prompt: "env", seconds: 1, session: "Session1", split: "test", audio: "../.env" },
      ],
    }),
  );
  resultsPath = path.join(root, "results.json");
  writeFileSync(
    resultsPath,
    JSON.stringify({
      date: "2026-11-09T03:37:26Z",
      records: [
        { clip: "F01-S1-0001", setup: "scribe", decision: "confirm", finalText: "stick", hypotheses: [{ hearer: "scribe", text: "Stick.", seconds: 0.5 }], seconds: 0.5, promptSeen: false },
        { clip: "F01-S1-0001", setup: "gemini", decision: "act", finalText: "stick", hypotheses: [], seconds: 2, promptSeen: false },
        {
          clip: "F01-S1-0001", setup: "phrasebook", decision: "act", finalText: "stick", seconds: 2.8, promptSeen: false,
          hypotheses: [{ hearer: "scribe", text: "Stick.", seconds: 0.5 }, { hearer: "gemini", text: "", seconds: 4, failure: "timed out" }],
          reading: { text: "stick", confidence: "high", alternatives: [], reason: "agree" },
          phrasebookMatch: { heard: "stik", meant: "stick", similarity: 0.9, timesConfirmed: 2 },
        },
        { clip: "NOT-IN-MANIFEST", setup: "phrasebook", decision: "act", finalText: "x", hypotheses: [], seconds: 1, promptSeen: false },
      ],
    }),
  );
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

const local = { REMOTE_ADDRESS: "127.0.0.1" };
const get = (app: ReturnType<typeof createDatasetApp>, url: string, headers: Record<string, string> = {}, env = local) =>
  app.request(url, { headers: { host: "localhost:5173", ...headers } }, env);

describe("only this machine is answered", () => {
  it("accepts loopback addresses with a localhost Host header", () => {
    expect(isLocalRequest("127.0.0.1", "localhost:5173")).toBe(true);
    expect(isLocalRequest("::1", "127.0.0.1:8787")).toBe(true);
    expect(isLocalRequest("::ffff:127.0.0.1", "[::1]:8787")).toBe(true);
  });

  it("refuses other machines, missing addresses and foreign Host headers", () => {
    expect(isLocalRequest("192.168.1.20", "localhost:5173")).toBe(false);
    expect(isLocalRequest(undefined, "localhost:5173")).toBe(false);
    expect(isLocalRequest("127.0.0.1", "evil.example")).toBe(false);
    expect(isLocalRequest("127.0.0.1", "localhost.evil.example:5173")).toBe(false);
    expect(isLocalRequest("127.0.0.1", undefined)).toBe(false);
  });

  it("refuses a request the Vite proxy received from another machine", () => {
    // Through the proxy the socket is always local; the proxy's header says who really asked.
    expect(isLocalRequest("127.0.0.1", "localhost:8787", "192.168.1.20")).toBe(false);
    expect(isLocalRequest("127.0.0.1", "localhost:8787", "")).toBe(false);
    expect(isLocalRequest("127.0.0.1", "localhost:8787", "::1")).toBe(true);
  });

  it("answers 403 when the proxy says the request came from the network", async () => {
    const app = createDatasetApp({ dataDir, resultsPath });
    expect((await get(app, "/api/dataset", { "x-understood-peer": "192.168.1.20" })).status).toBe(403);
    expect((await get(app, "/api/dataset/audio/F01-S1-0001", { "x-understood-peer": "192.168.1.20" })).status).toBe(403);
    expect((await get(app, "/api/dataset", { "x-understood-peer": "127.0.0.1" })).status).toBe(200);
  });

  it("answers 403 to a request from another machine, for the list and for audio", async () => {
    const app = createDatasetApp({ dataDir, resultsPath });
    expect((await get(app, "/api/dataset", {}, { REMOTE_ADDRESS: "10.0.0.5" })).status).toBe(403);
    expect((await get(app, "/api/dataset/audio/F01-S1-0001", {}, { REMOTE_ADDRESS: "10.0.0.5" })).status).toBe(403);
    expect((await get(app, "/api/dataset", { host: "rebind.example:5173" })).status).toBe(403);
  });
});

describe("GET /api/dataset", () => {
  it("lists every clip with speaker counts, and only the shown setups of evaluated clips", async () => {
    const response = await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset");
    expect(response.status).toBe(200);
    const body = (await response.json()) as DatasetIndex;
    expect(body.available).toBe(true);
    expect(body.clips.map((c) => c.id)).toEqual(["F01-S1-0001", "F01-S1-0002", "F01-S1-0003", "F01-S1-0004"]);
    expect(body.speakers.find((s) => s.id === "F01")?.clipCount).toBe(4);
    expect(body.speakers.find((s) => s.id === "FC01")?.clipCount).toBe(0);
    expect(body.results["F01-S1-0001"].map((r) => r.setup)).toEqual(["scribe", "phrasebook"]);
    expect(body.results["NOT-IN-MANIFEST"]).toBeUndefined();
    const full = body.results["F01-S1-0001"][1];
    expect(full.phrasebook).toEqual({ heard: "stik", meant: "stick", timesConfirmed: 2 });
    expect(full.heard[1]).toEqual({ hearer: "gemini", text: "", seconds: 4, failure: "timed out" });
    expect(body.resultsDate).toBe("2026-11-09T03:37:26Z");
  });

  it("never sends a file path to the page", async () => {
    const text = await (await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset")).text();
    expect(text).not.toContain("raw/");
    expect(text).not.toContain(".wav");
  });

  it("says how to get the data when it is not on this computer", async () => {
    const response = await get(createDatasetApp({ dataDir: path.join(root, "nowhere") }), "/api/dataset");
    const body = (await response.json()) as DatasetResponse;
    expect(body.available).toBe(false);
    if (!body.available) expect(body.reason).toContain("fetch_torgo.sh");
  });

  it("still lists the clips when the evaluation results are missing", async () => {
    const body = (await (await get(createDatasetApp({ dataDir, resultsPath: path.join(root, "none.json") }), "/api/dataset")).json()) as DatasetIndex;
    expect(body.clips).toHaveLength(4);
    expect(body.results).toEqual({});
  });
});

describe("GET /api/dataset/audio/:id", () => {
  it("serves a listed clip as WAV", async () => {
    const response = await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset/audio/F01-S1-0001");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("audio/wav");
    expect(response.headers.get("accept-ranges")).toBe("bytes");
    expect(Buffer.from(await response.arrayBuffer())).toEqual(wav);
  });

  it("serves part of a clip for a Range request (Safari needs this to play audio)", async () => {
    const response = await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset/audio/F01-S1-0001", { range: "bytes=0-3" });
    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe(`bytes 0-3/${wav.length}`);
    expect(Buffer.from(await response.arrayBuffer()).toString()).toBe("RIFF");
  });

  it("sends the whole file for a request asking for several ranges", async () => {
    const response = await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset/audio/F01-S1-0001", { range: "bytes=0-1,5-9" });
    expect(response.status).toBe(200);
    expect(Buffer.from(await response.arrayBuffer())).toEqual(wav);
  });

  it("refuses a symlink inside the data folder that points outside it", async () => {
    const linked = path.join(root, "linked");
    mkdirSync(path.join(linked, "raw"), { recursive: true });
    symlinkSync(path.join(root, "secret.wav"), path.join(linked, "raw", "link.wav"));
    writeFileSync(path.join(linked, "raw", "real.wav"), wav);
    writeFileSync(
      path.join(linked, "manifest.json"),
      JSON.stringify({
        speakers: [],
        clips: [
          { id: "L-1", speaker: "F01", kind: "word", prompt: "link", seconds: 1, session: "S1", split: "test", audio: "raw/link.wav" },
          { id: "L-2", speaker: "F01", kind: "word", prompt: "real", seconds: 1, session: "S1", split: "test", audio: "raw/real.wav" },
        ],
      }),
    );
    const app = createDatasetApp({ dataDir: linked });
    expect((await get(app, "/api/dataset/audio/L-1")).status).toBe(404);
    expect((await get(app, "/api/dataset/audio/L-2")).status).toBe(200);
  });

  it("answers 416 to a range past the end", async () => {
    const response = await get(createDatasetApp({ dataDir, resultsPath }), "/api/dataset/audio/F01-S1-0001", { range: "bytes=9999-" });
    expect(response.status).toBe(416);
  });

  it("refuses ids not in the manifest, odd ids, and missing files", async () => {
    const app = createDatasetApp({ dataDir, resultsPath });
    for (const id of ["NOPE-1", "..%2F..%2F.env", "%2E%2E", "F01-S1-0002"]) {
      expect((await get(app, `/api/dataset/audio/${id}`)).status, id).toBe(404);
    }
  });

  it("refuses a manifest entry that points outside the data folder", async () => {
    const app = createDatasetApp({ dataDir, resultsPath });
    expect((await get(app, "/api/dataset/audio/F01-S1-0003")).status).toBe(404);
    expect((await get(app, "/api/dataset/audio/F01-S1-0004")).status).toBe(404);
  });
});

describe("helpers", () => {
  it("safeAudioPath keeps paths inside the folder and to .wav files", () => {
    expect(safeAudioPath("/data/torgo", "raw/F01/0001.wav")).toBe(path.resolve("/data/torgo/raw/F01/0001.wav"));
    expect(safeAudioPath("/data/torgo", "../secret.wav")).toBeNull();
    expect(safeAudioPath("/data/torgo", "/etc/passwd")).toBeNull();
    expect(safeAudioPath("/data/torgo", "raw/F01/notes.txt")).toBeNull();
    expect(safeAudioPath("/data/torgo", "../torgo-other/x.wav")).toBeNull();
  });

  it("parseRange reads start-end, open-ended and suffix ranges", () => {
    expect(parseRange("bytes=0-99", 1000)).toEqual({ start: 0, end: 99 });
    expect(parseRange("bytes=500-", 1000)).toEqual({ start: 500, end: 999 });
    expect(parseRange("bytes=-100", 1000)).toEqual({ start: 900, end: 999 });
    expect(parseRange("bytes=0-5000", 1000)).toEqual({ start: 0, end: 999 });
    expect(parseRange("bytes=1000-", 1000)).toBeNull();
    expect(parseRange("bytes=5-1", 1000)).toBeNull();
    expect(parseRange("bytes=0-1,5-9", 1000)).toBeNull();
    expect(parseRange(undefined, 1000)).toBeNull();
  });

  it("buildIndex skips clips with unsafe ids", () => {
    const built = buildIndex({ clips: [{ id: "../x", audio: "a.wav" }, { id: "ok-1", audio: "b.wav", speaker: "F01" }], speakers: [] }, null);
    expect(built.index.clips.map((c) => c.id)).toEqual(["ok-1"]);
  });
});
