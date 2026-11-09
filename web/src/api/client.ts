// Calls to the API server. Keys never reach the browser: the server holds them.

import type {
  ActRequest,
  ActResponse,
  PipelineEvent,
  RealtimeTokenResponse,
  UnderstandRequest,
} from "../../shared/pipeline";

/** A failure with a sentence fit to show on the page. */
export class PlainError extends Error {}

async function explain(response: Response, what: string): Promise<PlainError> {
  let detail = "";
  try {
    const body = await response.text();
    const parsed = JSON.parse(body) as { message?: string; error?: string };
    detail = parsed.message ?? parsed.error ?? "";
  } catch {
    /* not JSON; keep the status only */
  }
  if (response.status === 429) return new PlainError(`Too many turns in a minute. Wait a moment and try again.`);
  return new PlainError(detail || `The server could not ${what} (status ${response.status}).`);
}

/**
 * POST /api/understand and yield each PipelineEvent as soon as its `data:` line arrives.
 * The body is read incrementally, so the page moves while the server is still working.
 */
export async function* understand(request: UnderstandRequest, signal?: AbortSignal): AsyncGenerator<PipelineEvent> {
  let response: Response;
  try {
    response = await fetch("/api/understand", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "text/event-stream" },
      body: JSON.stringify(request),
      signal,
    });
  } catch (error) {
    if ((error as Error).name === "AbortError") throw error;
    throw new PlainError("The server is not reachable. Is it running? Replays still work without it.");
  }
  if (!response.ok || !response.body) throw await explain(response, "understand the turn");

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += value;
    // Events are separated by a blank line; keep a partial event in the buffer.
    let boundary = buffer.search(/\r?\n\r?\n/);
    while (boundary >= 0) {
      const block = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, "");
      const event = parseBlock(block);
      if (event) yield event;
      boundary = buffer.search(/\r?\n\r?\n/);
    }
  }
  const last = parseBlock(buffer);
  if (last) yield last;
}

/** One server-sent event block: joins its `data:` lines and parses them as JSON. */
export function parseBlock(block: string): PipelineEvent | null {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).replace(/^ /, ""))
    .join("\n");
  if (!data.trim()) return null;
  try {
    return JSON.parse(data) as PipelineEvent;
  } catch {
    return null;
  }
}

export async function act(request: ActRequest): Promise<ActResponse> {
  let response: Response;
  try {
    response = await fetch("/api/act", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(request),
    });
  } catch {
    throw new PlainError("The server is not reachable, so nothing was done.");
  }
  if (!response.ok) throw await explain(response, "work out the action");
  return (await response.json()) as ActResponse;
}

/** POST /api/speak: the reply as a stream of 16 kHz PCM16 bytes. */
export async function speakStream(text: string, signal?: AbortSignal): Promise<ReadableStream<Uint8Array>> {
  const response = await fetch("/api/speak", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text }),
    signal,
  });
  if (!response.ok || !response.body) throw await explain(response, "speak the reply");
  return response.body;
}

export async function realtimeToken(): Promise<string> {
  const response = await fetch("/api/realtime-token", { method: "POST" });
  if (!response.ok) throw await explain(response, "open the live transcript");
  return ((await response.json()) as RealtimeTokenResponse).token;
}
