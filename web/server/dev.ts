// Runs the API server on Node for local development, on port 8787 (Vite sends /api here).
// Keys are read from the repo's .env with a tiny parser and handed to the app as its environment,
// the same way Cloudflare Workers hands it bindings. Keys are never printed or logged.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import { createApp, type Env } from "./app";
import { createDatasetApp } from "./dataset";

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
// On this computer one visitor may hear a TORGO speaker's 20 set-up clips and then their test
// clips within a minute, so the per-minute brake is looser than the hosted default of 20.
const app = createApp({ understandPerMinute: 90 });
const port = Number(process.env.PORT) || 8787;
const missing = (["ELEVENLABS_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"] as const).filter((name) => !env[name]);

// The TORGO dataset browser: local only, so it is mounted here and never in the hosted app.
// DATASET_DIR and DATASET_RESULTS override where the clips and the evaluation results are read from.
const repoPath = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const dataset = createDatasetApp({
  dataDir: process.env.DATASET_DIR || repoPath("eval/data/torgo"),
  resultsPath: process.env.DATASET_RESULTS || repoPath("eval/results/2026-11-09-second-run/results.json"),
});

// The socket's address is passed per request for the rate limit and the dataset's local-only
// check; proxy headers are not trusted here unless TRUST_PROXY is set.
serve({
  fetch: (request, node) => {
    const bindings = { ...env, REMOTE_ADDRESS: node.incoming.socket?.remoteAddress };
    const pathname = new URL(request.url).pathname;
    const forDataset = pathname === "/api/dataset" || pathname.startsWith("/api/dataset/");
    return forDataset ? dataset.fetch(request, bindings) : app.fetch(request, bindings);
  },
  port,
  // Only this computer: the keys behind this server, and the TORGO route, are not for the network.
  hostname: "127.0.0.1",
}, () => {
  console.log(`API server on http://localhost:${port}`);
  if (missing.length) console.warn(`Missing keys (those stages will fail): ${missing.join(", ")}`);
});
