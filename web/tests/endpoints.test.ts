// The HTTP endpoints, with every outside service faked by replacing fetch.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { PipelineEvent, UnderstandRequest } from "../shared/pipeline";
import { createApp, type Env } from "../server/app";

const env: Env = { ELEVENLABS_API_KEY: "el-test", OPENROUTER_API_KEY: "or-test", ANTHROPIC_API_KEY: "an-test" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const claudeSays = (object: unknown) => json({ stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify(object) }] });
const geminiSays = (text: string) => json({ choices: [{ finish_reason: "stop", message: { content: text } }] });

/** Fakes fetch by URL. Each handler gets the request init; `calls` records every URL. */
function fakeFetch(handlers: Record<string, (init: RequestInit) => Response | Promise<Response>>) {
  const calls: { url: string; init: RequestInit }[] = [];
  vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const key = Object.keys(handlers).find((prefix) => url.startsWith(prefix));
    if (!key) throw new Error(`unexpected fetch ${url}`);
    return handlers[key](init);
  });
  return calls;
}

afterEach(() => vi.unstubAllGlobals());

const turn = (change: Partial<UnderstandRequest> = {}): UnderstandRequest => ({
  turnId: "t1", wavBase64: btoa("RIFF0000WAVE"), realtimeText: "volume up", phrasebook: [], examples: [], keyterms: [], context: {},
  switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true }, ...change,
});

async function post(app: ReturnType<typeof createApp>, path: string, body: unknown, headers: Record<string, string> = {}, bindings: Env = env) {
  return app.request(path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) }, bindings);
}

async function events(response: Response): Promise<PipelineEvent[]> {
  const text = await response.text();
  return text.split("\n\n").map((block) => block.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join(""))
    .filter(Boolean).map((data) => JSON.parse(data) as PipelineEvent);
}

describe("POST /api/understand", () => {
  it("streams one event per step, in order, as server-sent events", async () => {
    const calls = fakeFetch({
      "https://api.elevenlabs.io/v1/speech-to-text": () => json({ text: "Volume up" }),
      "https://openrouter.ai/": () => geminiSays("volume up."),
    });
    const response = await post(createApp(), "/api/understand", turn());
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const list = await events(response);
    expect(list.map((event) => event.type)).toEqual([
      "turn.started", "hear.started", "hear.started", "hear.started", "hear.done", "hear.done", "hear.done",
      "agreement", "phrasebook", "repair.skipped", "decision", "turn.done",
    ]);
    expect(list.find((event) => event.type === "decision")).toMatchObject({ decision: { kind: "act", text: "Volume up" } });
    expect(calls.map((call) => call.url)).not.toContain("https://api.anthropic.com/v1/messages"); // fast path
    const scribe = calls.find((call) => call.url.includes("speech-to-text"))!;
    expect((scribe.init.headers as Record<string, string>)["xi-api-key"]).toBe("el-test");
  });

  it("reports a failed hearer and a failed Claude without failing the turn", async () => {
    fakeFetch({
      "https://api.elevenlabs.io/v1/speech-to-text": () => json({ detail: "no" }, 401),
      "https://openrouter.ai/": () => geminiSays("call some"),
      "https://api.anthropic.com/": () => json({ error: { message: "overloaded" } }, 529),
    });
    const list = await events(await post(createApp(), "/api/understand", turn({ realtimeText: "cool sum" })));
    expect(list.find((event) => event.type === "hear.done" && event.hearer === "scribe")).toMatchObject({ text: "", failure: "ElevenLabs didn't accept the key." });
    expect(list.find((event) => event.type === "repair.skipped")).toMatchObject({ why: expect.stringContaining("Claude had a problem on its side.") });
    expect(list.find((event) => event.type === "decision")).toMatchObject({ decision: { kind: "confirm" } });
    expect(list.at(-1)?.type).toBe("turn.done");
  });

  it("asks Claude with the repair schema when the hearers disagree", async () => {
    const calls = fakeFetch({
      "https://api.elevenlabs.io/v1/speech-to-text": () => json({ text: "message mom" }),
      "https://openrouter.ai/": () => geminiSays("massage Mum"),
      "https://api.anthropic.com/": () => claudeSays({ text: "message Mum", confidence: "medium", alternatives: [], reason: "Mum is a contact." }),
    });
    const list = await events(await post(createApp(), "/api/understand", turn({ realtimeText: "" })));
    expect(list.find((event) => event.type === "repair.done")).toMatchObject({ reading: { text: "message Mum", confidence: "medium" } });
    expect(list.find((event) => event.type === "decision")).toMatchObject({ decision: { kind: "confirm", question: "Message Mum?" } });
    const claude = calls.find((call) => call.url.startsWith("https://api.anthropic.com"))!;
    expect((claude.init.headers as Record<string, string>)["anthropic-version"]).toBe("2026-10-21");
    expect(JSON.parse(claude.init.body as string).output_config.format.type).toBe("json_schema");
  });

  it("refuses bad requests before any outside call", async () => {
    const calls = fakeFetch({});
    const app = createApp();
    expect((await post(app, "/api/understand", "not json")).status).toBe(400);
    expect((await post(app, "/api/understand", { ...turn(), wavBase64: "not base64!" })).status).toBe(400);
    expect((await post(app, "/api/understand", { ...turn(), switches: { keyterms: true } })).status).toBe(400);
    const sixExamples = Array.from({ length: 6 }, () => ({ wavBase64: "AAAA", text: "hi" }));
    const response = await post(app, "/api/understand", { ...turn(), examples: sixExamples });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "examples has too many items." });
    const tooLong = btoa("x".repeat(2_000_001));
    expect((await post(app, "/api/understand", { ...turn(), wavBase64: tooLong })).status).toBe(400);
    expect(calls).toHaveLength(0);
  });

  it("limits each visitor's turns per minute", async () => {
    fakeFetch({
      "https://api.elevenlabs.io/v1/speech-to-text": () => json({ text: "volume up" }),
      "https://openrouter.ai/": () => geminiSays("volume up"),
    });
    // Behind a trusted proxy, the proxy's header names the visitor.
    const behindProxy = { ...env, TRUST_PROXY: "1" };
    const app = createApp({ understandPerMinute: 2 });
    const visitor = { "x-forwarded-for": "203.0.113.7" };
    expect((await post(app, "/api/understand", turn(), visitor, behindProxy)).status).toBe(200);
    expect((await post(app, "/api/understand", turn(), visitor, behindProxy)).status).toBe(200);
    expect((await post(app, "/api/understand", turn(), visitor, behindProxy)).status).toBe(429);
    expect((await post(app, "/api/understand", turn(), { "x-forwarded-for": "203.0.113.8" }, behindProxy)).status).toBe(200);
  });

  it("ignores proxy headers unless told to trust them, so they can't dodge the limit", async () => {
    fakeFetch({
      "https://api.elevenlabs.io/v1/speech-to-text": () => json({ text: "volume up" }),
      "https://openrouter.ai/": () => geminiSays("volume up"),
    });
    const app = createApp({ understandPerMinute: 2 });
    const direct = { ...env, REMOTE_ADDRESS: "198.51.100.4" };
    expect((await post(app, "/api/understand", turn(), { "x-forwarded-for": "1.1.1.1" }, direct)).status).toBe(200);
    expect((await post(app, "/api/understand", turn(), { "cf-connecting-ip": "2.2.2.2" }, direct)).status).toBe(200);
    expect((await post(app, "/api/understand", turn(), { "x-forwarded-for": "3.3.3.3" }, direct)).status).toBe(429);
  });
});

describe("per-visitor limit by address", () => {
  it("counts IPv6 addresses in one /64 as one visitor, on the realtime-token endpoint too", async () => {
    fakeFetch({ "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe": () => json({ token: "t" }) });
    const app = createApp({ otherPerMinute: 2 });
    const from = (address: string) => post(app, "/api/realtime-token", {}, {}, { ...env, REMOTE_ADDRESS: address });
    expect((await from("2001:db8:1:2::a")).status).toBe(200);
    expect((await from("2001:db8:1:2::b")).status).toBe(200);
    expect((await from("2001:db8:1:2:ffff::c")).status).toBe(429);
    expect((await from("2001:db8:1:3::a")).status).toBe(200); // another /64
  });
});

describe("POST /api/act", () => {
  it("always needs a yes for a message or a call, whatever the model says", async () => {
    fakeFetch({ "https://api.anthropic.com/": () => claudeSays({ kind: "message", to: "Sam", text: "running late", minutes: 0, query: "", when: "", reply: "Sent!" }) });
    const response = await post(createApp(), "/api/act", { text: "message Sam running late" });
    expect(await response.json()).toEqual({ action: { kind: "message", to: "Sam", text: "running late" }, reply: 'Send "running late" to Sam?', needsConfirmation: true });

    fakeFetch({ "https://api.anthropic.com/": () => claudeSays({ kind: "call", to: "Mum", text: "", minutes: 0, query: "", when: "", reply: "Calling" }) });
    expect(await (await post(createApp(), "/api/act", { text: "call mum" })).json()).toMatchObject({ action: { kind: "call", to: "Mum" }, needsConfirmation: true });

    fakeFetch({ "https://api.anthropic.com/": () => claudeSays({ kind: "timer", to: "", text: "", minutes: 5, query: "", when: "", reply: "Timer set." }) });
    expect(await (await post(createApp(), "/api/act", { text: "timer five minutes" })).json()).toEqual({ action: { kind: "timer", minutes: 5 }, reply: "Timer set.", needsConfirmation: false });
  });

  it("turns an incomplete action into none", async () => {
    fakeFetch({ "https://api.anthropic.com/": () => claudeSays({ kind: "message", to: "", text: "hi", minutes: 0, query: "", when: "", reply: "Sent" }) });
    expect(await (await post(createApp(), "/api/act", { text: "message" })).json()).toMatchObject({ action: { kind: "none" }, needsConfirmation: false });
  });

  it("refuses an empty sentence", async () => {
    fakeFetch({});
    expect((await post(createApp(), "/api/act", { text: "  " })).status).toBe(400);
  });
});

describe("POST /api/speak and /api/realtime-token", () => {
  it("streams the PCM straight through and caps the text at 300 characters", async () => {
    const calls = fakeFetch({ "https://api.elevenlabs.io/v1/text-to-speech/": () => new Response(new Uint8Array([1, 2, 3, 4])) });
    const response = await post(createApp(), "/api/speak", { text: "Message Mum?" });
    expect(response.headers.get("content-type")).toContain("audio/pcm");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(calls[0].url).toBe("https://api.elevenlabs.io/v1/text-to-speech/Xb7hH8MSUJpSbSDYk0k2/stream?output_format=pcm_16000");
    expect(JSON.parse(calls[0].init.body as string)).toEqual({ text: "Message Mum?", model_id: "eleven_flash_v2_5" });
    expect((await post(createApp(), "/api/speak", { text: "x".repeat(301) })).status).toBe(400);
  });

  it("returns a single-use token and never the key", async () => {
    const calls = fakeFetch({ "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe": () => json({ token: "tok-123" }) });
    const response = await post(createApp(), "/api/realtime-token", {});
    const body = await response.json();
    expect(body).toEqual({ token: "tok-123" });
    expect(JSON.stringify(body)).not.toContain("el-test");
    expect(calls[0].init.method).toBe("POST");

    fakeFetch({ "https://api.elevenlabs.io/": () => json({}, 500) });
    expect((await post(createApp(), "/api/realtime-token", {})).status).toBe(502);
  });
});
