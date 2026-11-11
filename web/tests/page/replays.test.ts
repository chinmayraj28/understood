// Every example on the page, played through the real Conversation with the ReplayTransport
// sped up 200 times: the same code a live turn runs, minus the microphone and the server.
import { describe, expect, it } from "vitest";
import { REPLAYS, type Replay } from "../fixtures";
import { Conversation, type ConversationState } from "../../src/model/conversation";
import { ReplayTransport } from "../fixtures/replayTransport";
import { MemoryStore } from "../../src/storage/store";

async function play(id: string): Promise<ConversationState> {
  const replay = REPLAYS.find((r) => r.id === id) as Replay;
  const conversation = await Conversation.create(new ReplayTransport(replay, 200), new MemoryStore(replay.phrasebook));
  for (const turn of replay.turns) {
    const text = turn.partials.at(-1)?.[1] ?? "";
    await conversation.submitTurn({ wavBase64: "", realtimeText: text || undefined, liveText: text, speechSeconds: turn.speechSeconds, origin: "live" });
  }
  return conversation.getState();
}

const said = (state: ConversationState) => state.chat.filter((l) => l.who === "assistant").map((l) => l.text);
const timesFor = (state: ConversationState, hearer: string, heard: string) =>
  state.entries.find((e) => e.hearer === hearer && e.heard === heard)?.timesConfirmed;

describe("Example replays, end to end", () => {
  it("every example's events arrive in the contract's order and finish", () => {
    for (const replay of REPLAYS) {
      for (const turn of replay.turns) {
        const types = turn.events.map((e) => e.type);
        expect(types[0]).toBe("turn.started");
        expect(types.at(-1)).toBe("turn.done");
        expect(types.indexOf("agreement")).toBeLessThan(types.indexOf("phrasebook"));
        expect(types.indexOf("phrasebook")).toBeLessThan(types.indexOf("decision"));
        const times = turn.events.map((e) => e.at);
        expect([...times].sort((a, b) => a - b)).toEqual(times);
      }
    }
  });

  it("Call Sam: asks before calling, calls after the yes, and bumps each recogniser's own pair", async () => {
    const state = await play("call-sam");
    expect(said(state)).toEqual(["Call Sam?", "Calling Sam."]);
    expect(state.phone.screen).toBe("call");
    expect(timesFor(state, "scribe", "call some")).toBe(4);
    expect(timesFor(state, "realtime", "call some")).toBe(3);
  });

  it("Message Mum?: two questions, two yeses, two pairs learned, one message sent", async () => {
    const state = await play("message-mum");
    expect(said(state)).toEqual(["Message Mum?", "Send “I'm running late” to Mum?", "Sent to Mum."]);
    expect(state.phone.messages).toEqual([expect.objectContaining({ to: "Mum", text: "I'm running late" })]);
    expect(state.entries.filter((e) => e.meant === "Message Mum I'm running late").map((e) => e.hearer).sort()).toEqual(["gemini", "realtime"]);
  });

  it("A plain no: learns nothing, and the timer that simply went ahead teaches nothing either", async () => {
    const replay = REPLAYS.find((r) => r.id === "plain-no")!;
    const state = await play("plain-no");
    expect(said(state)[1]).toMatch(/^Okay, I won't/);
    expect(state.phone.screen).toBe("timer");
    expect(state.entries).toEqual(replay.phrasebook);
    expect(state.failedTries).toBe(0); // reset once it acted
  });

  it("Amma or Mum?: the chosen option is acted on and learned", async () => {
    const state = await play("amma-or-mum");
    expect(state.phone.reminders).toEqual([{ text: "Ring Amma", when: "6:00 pm" }]);
    expect(state.entries.some((e) => e.hearer === "scribe" && e.meant === "Remind me to ring Amma at six")).toBe(true);
  });

  it("Gemini is slow: still acts on the other two", async () => {
    const state = await play("gemini-timeout");
    expect(state.turns[0].lanes.gemini.status).toBe("failed");
    expect(state.phone.screen).toBe("music");
  });

  it("Nothing works: says it cannot hear, does nothing, counts a failed try", async () => {
    const state = await play("nothing-heard");
    expect(said(state)[0]).toMatch(/can't hear/);
    expect(state.phone.screen).toBe("home");
    expect(state.failedTries).toBe(1);
    expect(state.chat.some((l) => l.who === "you")).toBe(false);
  });
});
