// Example conversations 3 to 6. Made-up text, labelled as examples on the page.

import { actKey, entry, replayTurn, type Replay } from "./build";

export const plainNo: Replay = {
  id: "plain-no",
  title: "A plain no",
  summary: "It asks about the number, hears no, learns nothing from it, and gets it right the second time.",
  phrasebook: [entry("call some", "call Sam", "scribe", 3)],
  turns: [
    replayTurn(
      {
        turnId: "example-timer-1",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "set a time for tan minutes" },
          { hearer: "scribe", start: 2, seconds: 0.74, text: "Set a timer for ten minutes." },
          { hearer: "gemini", start: 3, seconds: 1.66, text: "Set a timer for two minutes." },
        ],
        disputed: ["time", "timer", "tan", "ten", "two"],
        repair: {
          seconds: 0.93,
          reading: {
            text: "Set a timer for ten minutes",
            confidence: "medium",
            alternatives: ["Set a timer for two minutes"],
            reason: "It is clearly a timer, but Scribe heard ten and Gemini heard two.",
          },
        },
        decision: { kind: "confirm", question: "Ten minutes?", reading: "Set a timer for ten minutes" },
        rule: "Claude was only fairly sure, and the recognisers heard different numbers, so it asks one yes/no question.",
      },
      "set a time for tan minutes",
      3.2,
    ),
    replayTurn(
      {
        turnId: "example-timer-2",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "no" },
          { hearer: "scribe", start: 2, seconds: 0.45, text: "No." },
          { hearer: "gemini", start: 3, seconds: 1.22, text: "No." },
        ],
        repair: { skipped: "The answer matched one of the expected answers, so Claude was not needed." },
        decision: { kind: "act", text: "no" },
        rule: "All three recognisers heard \"no\", one of the answers it was waiting for.",
      },
      "no",
      0.8,
    ),
    replayTurn(
      {
        turnId: "example-timer-3",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "to minutes" },
          { hearer: "scribe", start: 2, seconds: 0.58, text: "Two minutes." },
          { hearer: "gemini", start: 3, seconds: 1.4, text: "Two minutes." },
        ],
        disputed: ["to", "two"],
        repair: {
          seconds: 0.88,
          reading: {
            text: "Set a timer for two minutes",
            confidence: "high",
            alternatives: [],
            reason: "You said no to ten minutes, and two minutes is what Gemini heard the first time.",
          },
        },
        decision: { kind: "act", text: "Set a timer for two minutes" },
        rule: "Two recognisers heard the same words and Claude was sure, so it acts.",
      },
      "to minutes",
      1.3,
    ),
  ],
  acts: {
    [actKey("Set a timer for two minutes")]: { action: { kind: "timer", minutes: 2 }, reply: "Timer set for two minutes.", needsConfirmation: false },
  },
};

export const geminiTimeout: Replay = {
  id: "gemini-timeout",
  title: "Gemini is slow",
  summary: "Gemini takes too long and is left out at four seconds. The other two agree, so it still acts.",
  phrasebook: [],
  turns: [
    replayTurn(
      {
        turnId: "example-music-1",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "play some music" },
          { hearer: "scribe", start: 2, seconds: 0.64, text: "Play some music." },
          { hearer: "gemini", start: 3, seconds: 4.0, text: "", failure: "No answer within 4 seconds, so it was left out." },
        ],
        repair: {
          seconds: 0.71,
          reading: {
            text: "Play some music",
            confidence: "high",
            alternatives: [],
            reason: "Scribe and the live transcript heard the same words, and it is a plain request.",
          },
        },
        decision: { kind: "act", text: "Play some music" },
        rule: "Gemini was left out, but the other two heard the same words and Claude was sure, so it acts.",
      },
      "play some music",
      1.9,
    ),
  ],
  acts: {
    [actKey("Play some music")]: { action: { kind: "music", query: "Your evening mix" }, reply: "Playing your evening mix.", needsConfirmation: false },
  },
};

export const nothingHeard: Replay = {
  id: "nothing-heard",
  title: "Nothing works",
  summary: "Every recogniser fails. It says so plainly instead of guessing.",
  phrasebook: [],
  turns: [
    {
      partials: [],
      speechSeconds: 2.2,
      events: [
        { type: "turn.started", turnId: "example-fail-1", at: 0, keyterms: ["Mum", "Sam"], exampleCount: 0 },
        { type: "hear.started", hearer: "realtime", at: 0 },
        { type: "hear.started", hearer: "scribe", at: 2 },
        { type: "hear.started", hearer: "gemini", at: 3 },
        { type: "hear.done", hearer: "realtime", at: 4, text: "", seconds: 0, failure: "The live transcript returned no words." },
        { type: "hear.done", hearer: "scribe", at: 312, text: "", seconds: 0.31, failure: "Scribe answered with an error (503)." },
        { type: "hear.done", hearer: "gemini", at: 447, text: "", seconds: 0.44, failure: "OpenRouter answered with an error (502)." },
        { type: "agreement", at: 460, contentWords: {}, agreeing: [], disputedWords: [] },
        { type: "phrasebook", at: 471, match: null },
        { type: "repair.skipped", at: 476, why: "Nothing was heard, so there is nothing to repair." },
        {
          type: "decision",
          at: 483,
          decision: { kind: "cannotHear", message: "I can't hear properly right now. Please try again in a moment." },
          rule: "No recogniser returned any words, so it says so instead of guessing.",
        },
        { type: "turn.done", at: 487, seconds: 0.49 },
      ],
    },
  ],
  acts: {},
};

export const ammaOrMum: Replay = {
  id: "amma-or-mum",
  title: "Amma or Mum?",
  summary: "Claude is unsure between two names, so it offers a choice. The answer teaches the phrasebook.",
  phrasebook: [entry("call some", "call Sam", "scribe", 3)],
  turns: [
    replayTurn(
      {
        turnId: "example-remind-1",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "remind me to ring um at six" },
          { hearer: "scribe", start: 2, seconds: 0.92, text: "Remind me to ring Mum at six." },
          { hearer: "gemini", start: 3, seconds: 2.31, text: "Remind me to ring Amma at six." },
        ],
        disputed: ["um", "mum", "amma"],
        repair: {
          seconds: 1.12,
          reading: {
            text: "Remind me to ring Amma at six",
            confidence: "low",
            alternatives: ["Remind me to ring Mum at six"],
            reason: "Both Amma and Mum are in your contacts, and each was heard by one recogniser.",
          },
        },
        decision: { kind: "choose", question: "Amma or Mum?", options: ["Remind me to ring Amma at six", "Remind me to ring Mum at six"] },
        rule: "Claude was unsure between two names, so it offers both and asks you to pick.",
      },
      "remind me to ring um at six",
      4.1,
      3,
    ),
    replayTurn(
      {
        turnId: "example-remind-2",
        hear: [
          { hearer: "realtime", start: 0, seconds: 0, text: "amma" },
          { hearer: "scribe", start: 2, seconds: 0.51, text: "Uma." },
          { hearer: "gemini", start: 3, seconds: 1.27, text: "Amma." },
        ],
        disputed: ["uma", "amma"],
        repair: { skipped: "Two recognisers heard one of the two choices, so Claude was not needed." },
        decision: { kind: "act", text: "Amma" },
        rule: "Gemini and the live transcript heard \"Amma\", one of the two choices.",
      },
      "amma",
      1.0,
    ),
  ],
  acts: {
    [actKey("Remind me to ring Amma at six")]: {
      action: { kind: "reminder", text: "Ring Amma", when: "6:00 pm" },
      reply: "I'll remind you to ring Amma at six.",
      needsConfirmation: false,
    },
  },
};
