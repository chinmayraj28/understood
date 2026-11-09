// A live check of the running API server with real keys and real services. Not part of `npm test`.
//
//   npm start                       (in another terminal: the server on :8787)
//   say -o x.aiff "message Sam running late" && afconvert -f WAVE -d LEI16@16000 -c 1 x.aiff x.wav
//   npx tsx tests/live.smoke.ts x.wav [realtime text]
//
// Prints each streamed pipeline event with its time since the request, then one /api/act, one
// /api/speak (bytes and time to first byte) and one /api/realtime-token. Never prints a key.

import { readFileSync } from "node:fs";
import type { PipelineEvent, UnderstandRequest } from "../shared/pipeline";

const base = process.env.API ?? "http://localhost:8787";
const wavPath = process.argv[2];
if (!wavPath) {
  console.error("Usage: npx tsx tests/live.smoke.ts <16 kHz mono WAV> [realtime text]");
  process.exit(1);
}
const realtimeText = process.argv[3] ?? "message Sam running late";

async function understand(): Promise<void> {
  const request: UnderstandRequest = {
    turnId: `smoke-${Date.now()}`,
    wavBase64: readFileSync(wavPath).toString("base64"),
    realtimeText,
    phrasebook: [],
    examples: [],
    keyterms: ["running late"],
    context: { recentTurns: [] },
    switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true },
  };
  const start = Date.now();
  const response = await fetch(`${base}/api/understand`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(request),
  });
  console.log(`understand: HTTP ${response.status} ${response.headers.get("content-type")}`);
  if (!response.ok || !response.body) return console.log(await response.text());
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += value;
    let end: number;
    while ((end = buffer.indexOf("\n\n")) >= 0) {
      const block = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      const data = block.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (!data) continue;
      const event = JSON.parse(data) as PipelineEvent;
      const { type, at: _at, ...rest } = event;
      console.log(`  +${String(Date.now() - start).padStart(5)} ms  ${type.padEnd(15)} ${JSON.stringify(rest)}`);
    }
  }
}

async function act(): Promise<void> {
  const start = Date.now();
  const response = await fetch(`${base}/api/act`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: "message Sam I'm running late" }),
  });
  console.log(`act: HTTP ${response.status} in ${Date.now() - start} ms`, await response.text());
}

async function speak(): Promise<void> {
  const start = Date.now();
  const response = await fetch(`${base}/api/speak`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: "Send running late to Sam?" }),
  });
  if (!response.ok || !response.body) return console.log(`speak: HTTP ${response.status}`, await response.text());
  const reader = response.body.getReader();
  let bytes = 0, firstByte = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!firstByte) firstByte = Date.now() - start;
    bytes += value.byteLength;
  }
  console.log(`speak: HTTP ${response.status}, first byte ${firstByte} ms, ${bytes} bytes (${(bytes / 32000).toFixed(2)} s of audio) in ${Date.now() - start} ms`);
}

async function token(): Promise<void> {
  const start = Date.now();
  const response = await fetch(`${base}/api/realtime-token`, { method: "POST" });
  const body = (await response.json()) as { token?: string; error?: string };
  console.log(`realtime-token: HTTP ${response.status} in ${Date.now() - start} ms, ${body.token ? `token of ${body.token.length} characters` : body.error}`);
}

await understand();
await act();
await speak();
await token();
