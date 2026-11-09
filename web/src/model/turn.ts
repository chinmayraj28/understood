// What the page knows about one turn, built up one PipelineEvent at a time.
//
// `reduceTurn` is pure: given the turn so far and the next event, it returns the new turn. The
// whole pipeline view is drawn from this one object, so a replayed turn and a live turn look the
// same, and every time shown comes from the events themselves.

import type {
  Decision,
  HearerName,
  PhrasebookMatch,
  PipelineEvent,
  Reading,
  StageSwitches,
} from "../../shared/pipeline";

export const HEARERS: HearerName[] = ["scribe", "gemini", "realtime"];

export const HEARER_LABEL: Record<HearerName, string> = {
  scribe: "Scribe",
  gemini: "Gemini",
  realtime: "Live",
};

export const HEARER_NOTE: Record<HearerName, string> = {
  scribe: "ElevenLabs Scribe, told your names and keyterms",
  gemini: "Gemini Flash, shown clips of your own voice",
  realtime: "The live transcript you watched while speaking",
};

/** The stations a turn passes, in order. */
export type Stage = "speak" | "hear" | "agree" | "phrasebook" | "repair" | "decide" | "done";
export const STAGES: Stage[] = ["speak", "hear", "agree", "phrasebook", "repair", "decide", "done"];

export function stageIndex(stage: Stage): number {
  return STAGES.indexOf(stage);
}

export interface Lane {
  hearer: HearerName;
  status: "waiting" | "running" | "done" | "failed";
  /** Server time the hearer started, ms. */
  startedAt?: number;
  /** Local performance.now() when the start arrived, for the running stopwatch. */
  localStartedAt?: number;
  doneAt?: number;
  text?: string;
  seconds?: number;
  failure?: string;
}

export type AgreementEvent = Extract<PipelineEvent, { type: "agreement" }>;

export interface RepairState {
  status: "waiting" | "running" | "done" | "skipped";
  startedAt?: number;
  localStartedAt?: number;
  reading?: Reading;
  seconds?: number;
  why?: string;
}

export interface TurnModel {
  turnId: string;
  /** Where the turn came from. Replays and evaluation turns are labelled as such on the page. */
  origin: "live" | "replay" | "enrolment" | "evaluation";
  label?: string;
  /** The live transcript as it was written while the person spoke. */
  liveText: string;
  speechSeconds?: number;
  switches: StageSwitches;
  /** The question the person was answering, if any. */
  answering?: string;
  startedAt?: number;
  keyterms: string[];
  exampleCount: number;
  lanes: Record<HearerName, Lane>;
  agreement?: AgreementEvent;
  phrasebookChecked: boolean;
  match: PhrasebookMatch | null;
  repair: RepairState;
  decision?: { decision: Decision; rule: string; at: number };
  totalSeconds?: number;
  failed?: string;
  stage: Stage;
  events: PipelineEvent[];
}

export const ALL_ON: StageSwitches = {
  keyterms: true,
  gemini: true,
  examples: true,
  phrasebook: true,
  repair: true,
};

export function newTurn(init: {
  turnId: string;
  origin: TurnModel["origin"];
  label?: string;
  liveText?: string;
  switches?: StageSwitches;
  answering?: string;
}): TurnModel {
  const lanes = {} as Record<HearerName, Lane>;
  for (const hearer of HEARERS) lanes[hearer] = { hearer, status: "waiting" };
  return {
    turnId: init.turnId,
    origin: init.origin,
    label: init.label,
    liveText: init.liveText ?? "",
    switches: init.switches ?? ALL_ON,
    answering: init.answering,
    keyterms: [],
    exampleCount: 0,
    lanes,
    phrasebookChecked: false,
    match: null,
    repair: { status: "waiting" },
    stage: "speak",
    events: [],
  };
}

/** Folds one event into the turn. `localNow` is performance.now(), used only for live stopwatches. */
export function reduceTurn(turn: TurnModel, event: PipelineEvent, localNow: number): TurnModel {
  const next: TurnModel = { ...turn, events: [...turn.events, event] };
  switch (event.type) {
    case "turn.started":
      return { ...next, startedAt: event.at, keyterms: event.keyterms, exampleCount: event.exampleCount, stage: "hear" };
    case "hear.started":
      return withLane(next, event.hearer, {
        status: "running",
        startedAt: event.at,
        localStartedAt: localNow,
      });
    case "hear.done":
      return withLane(next, event.hearer, {
        status: event.failure ? "failed" : "done",
        doneAt: event.at,
        text: event.text,
        seconds: event.seconds,
        failure: event.failure,
      });
    case "agreement":
      return { ...next, agreement: event, stage: "agree" };
    case "phrasebook":
      return { ...next, phrasebookChecked: true, match: event.match, stage: "phrasebook" };
    case "repair.started":
      return { ...next, repair: { status: "running", startedAt: event.at, localStartedAt: localNow }, stage: "repair" };
    case "repair.done":
      return { ...next, repair: { ...next.repair, status: "done", reading: event.reading, seconds: event.seconds }, stage: "repair" };
    case "repair.skipped":
      return { ...next, repair: { status: "skipped", why: event.why }, stage: "repair" };
    case "decision":
      return { ...next, decision: { decision: event.decision, rule: event.rule, at: event.at }, stage: "decide" };
    case "turn.done":
      return { ...next, totalSeconds: event.seconds, stage: "done" };
    case "turn.failed":
      return { ...next, failed: event.message, stage: "done" };
  }
}

function withLane(turn: TurnModel, hearer: HearerName, patch: Partial<Lane>): TurnModel {
  return { ...turn, lanes: { ...turn.lanes, [hearer]: { ...turn.lanes[hearer], ...patch } } };
}

/** The best single text for the turn: what it acted on, else Claude's reading, the phrasebook, a hearer. */
export function bestText(turn: TurnModel): string {
  if (turn.decision?.decision.kind === "act") return turn.decision.decision.text;
  if (turn.repair.reading) return turn.repair.reading.text;
  if (turn.match) return turn.match.meant;
  for (const hearer of HEARERS) {
    const lane = turn.lanes[hearer];
    if (lane.status === "done" && lane.text) return lane.text;
  }
  return turn.liveText;
}

/** What a recogniser heard, before any repair: Scribe first, then the live transcript, then Gemini. */
export function heardText(turn: TurnModel): string {
  for (const hearer of ["scribe", "realtime", "gemini"] as HearerName[]) {
    const lane = turn.lanes[hearer];
    if (lane.status === "done" && lane.text) return lane.text;
  }
  return turn.liveText;
}

/** Seconds from the turn's start to an event time, for the timing strip. */
export function offsetSeconds(turn: TurnModel, at: number | undefined): number | undefined {
  if (at === undefined || turn.startedAt === undefined) return undefined;
  return Math.max(0, (at - turn.startedAt) / 1000);
}

/** The decision's route on the switch-track. */
export function routeOf(decision: Decision): "act" | "ask" | "stop" {
  if (decision.kind === "act") return "act";
  if (decision.kind === "cannotHear") return "stop";
  return "ask";
}

/** What the assistant says for a decision, in one line. */
export function decisionSpeech(decision: Decision): string {
  switch (decision.kind) {
    case "act":
      return decision.text;
    case "confirm":
    case "choose":
    case "askAgain":
      return decision.question;
    case "cannotHear":
      return decision.message;
  }
}
