// Review findings 2, 3, 4 and 7, through the real Conversation with a fake server:
// the assistant's own voice is not a turn, an answer must come after its question, questions
// expire, and "Clear everything" forgets everything.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ActRequest, ActResponse, Decision, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { Conversation } from "../../src/model/conversation";
import type { Transport } from "../../src/model/transport";
import { MemoryStore } from "../../src/storage/store";

/** A pretend server: every turn is heard as its realtime text and decided "act" on it. */
class FakeServer implements Transport {
  readonly kind = "live" as const;
  onSpeaking: (speaking: boolean) => void = () => {};
  understood: UnderstandRequest[] = [];
  acted: string[] = [];
  spoken: string[] = [];

  async *understand(request: UnderstandRequest): AsyncGenerator<PipelineEvent> {
    this.understood.push(request);
    const text = request.realtimeText ?? "";
    const decision: Decision = { kind: "act", text };
    yield { type: "turn.started", turnId: request.turnId, at: 0, keyterms: [], exampleCount: 0 };
    yield { type: "hear.started", hearer: "scribe", at: 1 };
    yield { type: "hear.done", hearer: "scribe", at: 2, text, seconds: 0.4 };
    yield { type: "decision", at: 3, decision, rule: "test" };
    yield { type: "turn.done", at: 4, seconds: 0.004 };
  }
  async act(request: ActRequest): Promise<ActResponse> {
    this.acted.push(request.text);
    if (/message sam/i.test(request.text)) {
      return { action: { kind: "message", to: "Sam", text: "I'm running late" }, reply: "Send \"I'm running late\" to Sam?", needsConfirmation: true };
    }
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
  const say = (text: string, speechStartedAt: number = performance.now() + 1, wavBase64 = "") =>
    conversation.submitTurn({ wavBase64, realtimeText: text, liveText: text, origin: "live", speechStartedAt });
  await say("Message Sam I'm running late");
  return { server, conversation, say };
}

afterEach(() => vi.restoreAllMocks());

describe("An answer must come after its question (finding 3)", () => {
  it("stamps when the question finished playing", async () => {
    const { conversation } = await setUp();
    expect(conversation.getState().pending?.kind).toBe("action");
    expect(conversation.getState().pending?.askedAt).toBeTypeOf("number");
  });

  it("a yes that started before the question finished does not send, and the question is asked again", async () => {
    const { conversation, server, say } = await setUp();
    const askedAt = conversation.getState().pending!.askedAt!;
    await say("yes", askedAt - 200);
    expect(conversation.getState().phone.messages).toHaveLength(0);
    expect(server.understood).toHaveLength(1); // the early yes never went to the server
    expect(server.spoken.at(-1)).toBe("Send \"I'm running late\" to Sam?");
    // A yes after the repeated question does send.
    await say("yes");
    expect(conversation.getState().phone.messages).toHaveLength(1);
  });
});

describe("The assistant's own voice is not a turn (finding 2)", () => {
  it("drops a turn that matches what the assistant just said", async () => {
    const { conversation, server, say } = await setUp();
    await say("Send I'm running late to Sam");
    expect(server.understood).toHaveLength(1);
    expect(conversation.getState().phone.messages).toHaveLength(0);
    expect(conversation.getState().pending?.kind).toBe("action");
  });
});

describe("Questions expire (finding 4)", () => {
  it("after a minute, a yes no longer answers the old question", async () => {
    const { conversation, server, say } = await setUp();
    const now = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(now + 61_000);
    await say("yes");
    expect(conversation.getState().phone.messages).toHaveLength(0);
    expect(conversation.getState().phone.screen).toBe("home");
    expect(conversation.getState().chat.some((l) => /went unanswered for a minute/.test(l.text))).toBe(true);
    expect(server.understood.at(-1)?.context.pendingQuestion).toBeUndefined();
  });

  it("an unrelated request clears the question and cancels the waiting message", async () => {
    const { conversation, server, say } = await setUp();
    await say("play some music");
    expect(conversation.getState().pending).toBeUndefined();
    expect(conversation.getState().phone.screen).toBe("home");
    expect(server.acted.at(-1)).toBe("play some music");
  });
});

describe("Clear everything forgets everything (finding 7)", () => {
  it("resets turns, the question, the conversation and kept recordings", async () => {
    const { conversation, say } = await setUp();
    await say("hmm", performance.now() + 1, "UklGRg==");
    await conversation.clearEverything();
    const state = conversation.getState();
    expect(state.turns).toEqual([]);
    expect(state.pending).toBeUndefined();
    expect(state.chat).toEqual([]);
    expect(state.entries).toEqual([]);
    expect(state.phone.messages).toEqual([]);
    expect((conversation as unknown as { wavByTurn: Map<string, string> }).wavByTurn.size).toBe(0);
    expect((conversation as unknown as { recent: string[] }).recent).toEqual([]);
  });

  it("keeps at most twelve recordings in memory", async () => {
    const { conversation, say } = await setUp();
    for (let i = 0; i < 20; i++) await say(`turn number ${i}`, performance.now() + 1, "UklGRg==");
    expect((conversation as unknown as { wavByTurn: Map<string, string> }).wavByTurn.size).toBeLessThanOrEqual(12);
  });
});
