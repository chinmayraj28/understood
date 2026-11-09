// Example conversations 1 and 2. Made-up text, labelled as examples on the page.

import { actKey, entry, replayTurn, type Replay } from "./build";

const yesTurn = (turnId: string, live = "yes") =>
  replayTurn(
    {
      turnId,
      exampleCount: 5,
      hear: [
        { hearer: "realtime", start: 0, seconds: 0, text: live },
        { hearer: "scribe", start: 2, seconds: 0.48, text: live === "yes" ? "Yes." : "Yeah." },
        { hearer: "gemini", start: 3, seconds: 1.31, text: "Yes." },
      ],
      disputed: live === "yes" ? [] : ["yeah", "yes"],
      repair: { skipped: "The answer matched one of the expected answers, so Claude was not needed." },
      decision: { kind: "act", text: "yes" },
      rule:
        live === "yes"
          ? "All three recognisers heard \"yes\", one of the answers it was waiting for."
          : "Every recogniser heard a word that means yes, one of the answers it was waiting for.",
    },
    live,
    0.9,
  );

export const callSam: Replay = {
  id: "call-sam",
  title: "Call Sam",
  summary: "Two recognisers hear \"call some\". The phrasebook remembers what that has meant before.",
  phrasebook: [
    entry("call some", "call Sam", "scribe", 3),
    entry("call some", "call Sam", "realtime", 2),
    entry("muse it", "music", "realtime", 1, "enrolment"),
  ],
  turns: [
    replayTurn(
      {
        turnId: "example-call-1",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "call some" },
          { hearer: "scribe", start: 2, seconds: 0.71, text: "Call some." },
          { hearer: "gemini", start: 3, seconds: 1.84, text: "Call Sam." },
        ],
        disputed: ["some", "sam"],
        phrasebook: {
          entryId: "ex-call-some-scribe",
          meant: "call Sam",
          heard: "call some",
          similarity: 1,
          timesConfirmed: 3,
          strong: true,
        },
        repair: {
          seconds: 0.82,
          reading: {
            text: "Call Sam",
            confidence: "high",
            alternatives: [],
            reason: "Your phrasebook says \"call some\" has meant \"call Sam\" three times, and Gemini heard Sam too.",
          },
        },
        decision: { kind: "act", text: "Call Sam" },
        rule: "A phrasebook entry you confirmed 3 times matched exactly, and Claude was sure, so it acts.",
      },
      "call some",
      1.8,
    ),
    yesTurn("example-call-2"),
  ],
  acts: {
    [actKey("Call Sam")]: { action: { kind: "call", to: "Sam" }, reply: "Calling Sam.", needsConfirmation: true },
  },
};

export const messageMum: Replay = {
  id: "message-mum",
  title: "Message Mum?",
  summary: "The recognisers hear three different names. The name decides who gets the message, so it asks.",
  phrasebook: [entry("call some", "call Sam", "scribe", 3)],
  turns: [
    replayTurn(
      {
        turnId: "example-message-1",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "massage some I'm running late" },
          { hearer: "scribe", start: 2, seconds: 0.86, text: "Message Mum, I'm running late." },
          { hearer: "gemini", start: 3, seconds: 2.12, text: "Message mom I'm running late." },
        ],
        disputed: ["massage", "message", "some", "mum", "mom"],
        phrasebook: null,
        repair: {
          seconds: 1.04,
          reading: {
            text: "Message Mum I'm running late",
            confidence: "medium",
            alternatives: ["Message Sam I'm running late"],
            reason: "Scribe and Gemini agree it is a message about running late; the name sounds like Mum, but \"some\" could be Sam.",
          },
        },
        decision: { kind: "confirm", question: "Message Mum?", reading: "Message Mum I'm running late" },
        rule: "The recognisers heard different names, and the name decides who gets the message, so it asks first.",
      },
      "massage some I'm running late",
      4.6,
      1,
    ),
    yesTurn("example-message-2", "yeah"),
    yesTurn("example-message-3"),
  ],
  acts: {
    [actKey("Message Mum I'm running late")]: {
      action: { kind: "message", to: "Mum", text: "I'm running late" },
      reply: "Sent to Mum.",
      needsConfirmation: true,
    },
  },
};
