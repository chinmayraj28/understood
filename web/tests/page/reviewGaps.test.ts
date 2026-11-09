// The page review's test gaps a, b, c, d and f, through the real Conversation with a fake server.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ActRequest, ActResponse, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { understand as realUnderstand } from "../../src/api/client";
import { resolveDecision } from "../../src/model/answers";
import { afterAct } from "../../src/model/answers";
import { Conversation } from "../../src/model/conversation";
import { PHONE_HOME } from "../../src/model/phone";
import { newTurn } from "../../src/model/turn";
import type { Transport } from "../../src/model/transport";
import { MemoryStore } from "../../src/storage/store";

/** Hears each turn as its realtime text, decides "act", and can be told to hold a turn back. */
class FakeServer implements Transport {
  readonly kind = "live" as const;
  onSpeaking: (speaking: boolean) => void = () => {};
  understood: UnderstandRequest[] = [];
  spoken: string[] = [];
  hold: Promise<void> | null = null;
  failNext: ((request: UnderstandRequest, signal?: AbortSignal) => AsyncIterable<PipelineEvent>) | null = null;

  understand(request: UnderstandRequest, signal?: AbortSignal): AsyncIterable<PipelineEvent> {
    if (this.failNext) {
      const fail = this.failNext;
      this.failNext = null;
      return fail(request, signal);
    }
    return this.answer(request);
  }
  private async *answer(request: UnderstandRequest): AsyncGenerator<PipelineEvent> {
    this.understood.push(request);
    const hold = this.hold;
    this.hold = null;
    if (hold) await hold;
    const text = request.realtimeText ?? "";
    yield { type: "turn.started", turnId: request.turnId, at: 0, keyterms: [], exampleCount: 0 };
    yield { type: "hear.started", hearer: "scribe", at: 1 };
    yield { type: "hear.started", hearer: "realtime", at: 1 };
    yield { type: "hear.done", hearer: "realtime", at: 2, text: text.toLowerCase(), seconds: 0 };
    yield { type: "hear.done", hearer: "scribe", at: 3, text: text.replace(/Sam/, "some"), seconds: 0.4 };
    yield { type: "decision", at: 4, decision: { kind: "act", text }, rule: "test" };
    yield { type: "turn.done", at: 5, seconds: 0.005 };
  }
  async act(request: ActRequest): Promise<ActResponse> {
    if (/message sam/i.test(request.text)) return { action: { kind: "message", to: "Sam", text: "I'm running late" }, reply: "Send \"I'm running late\" to Sam?", needsConfirmation: true };
    if (/message mum/i.test(request.text)) return { action: { kind: "message", to: "Mum", text: "running late" }, reply: "Send 'running late' to Mum?", needsConfirmation: true };
    return { action: { kind: "none" }, reply: "I can't do that.", needsConfirmation: false };
  }
  async speak(text: string) {
    this.spoken.push(text);
  }
  stopSpeaking() {}
}

async function setUp() {
  const server = new FakeServer();
  const conversation = await Conversation.create(server, new MemoryStore());
  const say = (text: string, speechStartedAt = performance.now() + 1) =>
    conversation.submitTurn({ wavBase64: "", realtimeText: text, liveText: text, origin: "live", speechStartedAt });
  return { server, conversation, say };
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("a) Not-quite-yes answers never perform the waiting action", () => {
  const waiting = afterAct({ action: { kind: "message", to: "Mum", text: "running late" }, reply: "Send 'running late' to Mum?", needsConfirmation: true }, PHONE_HOME, "Message Mum running late");
  it.each(["Okay, message Sam instead", "Right, call Dad", "yes but to Sam", "please message Sam", "Please say yes or no. Send running late to Mum?"])("%s", (text) => {
    const turn = { ...newTurn({ turnId: "t", origin: "live" }), decision: { decision: { kind: "act" as const, text }, rule: "", at: 0 } };
    const outcome = resolveDecision(turn, waiting.pending, []);
    const phone = outcome.phone ? outcome.phone(waiting.phone) : waiting.phone;
    expect(phone.messages).toHaveLength(0);
    expect(outcome.say ?? "").not.toMatch(/^Sent/);
  });
});

describe("b) A yes queued while the previous turn was still running does not confirm its question", () => {
  it("is refused, and the question is asked again", async () => {
    const { server, conversation, say } = await setUp();
    let release: () => void = () => {};
    server.hold = new Promise<void>((resolve) => (release = resolve));
    const first = say("Message Sam I'm running late");
    // The person says "yes" while the first turn is still being understood: before any question.
    const early = say("yes", performance.now());
    release();
    await first;
    await early;
    expect(conversation.getState().phone.messages).toHaveLength(0);
    expect(server.spoken.filter((s) => s.startsWith("Send"))).toHaveLength(2);
  });
});

describe("c) A stale question does nothing", () => {
  it("a yes long after the question sends nothing", async () => {
    const { conversation, say } = await setUp();
    await say("Message Sam I'm running late");
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 5 * 60_000);
    await say("yes");
    expect(conversation.getState().phone.messages).toHaveLength(0);
  });

  it("a yes after an unrelated request sends nothing", async () => {
    const { conversation, say } = await setUp();
    await say("Message Sam I'm running late");
    await say("play some music");
    await say("yes");
    expect(conversation.getState().phone.messages).toHaveLength(0);
  });
});

describe("d) After Clear everything, a later yes learns nothing from before", () => {
  it("the old question and what was heard before are gone", async () => {
    const { conversation, say } = await setUp();
    await say("Message Sam I'm running late");
    await conversation.clearEverything();
    await say("yes");
    expect(conversation.getState().entries).toEqual([]);
    expect(conversation.getState().phone.messages).toHaveLength(0);
  });
});

describe("f) A server that never answers", () => {
  it("ends the turn with a plain error, clears busy, and the next turn runs", async () => {
    const { server, conversation, say } = await setUp();
    vi.stubGlobal("fetch", (_url: string, init: RequestInit) => new Promise((_r, reject) => init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))));
    server.failNext = (request, signal) => realUnderstand(request, signal, 50);
    await say("Message Sam I'm running late");
    const state = conversation.getState();
    expect(state.busy).toBe(false);
    expect(state.turns[0].failed).toMatch(/took more than/);
    expect(state.chat.at(-1)?.tone).toBe("error");
    await say("Message Sam I'm running late");
    expect(conversation.getState().pending?.kind).toBe("action");
  });
});
