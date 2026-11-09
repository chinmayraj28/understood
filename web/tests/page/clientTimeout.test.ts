// Review finding 11: a server that never answers must not hold up every turn after it.
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, understand } from "../../src/api/client";
import type { UnderstandRequest } from "../../shared/pipeline";

const request: UnderstandRequest = {
  turnId: "t",
  wavBase64: "",
  phrasebook: [],
  examples: [],
  keyterms: [],
  context: {},
  switches: { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true },
};

/** A fetch that never answers, but stops when its signal aborts, as the browser's does. */
function hangingFetch() {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      (_url: string, init: RequestInit) =>
        new Promise((_resolve, reject) => {
          init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    ),
  );
}

/** A fetch that answers at once but whose event stream sends one event, then hangs. */
function stallingStream() {
  vi.stubGlobal(
    "fetch",
    vi.fn((_url: string, init: RequestInit) => {
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('data: {"type":"turn.started","turnId":"t","at":0,"keyterms":[],"exampleCount":0}\n\n'));
          init.signal?.addEventListener("abort", () => controller.error(new DOMException("aborted", "AbortError")));
        },
      });
      return Promise.resolve(new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } }));
    }),
  );
}

afterEach(() => vi.unstubAllGlobals());

async function drain(timeoutMs: number) {
  const events: string[] = [];
  for await (const event of understand(request, undefined, timeoutMs)) events.push(event.type);
  return events;
}

describe("Timeouts", () => {
  it("drops a turn whose request never gets an answer, with a plain message", async () => {
    hangingFetch();
    await expect(drain(50)).rejects.toThrow(/took more than/);
  });

  it("drops a turn whose event stream stalls part-way", async () => {
    stallingStream();
    const seen: string[] = [];
    await expect(
      (async () => {
        for await (const event of understand(request, undefined, 80)) seen.push(event.type);
      })(),
    ).rejects.toThrow(/took more than/);
    expect(seen).toEqual(["turn.started"]);
  });

  it("gives up on /api/act and does nothing", async () => {
    hangingFetch();
    await expect(act({ text: "Call Sam" }, 50)).rejects.toThrow(/took too long, so nothing was done/);
  });

  it("uses 15 s for a turn and 10 s for an action by default", async () => {
    const { UNDERSTAND_TIMEOUT_MS, ACT_TIMEOUT_MS } = await import("../../src/api/client");
    expect(UNDERSTAND_TIMEOUT_MS).toBe(15_000);
    expect(ACT_TIMEOUT_MS).toBe(10_000);
  });

  it("a stop from the page is still a stop, not a timeout", async () => {
    hangingFetch();
    const stop = new AbortController();
    const running = (async () => {
      for await (const _ of understand(request, stop.signal, 5_000)) void _;
    })();
    stop.abort();
    await expect(running).rejects.toMatchObject({ name: "AbortError" });
  });
});
