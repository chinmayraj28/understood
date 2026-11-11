// Each decision reaches a screen reader exactly once: as one line in the conversation log (the
// turn's only live region). The page-level region stays silent for it and speaks only failures.
import { describe, expect, it } from "vitest";
import { REPLAYS } from "../../src/fixtures";
import { Conversation, type ConversationState } from "../../src/model/conversation";
import { ReplayTransport } from "../../src/model/transport";
import { pageAnnouncement } from "../../src/model/turn";
import { MemoryStore } from "../../src/storage/store";

/** Plays an example's turns, recording the page-level announcement after each one. */
async function play(id: string) {
  const replay = REPLAYS.find((r) => r.id === id)!;
  const conversation = await Conversation.create(new ReplayTransport(replay, 200), new MemoryStore(replay.phrasebook));
  const pageSaid: string[] = [];
  for (const turn of replay.turns) {
    const text = turn.partials.at(-1)?.[1] ?? "";
    await conversation.submitTurn({ wavBase64: "", realtimeText: text || undefined, liveText: text, origin: "replay" });
    const latest = conversation.getState().turns.at(-1);
    const said = pageAnnouncement(latest);
    if (said) pageSaid.push(said);
  }
  return { state: conversation.getState(), pageSaid };
}

const assistantLines = (state: ConversationState, text: string) => state.chat.filter((l) => l.who === "assistant" && l.text === text);

describe("A decision is announced exactly once", () => {
  it("\"Message Mum?\": each question appears once in the log, and the page region says nothing", async () => {
    const { state, pageSaid } = await play("message-mum");
    expect(assistantLines(state, "Message Mum?")).toHaveLength(1);
    expect(assistantLines(state, "Send “I'm running late” to Mum?")).toHaveLength(1);
    expect(assistantLines(state, "Sent to Mum.")).toHaveLength(1);
    expect(pageSaid).toEqual([]);
  });

  it("\"Nothing works\": the cannot-hear message appears once in the log, and the page region says nothing", async () => {
    const { state, pageSaid } = await play("nothing-heard");
    expect(state.chat.filter((l) => l.who === "assistant")).toHaveLength(1);
    expect(pageSaid).toEqual([]);
  });

  it("a failed turn is announced once, by the page region", () => {
    const failed = { stage: "done", failed: "The server took more than 15 s, so this turn was dropped." } as Parameters<typeof pageAnnouncement>[0];
    expect(pageAnnouncement(failed)).toBe("The turn failed. The server took more than 15 s, so this turn was dropped.");
    expect(pageAnnouncement(undefined)).toBe("");
  });
});
