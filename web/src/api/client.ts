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

/** How long a whole turn may take on the server before the page gives up on it. */
export const UNDERSTAND_TIMEOUT_MS = 15_000;
/** How long /api/act may take. */
export const ACT_TIMEOUT_MS = 10_000;

/** An abort signal that fires after `ms`, or when `outer` fires, whichever is first. */
function deadline(ms: number, outer?: AbortSignal) {
  const controller = new AbortController();
  let expired = false;
  const timer = setTimeout(() => {
    expired = true;
    controller.abort();
  }, ms);
  const forward = () => controller.abort();
  if (outer?.aborted) controller.abort();
  outer?.addEventListener("abort", forward);
  return {
    signal: controller.signal,
    expired: () => expired,
    clear: () => {
      clearTimeout(timer);
      outer?.removeEventListener("abort", forward);
    },
  };
}

/**
 * POST /api/understand and yield each PipelineEvent as soon as its `data:` line arrives.
 * The body is read incrementally, so the page moves while the server is still working.
 * A turn that takes longer than `timeoutMs` is dropped with a plain error, so one hung
 * request cannot hold up every turn after it.
 */
export async function* understand(request: UnderstandRequest, signal?: AbortSignal, timeoutMs = UNDERSTAND_TIMEOUT_MS): AsyncGenerator<PipelineEvent> {
  const limit = deadline(timeoutMs, signal);
  let reader: ReadableStreamDefaultReader<string> | null = null;
  try {
    let response: Response;
    try {
      response = await fetch("/api/understand", {
        method: "POST",
        headers: { "content-type": "application/json", accept: "text/event-stream" },
        body: JSON.stringify(request),
        signal: limit.signal,
      });
    } catch (error) {
      if ((error as Error).name === "AbortError" && !limit.expired()) throw error;
      if (limit.expired()) throw tooSlow(timeoutMs);
      throw new PlainError("The server is not reachable. Is it running? Replays still work without it.");
    }
    if (!response.ok || !response.body) throw await explain(response, "understand the turn");

    reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
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
  } catch (error) {
    if (limit.expired()) throw tooSlow(timeoutMs);
    throw error;
  } finally {
    limit.clear();
    // Stopped early (or failed): stop downloading the rest of the turn.
    reader?.cancel().catch(() => {});
  }
}

function tooSlow(ms: number) {
  return new PlainError(`The server took more than ${Math.round(ms / 1000)} s, so this turn was dropped. Please say it again.`);
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

export async function act(request: ActRequest, timeoutMs = ACT_TIMEOUT_MS): Promise<ActResponse> {
  const limit = deadline(timeoutMs);
  try {
    let response: Response;
    try {
      response = await fetch("/api/act", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(request),
        signal: limit.signal,
      });
    } catch {
      throw new PlainError(limit.expired() ? "The server took too long, so nothing was done." : "The server is not reachable, so nothing was done.");
    }
    if (!response.ok) throw await explain(response, "work out the action");
    return (await response.json()) as ActResponse;
  } catch (error) {
    if (limit.expired()) throw new PlainError("The server took too long, so nothing was done.");
    throw error;
  } finally {
    limit.clear();
  }
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
