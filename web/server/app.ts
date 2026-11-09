// The API server for the website, as a Hono app. Only fetch and Web APIs are used here (no
// fs, no Buffer), so the same app runs on Node locally (dev.ts) and later on Cloudflare Workers.
// Keys come from the environment bindings and never leave the server.

import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { streamSSE } from "hono/streaming";
import type { PipelineEvent, RealtimeTokenResponse } from "../shared/pipeline";
import { chooseAction } from "./act";
import { askClaude } from "./claude";
import { hearWithGemini, hearWithScribe } from "./hearers";
import { plainMessage, send, withTimeLimit } from "./http";
import { readingFrom, repairData, repairInstructions, repairSchema } from "./repair";
import { understandTurn, type UnderstandDeps } from "./understand";
import { checkAct, checkSpeak, checkUnderstand, type Checked } from "./validate";

export interface Env {
  ELEVENLABS_API_KEY?: string;
  OPENROUTER_API_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  /** Optional: the ElevenLabs voice for /api/speak. */
  ELEVENLABS_VOICE_ID?: string;
  /**
   * "1" when the server sits behind a proxy that sets the visitor's address (Cloudflare sets
   * cf-connecting-ip). Without it those headers are ignored, because anyone can send them.
   */
  TRUST_PROXY?: string;
  /** The socket's address, set per request by dev.ts on Node. */
  REMOTE_ADDRESS?: string;
}

/** The voice the Mac app's agent uses (HFVoice AgentConfiguration.swift). */
export const defaultVoiceId = "Xb7hH8MSUJpSbSDYk0k2";

/**
 * A per-visitor limit on requests per minute, kept in memory. It remembers at most `maxVisitors`;
 * when full, the visitor seen longest ago is forgotten first, so a flood of new addresses cannot
 * wipe everyone's count at once. On Workers each instance keeps its own count, so there this is
 * only a brake on one runaway visitor; when we deploy there we'd use Workers' rate-limiting
 * binding instead. The spending caps on every key are the real ceiling.
 */
export class RateLimiter {
  private hits = new Map<string, number[]>();
  constructor(private perMinute: number, private now: () => number = Date.now, private maxVisitors = 10_000) {}

  allow(visitor: string): boolean {
    const cutoff = this.now() - 60_000;
    const recent = (this.hits.get(visitor) ?? []).filter((time) => time > cutoff);
    const allowed = recent.length < this.perMinute;
    if (allowed) recent.push(this.now());
    // Delete and set again, so the Map's order is "seen longest ago" first.
    this.hits.delete(visitor);
    this.hits.set(visitor, recent);
    while (this.hits.size > this.maxVisitors) this.hits.delete(this.hits.keys().next().value!);
    return allowed;
  }

  get visitorCount(): number {
    return this.hits.size;
  }
}

/**
 * The key a visitor is counted under. IPv4 addresses count one by one; IPv6 addresses count by
 * their first 64 bits, because one home or phone is usually given a whole /64 and could
 * otherwise use a fresh address for every request.
 */
export function visitorKey(address: string): string {
  const plain = address.trim().replace(/^\[|\]$/g, "").split("%")[0];
  const mapped = plain.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i);
  if (mapped) return mapped[1];
  if (!plain.includes(":")) return plain || "unknown";
  const [head, tail] = plain.split("::");
  const front = head ? head.split(":") : [];
  const back = tail !== undefined && tail ? tail.split(":") : [];
  const groups = tail === undefined ? front : [...front, ...Array(Math.max(0, 8 - front.length - back.length)).fill("0"), ...back];
  return groups.slice(0, 4).map((group) => (parseInt(group, 16) || 0).toString(16)).join(":") + "::/64";
}

export interface AppOptions {
  /** Replaces the real hearers and Claude in tests. */
  deps?: (env: Env) => UnderstandDeps;
  understandPerMinute?: number;
  otherPerMinute?: number;
}

export function realDeps(env: Env): UnderstandDeps {
  return {
    hearScribe: (request) => hearWithScribe(env.ELEVENLABS_API_KEY ?? "", request),
    hearGemini: (request) => hearWithGemini(env.OPENROUTER_API_KEY ?? "", request),
    repair: async (input, signal) => {
      const answer = await askClaude(env.ANTHROPIC_API_KEY ?? "", {
        instructions: repairInstructions, input: repairData(input), schema: repairSchema, signal, seconds: 3,
      });
      return readingFrom(answer, input);
    },
    now: Date.now,
    hearerSeconds: 4,
    repairSeconds: 3,
  };
}

/** Proxy headers are believed only when TRUST_PROXY says a proxy we control sets them. */
const visitor = (c: Context<{ Bindings: Env }>) => {
  const trusted = c.env?.TRUST_PROXY === "1" || c.env?.TRUST_PROXY === "true";
  const forwarded = trusted ? c.req.header("cf-connecting-ip") ?? c.req.header("x-forwarded-for")?.split(",")[0] : undefined;
  return visitorKey(forwarded ?? c.env?.REMOTE_ADDRESS ?? "unknown");
};

async function jsonBody<T>(c: Context, check: (body: unknown) => Checked<T>): Promise<Checked<T>> {
  const body = await c.req.json().catch(() => undefined);
  if (body === undefined) return { ok: false, error: "The request must be JSON." };
  return check(body);
}

export function createApp(options: AppOptions = {}) {
  const app = new Hono<{ Bindings: Env }>();
  const turns = new RateLimiter(options.understandPerMinute ?? 20);
  const others = new RateLimiter(options.otherPerMinute ?? 60);
  const tooBig = (c: Context) => c.json({ error: "That request is too large." }, 413);

  app.get("/api/health", (c) => c.json({ ok: true }));

  app.post("/api/understand", bodyLimit({ maxSize: 10 * 1024 * 1024, onError: tooBig }), async (c) => {
    if (!turns.allow(visitor(c))) return c.json({ error: "Too many turns in a minute. Please wait a moment." }, 429);
    const checked = await jsonBody(c, checkUnderstand);
    if (!checked.ok) return c.json({ error: checked.error }, 400);
    const deps = (options.deps ?? realDeps)(c.env ?? {});
    return streamSSE(c, async (stream) => {
      // Events are written in the order they are emitted; the chain keeps writes from overlapping.
      let chain = Promise.resolve();
      const emit = (event: PipelineEvent) => {
        // A visitor who closed the page can't be written to; that is not a server failure.
        chain = chain.then(() => stream.writeSSE({ data: JSON.stringify(event) })).catch(() => {});
      };
      try {
        await understandTurn(checked.value, deps, emit, c.req.raw.signal);
      } catch {
        emit({ type: "turn.failed", at: Date.now(), message: "Something went wrong on the server, so this turn was not understood." });
      }
      await chain;
    });
  });

  app.post("/api/realtime-token", async (c) => {
    if (!others.allow(visitor(c))) return c.json({ error: "Too many requests. Please wait a moment." }, 429);
    try {
      const response = await send("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", {
        method: "POST", headers: { "xi-api-key": c.env?.ELEVENLABS_API_KEY ?? "" }, signal: withTimeLimit(5000),
      }, "ElevenLabs", 5);
      const reply = (await response.json().catch(() => null)) as { token?: unknown } | null;
      if (typeof reply?.token !== "string" || !reply.token) return c.json({ error: "ElevenLabs gave an answer I didn't expect." }, 502);
      return c.json({ token: reply.token } satisfies RealtimeTokenResponse);
    } catch (error) {
      return c.json({ error: plainMessage(error, "ElevenLabs") }, 502);
    }
  });

  app.post("/api/speak", bodyLimit({ maxSize: 16 * 1024, onError: tooBig }), async (c) => {
    if (!others.allow(visitor(c))) return c.json({ error: "Too many requests. Please wait a moment." }, 429);
    const checked = await jsonBody(c, checkSpeak);
    if (!checked.ok) return c.json({ error: checked.error }, 400);
    const voice = c.env?.ELEVENLABS_VOICE_ID || defaultVoiceId;
    try {
      const upstream = await send(`https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voice)}/stream?output_format=pcm_16000`, {
        method: "POST",
        headers: { "xi-api-key": c.env?.ELEVENLABS_API_KEY ?? "", "content-type": "application/json" },
        body: JSON.stringify({ text: checked.value.text, model_id: "eleven_flash_v2_5" }),
        signal: withTimeLimit(15_000, c.req.raw.signal),
      }, "ElevenLabs", 15);
      // Passed straight through as it arrives, so the page can start playing the first words.
      return new Response(upstream.body, { headers: { "content-type": "audio/pcm;rate=16000;encoding=signed-int;bits=16", "cache-control": "no-store" } });
    } catch (error) {
      return c.json({ error: plainMessage(error, "ElevenLabs") }, 502);
    }
  });

  app.post("/api/act", bodyLimit({ maxSize: 64 * 1024, onError: tooBig }), async (c) => {
    if (!others.allow(visitor(c))) return c.json({ error: "Too many requests. Please wait a moment." }, 429);
    const checked = await jsonBody(c, checkAct);
    if (!checked.ok) return c.json({ error: checked.error }, 400);
    try {
      return c.json(await chooseAction(c.env?.ANTHROPIC_API_KEY ?? "", checked.value, c.req.raw.signal));
    } catch (error) {
      return c.json({ error: plainMessage(error, "Claude") }, 502);
    }
  });

  return app;
}

/** The app with the real hearers and Claude; Workers use this as the default export. */
const app = createApp();
export default app;
