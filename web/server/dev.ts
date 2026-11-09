// Runs the API server on Node for local development, on port 8787 (Vite sends /api here).
// Keys are read from the repo's .env with a tiny parser and handed to the app as its environment,
// the same way Cloudflare Workers hands it bindings. Keys are never printed or logged.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import app, { type Env } from "./app";

/** Reads KEY=value lines; ignores blanks and comments; strips matching quotes. */
export function parseEnv(text: string): Record<string, string> {
  const values: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const equals = trimmed.indexOf("=");
    if (equals <= 0) continue;
    const key = trimmed.slice(0, equals).replace(/^export\s+/, "").trim();
    let value = trimmed.slice(equals + 1).trim();
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.endsWith(value[0])) value = value.slice(1, -1);
    values[key] = value;
  }
  return values;
}

function loadEnv(): Env {
  const path = fileURLToPath(new URL("../../.env", import.meta.url));
  let file: Record<string, string> = {};
  try {
    file = parseEnv(readFileSync(path, "utf8"));
  } catch {
    console.warn("No .env found at the repo root; using the process environment only.");
  }
  const pick = (name: keyof Env) => process.env[name] || file[name] || undefined;
  return {
    ELEVENLABS_API_KEY: pick("ELEVENLABS_API_KEY"),
    OPENROUTER_API_KEY: pick("OPENROUTER_API_KEY"),
    ANTHROPIC_API_KEY: pick("ANTHROPIC_API_KEY"),
    ELEVENLABS_VOICE_ID: pick("ELEVENLABS_VOICE_ID"),
    TRUST_PROXY: pick("TRUST_PROXY"),
  };
}

const env = loadEnv();
const port = Number(process.env.PORT) || 8787;
const missing = (["ELEVENLABS_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"] as const).filter((name) => !env[name]);
// The socket's address is passed per request for the rate limit; proxy headers are not trusted
// here unless TRUST_PROXY is set.
serve({ fetch: (request, node) => app.fetch(request, { ...env, REMOTE_ADDRESS: node.incoming.socket?.remoteAddress }), port }, () => {
  console.log(`API server on http://localhost:${port}`);
  if (missing.length) console.warn(`Missing keys (those stages will fail): ${missing.join(", ")}`);
});
