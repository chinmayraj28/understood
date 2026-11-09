// Review findings 1, 2, 4 and 5: what counts as a yes, what happens to anything else, how long
// a question waits, and that messages and calls always ask first.
import { describe, expect, it } from "vitest";
import type { ActResponse, Decision, HearerName, PipelineEvent } from "../../shared/pipeline";
import { afterAct, isExpired, PENDING_LIFETIME_MS, resolveDecision, type Pending } from "../../src/model/answers";
import { classifyAnswer } from "../../src/model/learning";
import { PHONE_HOME, phoneAsk } from "../../src/model/phone";
import { newTurn, reduceTurn, type TurnModel } from "../../src/model/turn";

function turn(heard: Partial<Record<HearerName, string>>, decision: Decision): TurnModel {
  let t = newTurn({ turnId: `t-${Math.random()}`, origin: "live" });
  const events: PipelineEvent[] = [{ type: "turn.started", turnId: t.turnId, at: 0, keyterms: [], exampleCount: 0 }];
  for (const [hearer, text] of Object.entries(heard) as [HearerName, string][]) {
    events.push({ type: "hear.started", hearer, at: 1 }, { type: "hear.done", hearer, at: 2, text, seconds: 0.5 });
  }
  events.push({ type: "decision", at: 5, decision, rule: "test" }, { type: "turn.done", at: 6, seconds: 0.006 });
  for (const event of events) t = reduceTurn(t, event, 0);
  return t;
}

const message: ActResponse = { action: { kind: "message", to: "Mum", text: "I'm running late" }, reply: "Send \"I'm running late\" to Mum?", needsConfirmation: true };
const waitingToSend = (): Pending => afterAct(message, PHONE_HOME, "Message Mum I'm running late").pending!;

describe("A yes is only a yes (finding 1)", () => {
  it.each(["yes", "Yes please.", "yeah", "okay", "go ahead", "send it", "do it", "that's right", "yes, thank you"])("%s is a yes", (text) => {
    expect(classifyAnswer(text).kind).toBe("yes");
  });

  it.each(["Okay, message Sam instead", "yes but to Sam", "right, call Dad", "please play some music", "sure, set a timer"])(
    "%s is not a yes",
    (text) => {
      expect(classifyAnswer(text).kind).not.toBe("yes");
    },
  );

  it("\"Okay, message Sam instead\" does not send to Mum: it cancels and becomes a new request", () => {
    const outcome = resolveDecision(turn({ scribe: "Okay, message Sam instead." }, { kind: "act", text: "Okay, message Sam instead" }), waitingToSend(), []);
    const phone = outcome.phone!(phoneAsk(PHONE_HOME, message.action, "Send it?"));
    expect(phone.messages).toHaveLength(0);
    expect(phone.screen).toBe("home");
    expect(outcome.pending).toBeUndefined();
    expect(outcome.actOn).toBe("Okay, message Sam instead");
  });

  it("\"no, Sam\" still corrects the name", () => {
    const asked = turn({ scribe: "Message Mum I'm running late." }, { kind: "confirm", question: "Message Mum?", reading: "Message Mum I'm running late" });
    const pending: Pending = { kind: "understand", question: "Message Mum?", reading: "Message Mum I'm running late", expectedAnswers: ["yes", "no"], subject: asked };
    const outcome = resolveDecision(turn({ scribe: "No, Sam." }, { kind: "act", text: "no, Sam" }), pending, []);
    expect(outcome.actOn).toBe("Message Sam I'm running late");
  });

  it("one unclear word gets the question again and sends nothing", () => {
    const outcome = resolveDecision(turn({ scribe: "Hmm." }, { kind: "act", text: "hmm" }), waitingToSend(), []);
    expect(outcome.pending?.kind).toBe("action");
    expect(outcome.say).toMatch(/^Please say yes or no\./);
    expect(outcome.phone).toBeUndefined();
  });
});

describe("The page's own re-prompt is never a yes (finding 2)", () => {
  it("\"Please say yes or no. Send … to Mum?\" heard back is not a yes", () => {
    expect(classifyAnswer("Please say yes or no. Send \"I'm running late\" to Mum?").kind).not.toBe("yes");
  });
});

describe("Questions expire (finding 4)", () => {
  it("a question older than a minute has expired", () => {
    const pending = { ...waitingToSend(), createdAt: 1_000 };
    expect(isExpired(pending, 1_000 + PENDING_LIFETIME_MS - 1)).toBe(false);
    expect(isExpired(pending, 1_000 + PENDING_LIFETIME_MS + 1)).toBe(true);
  });
});

describe("Messages and calls always ask first (finding 5)", () => {
  it("asks before a message even when the server's flag says it need not", () => {
    const outcome = afterAct({ ...message, needsConfirmation: false, reply: "Sent." }, PHONE_HOME, "Message Mum I'm running late");
    expect(outcome.pending?.kind).toBe("action");
    expect(outcome.phone.screen).toBe("confirm");
    expect(outcome.phone.messages).toHaveLength(0);
  });

  it("asks before a call even when the server's flag says it need not", () => {
    const outcome = afterAct({ action: { kind: "call", to: "Sam" }, reply: "Calling Sam.", needsConfirmation: false }, PHONE_HOME, "Call Sam");
    expect(outcome.say).toBe("Call Sam?");
    expect(outcome.phone.screen).toBe("confirm");
  });

  it("a timer still goes ahead without a question", () => {
    const outcome = afterAct({ action: { kind: "timer", minutes: 2 }, reply: "Timer set.", needsConfirmation: false }, PHONE_HOME, "Set a timer");
    expect(outcome.pending).toBeUndefined();
    expect(outcome.phone.screen).toBe("timer");
  });
});
