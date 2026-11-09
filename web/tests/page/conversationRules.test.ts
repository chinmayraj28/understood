// The page's own rules after a decision (web/src/model/answers.ts, learning.ts): when it learns,
// when it asks, what it says, and how it reads the event stream.
import { describe, expect, it } from "vitest";
import type { ActResponse, Decision, HearerName, PipelineEvent } from "../../shared/pipeline";
import { parseBlock } from "../../src/api/client";
import { afterAct, correction, doneSentence, resolveDecision, type Pending } from "../../src/model/answers";
import { chooseExamples, classifyAnswer, matchOption, type Clip } from "../../src/model/learning";
import { PHONE_HOME } from "../../src/model/phone";
import { newTurn, reduceTurn, type TurnModel } from "../../src/model/turn";

/** A finished turn: what each recogniser heard, Claude's reading, and the decision. */
function turn(heard: Partial<Record<HearerName, string>>, decision: Decision, alternatives: string[] = []): TurnModel {
  let t = newTurn({ turnId: `t-${Math.random()}`, origin: "live" });
  const events: PipelineEvent[] = [{ type: "turn.started", turnId: t.turnId, at: 0, keyterms: [], exampleCount: 0 }];
  for (const [hearer, text] of Object.entries(heard) as [HearerName, string][]) {
    events.push({ type: "hear.started", hearer, at: 1 }, { type: "hear.done", hearer, at: 2, text, seconds: 0.5 });
  }
  events.push(
    { type: "repair.started", at: 3 },
    { type: "repair.done", at: 4, seconds: 1, reading: { text: "x", confidence: "medium", alternatives, reason: "" } },
    { type: "decision", at: 5, decision, rule: "test" },
    { type: "turn.done", at: 6, seconds: 0.006 },
  );
  for (const event of events) t = reduceTurn(t, event, 0);
  return t;
}

const act = (text: string) => ({ kind: "act" as const, text });

describe("Answers", () => {
  it("reads yes, no, and a no with a correction", () => {
    expect(classifyAnswer("Yeah.").kind).toBe("yes");
    expect(classifyAnswer("no").kind).toBe("no");
    expect(classifyAnswer("No, Sam")).toEqual({ kind: "no", rest: "sam" });
    expect(classifyAnswer("play some music").kind).toBe("other");
  });

  it("picks an option by the words that tell the options apart", () => {
    const options = ["Remind me to ring Amma at six", "Remind me to ring Mum at six"];
    expect(matchOption("Amma", options)).toBe(options[0]);
    expect(matchOption("mum", options)).toBe(options[1]);
    expect(matchOption("at six", options)).toBeNull(); // shared words pick nothing
  });

  it("turns \"no, Sam\" into the same sentence with the name swapped", () => {
    const subject = turn({ scribe: "Message Mum I'm late" }, { kind: "confirm", question: "Message Mum?", reading: "Message Mum I'm late" });
    expect(correction("sam", "Message Mum I'm late", subject)).toBe("Message Sam I'm late");
  });
});

describe("What the page learns", () => {
  const question = turn(
    { scribe: "Message Mum, I'm running late.", gemini: "Message mom I'm running late.", realtime: "massage some I'm running late" },
    { kind: "confirm", question: "Message Mum?", reading: "Message Mum I'm running late" },
  );
  const pending: Pending = { kind: "understand", question: "Message Mum?", reading: "Message Mum I'm running late", expectedAnswers: ["yes", "no"], subject: question };

  it("learns from a spoken yes: one pair for each recogniser that heard something else", () => {
    const outcome = resolveDecision(turn({ scribe: "Yes." }, act("yes")), pending, []);
    expect(outcome.actOn).toBe("Message Mum I'm running late");
    const pairs = outcome.learned!.entries.map((e) => `${e.hearer}: ${e.heard}`);
    expect(pairs).toContain("gemini: Message mom I'm running late.");
    expect(pairs).toContain("realtime: massage some I'm running late");
    expect(pairs.some((p) => p.startsWith("scribe"))).toBe(false); // Scribe heard it right
  });

  it("learns nothing from a plain no, and counts a failed try", () => {
    const outcome = resolveDecision(turn({ scribe: "No." }, act("no")), pending, []);
    expect(outcome.learned).toBeUndefined();
    expect(outcome.actOn).toBeUndefined();
    expect(outcome.failed).toBe(true);
  });

  it("learns the corrected meaning from \"no, Sam\"", () => {
    const outcome = resolveDecision(turn({ scribe: "No, Sam." }, act("no, Sam")), pending, []);
    expect(outcome.actOn).toBe("Message Sam I'm running late");
    expect(outcome.learned!.entries.every((e) => e.meant === "Message Sam I'm running late" && e.source === "correction")).toBe(true);
  });

  it("learns nothing from an action that simply went ahead", () => {
    const outcome = resolveDecision(turn({ scribe: "Play some music." }, act("Play some music")), undefined, []);
    expect(outcome.actOn).toBe("Play some music");
    expect(outcome.learned).toBeUndefined();
  });

  it("bumps an existing pair instead of adding a second one", () => {
    const first = resolveDecision(turn({ scribe: "Yes." }, act("yes")), pending, []).learned!.entries;
    const second = resolveDecision(turn({ scribe: "Yes." }, act("yes")), pending, first).learned!.entries;
    expect(second).toHaveLength(first.length);
    expect(second.find((e) => e.hearer === "realtime")!.timesConfirmed).toBe(2);
  });

  it("learns the chosen option", () => {
    const options = ["Remind me to ring Amma at six", "Remind me to ring Mum at six"];
    const asked = turn({ scribe: "Remind me to ring Mum at six.", gemini: "Remind me to ring Amma at six." }, { kind: "choose", question: "Amma or Mum?", options });
    const choose: Pending = { kind: "choose", question: "Amma or Mum?", options, expectedAnswers: ["amma", "mum", "no"], subject: asked };
    const outcome = resolveDecision(turn({ gemini: "Amma." }, act("Amma")), choose, []);
    expect(outcome.actOn).toBe(options[0]);
    expect(outcome.learned!.entries.map((e) => e.hearer)).toEqual(["scribe"]);
  });
});

describe("Anything that reaches a person waits for a yes", () => {
  const message: ActResponse = { action: { kind: "message", to: "Mum", text: "I'm running late" }, reply: "Send \"I'm running late\" to Mum?", needsConfirmation: true };

  it("asks the server's question and shows the confirm sheet, without sending", () => {
    const outcome = afterAct(message, PHONE_HOME, "Message Mum I'm running late");
    expect(outcome.say).toBe("Send \"I'm running late\" to Mum?");
    expect(outcome.pending?.kind).toBe("action");
    expect(outcome.phone.screen).toBe("confirm");
    expect(outcome.phone.messages).toHaveLength(0);
  });

  it("sends after a yes, and says it is done rather than asking again", () => {
    const pending = afterAct(message, PHONE_HOME, "Message Mum I'm running late").pending!;
    const outcome = resolveDecision(turn({ scribe: "Yes." }, act("yes")), pending, []);
    expect(outcome.phone!(PHONE_HOME).messages).toHaveLength(1);
    expect(outcome.say).toBe("Sent to Mum.");
    expect(doneSentence(message)).toBe("Sent to Mum.");
  });

  it("sends nothing after a no", () => {
    const pending = afterAct(message, PHONE_HOME, "Message Mum I'm running late").pending!;
    const outcome = resolveDecision(turn({ scribe: "No." }, act("no")), pending, []);
    expect(outcome.phone!(PHONE_HOME).messages).toHaveLength(0);
  });
});

describe("Gemini's examples", () => {
  it("picks the three most recent clips, then the hardest, five at most", () => {
    const clips: Clip[] = Array.from({ length: 8 }, (_, i) => ({ id: `c${i}`, text: `t${i}`, wavBase64: "", createdAt: i, source: "enrolment", difficulty: i === 0 ? 0.9 : i === 1 ? 0.8 : 0.1 }));
    expect(chooseExamples(clips).map((e) => e.text)).toEqual(["t7", "t6", "t5", "t0", "t1"]);
  });
});

describe("The event stream", () => {
  it("parses a data: block and ignores comments and broken JSON", () => {
    expect(parseBlock('data: {"type":"turn.done","at":5,"seconds":1}')).toEqual({ type: "turn.done", at: 5, seconds: 1 });
    expect(parseBlock(": keep-alive")).toBeNull();
    expect(parseBlock("data: {broken")).toBeNull();
  });
});
