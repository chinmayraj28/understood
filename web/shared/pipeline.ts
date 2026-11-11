// The shared contract between the page (web/src) and the API server (web/server).
//
// One turn of speech goes through five stages: record it in the browser, hear it with three
// recognisers, look it up in the person's phrasebook, repair it with Claude using context, then
// decide in code whether to act or ask first. The server streams one PipelineEvent per step so
// the page can show the turn moving through the pipeline as it happens.
//
// This mirrors the Swift contract in Packages/HFCore/Sources/HFCore/Understanding.swift, which
// the evaluation on real impaired speech (eval/) was run against.

/** Which recogniser produced a transcript. */
export type HearerName =
  | "scribe" // ElevenLabs Scribe batch, with the person's keyterms
  | "gemini" // Gemini Flash through OpenRouter, shown a few of the person's own clips
  | "realtime"; // ElevenLabs Scribe realtime: the live transcript shown while speaking (its final text is the third vote)

export type Confidence = "low" | "medium" | "high";

/** One of the person's own earlier recordings with what they meant. */
export interface SpeechExample {
  /** 16 kHz mono 16-bit WAV, base64. */
  wavBase64: string;
  text: string;
}

/** A phrasebook entry: once a recogniser heard `heard` and the person confirmed they meant `meant`. */
export interface PhrasebookEntry {
  id: string;
  meant: string;
  heard: string;
  hearer: HearerName;
  timesConfirmed: number;
  /** Milliseconds since 1970. */
  lastConfirmedAt: number;
  source: "enrolment" | "confirmation" | "correction";
}

/** What is going on around the turn. */
export interface TurnContext {
  /** The question the assistant just asked, if the person is answering one. */
  pendingQuestion?: string;
  /** Fixed answers to that question ("yes", "no", or "Mum", "Sam"). */
  expectedAnswers?: string[];
  /** Last few turns, oldest first, each "User: ..." or "Assistant: ...". */
  recentTurns?: string[];
  /** Consecutive turns that ended in a question or a "no". The decider gets stricter as this grows. */
  failedTries?: number;
}

/** Switches each stage on or off, so the page can show the difference each one makes. */
export interface StageSwitches {
  keyterms: boolean;
  gemini: boolean;
  examples: boolean;
  phrasebook: boolean;
  repair: boolean;
}

/** The body of POST /api/understand (sent as JSON). */
export interface UnderstandRequest {
  turnId: string;
  /** The recorded turn: 16 kHz mono 16-bit WAV, base64. */
  wavBase64: string;
  /** The final text from the live (realtime) recogniser, if it produced one. */
  realtimeText?: string;
  /**
   * The keyterms the live recogniser was given (none by default). The decider treats the live
   * transcript as an independent, hint-free check only when these share no word with the hints
   * the other recognisers got; otherwise all three could be pushed to the same wrong name.
   */
  realtimeKeyterms?: string[];
  /** The person's phrasebook. It lives only in their browser and is sent with each turn. */
  phrasebook: PhrasebookEntry[];
  /** A few of their clips for Gemini (the client picks them; at most 5). */
  examples: SpeechExample[];
  /** Extra words likely in this turn (names, the things the demo assistant can do). */
  keyterms: string[];
  context: TurnContext;
  switches: StageSwitches;
  /**
   * "transcribe" for a recording, where the transcript is the point and nobody is waiting to be
   * answered: the recognisers and Claude get longer to answer (Gemini with example clips can take
   * well over 4 s), and the demo phone's contact names are not added as hints. Default "conversation".
   */
  purpose?: "conversation" | "transcribe";
}

export interface PhrasebookMatch {
  entryId: string;
  meant: string;
  heard: string;
  /** 0...1. */
  similarity: number;
  timesConfirmed: number;
  /** True when the match alone is allowed to act (see the decider's rules). */
  strong: boolean;
}

export interface Reading {
  text: string;
  confidence: Confidence;
  /** Up to two other likely readings. */
  alternatives: string[];
  /** One short sentence on why. Shown on the page, never spoken. */
  reason: string;
}

export type Decision =
  | { kind: "act"; text: string }
  | { kind: "confirm"; question: string; reading: string }
  | { kind: "choose"; question: string; options: string[] }
  | { kind: "askAgain"; question: string }
  | { kind: "cannotHear"; message: string };

/**
 * One step of a turn, streamed from the server as server-sent events, in this order:
 * turn.started, hear.started ×N, hear.done ×N (as each finishes), agreement, phrasebook,
 * repair.started + repair.done (or repair.skipped), decision, turn.done.
 * repair.skipped can also follow repair.started, when Claude fails or runs past its time limit.
 * On a server failure, turn.failed replaces the rest.
 */
export type PipelineEvent =
  | { type: "turn.started"; turnId: string; at: number; keyterms: string[]; exampleCount: number }
  | { type: "hear.started"; hearer: HearerName; at: number }
  | { type: "hear.done"; hearer: HearerName; at: number; text: string; seconds: number; failure?: string }
  | {
      type: "agreement";
      at: number;
      /** Normalised content words per hearer, for the page to show where they differ. */
      contentWords: Partial<Record<HearerName, string[]>>;
      /** Hearers whose content words are identical, largest group. */
      agreeing: HearerName[];
      /** Words that differ between hearers. */
      disputedWords: string[];
    }
  | { type: "phrasebook"; at: number; match: PhrasebookMatch | null }
  | { type: "repair.started"; at: number }
  | { type: "repair.done"; at: number; reading: Reading; seconds: number }
  | { type: "repair.skipped"; at: number; why: string }
  | {
      type: "decision";
      at: number;
      decision: Decision;
      /** The rule that fired, in plain words: "Two recognisers heard the same words and Claude was sure." */
      rule: string;
    }
  | { type: "turn.done"; at: number; seconds: number }
  | { type: "turn.failed"; at: number; message: string };

/** POST /api/realtime-token returns a single-use token for the browser's live transcript. */
export interface RealtimeTokenResponse {
  token: string;
}

/** POST /api/speak with { text } returns 16 kHz PCM16 audio, streamed. */
export interface SpeakRequest {
  text: string;
}

/** Something the pretend phone on the page can do. Nothing real is ever sent. */
export type PhoneAction =
  | { kind: "message"; to: string; text: string }
  | { kind: "call"; to: string }
  | { kind: "timer"; minutes: number }
  | { kind: "music"; query: string }
  | { kind: "reminder"; text: string; when: string }
  | { kind: "none" };

/** POST /api/act with { text, recentTurns } — Claude picks one action for an understood sentence. */
export interface ActRequest {
  text: string;
  recentTurns?: string[];
}

export interface ActResponse {
  action: PhoneAction;
  /** What the assistant says back, short and spoken aloud. */
  reply: string;
  /**
   * True for anything that would reach another person (message, call). The page then asks
   * "Send 'running late' to Mum?" and does it only after a yes that went through the pipeline.
   */
  needsConfirmation: boolean;
}

/** The contacts and things the pretend phone knows, used as keyterms and by /api/act. */
export const DEMO_CONTACTS = ["Mum", "Sam", "Priya", "Dad", "Amma"] as const;
