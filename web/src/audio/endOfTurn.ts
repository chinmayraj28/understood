// Decides when a turn starts and ends, from sound levels and the live transcript.
// Ported from Packages/HFUnderstand/Sources/HFUnderstand/TurnRecorderEndOfTurn.swift.
//
// Why it is patient: people with dysarthria pause for a long time inside a sentence, so a turn
// ends only after `endSilenceSeconds` of quiet (2.5 s by default), when the person says "done",
// or at `maxTurnSeconds`. Pure code: its clock is the audio fed to it, so it is easy to test.
//
// The fix over the Swift version (found 9 Nov): the noise floor used to be seeded from the very
// first chunk and learnt only between turns. In a moderately noisy room the first chunk could be
// quieter than the room, every later chunk counted as speech, and the turn never ended. Now:
//   1. the first `calibrationSeconds` only measure the room (no turn can start), and
//   2. during a turn, if even the quietest moments of the last few seconds stay above the speech
//      threshold, that is steady noise, and the floor rises towards it, so quiet can be found.

export interface TurnEndSettings {
  endSilenceSeconds: number;
  maxTurnSeconds: number;
  minimumSpeechSeconds: number;
  doneSilenceSeconds: number;
  speechMarginDecibels: number;
  quietestSpeechDecibels: number;
  preRollSeconds: number;
  trailingSilenceKeptSeconds: number;
  calibrationSeconds: number;
  doneWord: string;
}

export const DEFAULT_SETTINGS: TurnEndSettings = {
  endSilenceSeconds: 2.5,
  maxTurnSeconds: 30,
  minimumSpeechSeconds: 0.3,
  doneSilenceSeconds: 0.6,
  speechMarginDecibels: 10,
  quietestSpeechDecibels: -55,
  preRollSeconds: 0.4,
  trailingSilenceKeptSeconds: 0.4,
  calibrationSeconds: 0.5,
  doneWord: "done",
};

export type TurnEndReason = "silence" | "saidDone" | "maxLength" | "button";

export interface TurnBoundary {
  audioStart: number;
  audioEnd: number;
  reason: TurnEndReason;
  /** The live transcript of the turn, with a final "done" taken off. */
  liveTranscript: string;
}

export type DetectorEvent =
  | { type: "speechStarted"; at: number }
  | { type: "level"; value: number }
  | { type: "blipIgnored"; at: number }
  | { type: "turnEnded"; boundary: TurnBoundary };

type Phase =
  | { kind: "idle" }
  | { kind: "candidate"; start: number; voiced: number; lastVoice: number }
  | { kind: "speaking"; start: number };

/** Seconds of recent audio watched during a turn to notice noise that never goes away. */
const NOISE_WINDOW_SECONDS = 3;

export class EndOfTurnDetector {
  time = 0;
  noiseFloor: number | null = null;
  private phase: Phase = { kind: "idle" };
  private lastVoice = 0;
  private lastRunStart = 0;
  private calibration: number[] = [];
  private recent: { db: number; duration: number }[] = [];
  private transcript = "";
  private raisingFloor = false;

  constructor(public settings: TurnEndSettings = DEFAULT_SETTINGS) {}

  get isInTurn() {
    return this.phase.kind === "speaking";
  }
  get calibrating() {
    return this.time < this.settings.calibrationSeconds;
  }
  get threshold() {
    return Math.max((this.noiseFloor ?? -70) + this.settings.speechMarginDecibels, this.settings.quietestSpeechDecibels);
  }
  /** Seconds of quiet since the last sound, while a turn is under way. For the patience meter. */
  get quietSeconds() {
    return this.isInTurn ? Math.max(0, this.time - this.lastVoice) : 0;
  }

  /** One chunk of audio: its loudness in dBFS and its length in seconds. */
  audio(db: number, duration: number): DetectorEvent[] {
    const chunkStart = this.time;
    this.time += duration;
    const events: DetectorEvent[] = [];

    if (chunkStart < this.settings.calibrationSeconds) {
      // Measure the room first. The median ignores a click during the first half second.
      this.calibration.push(db);
      const sorted = [...this.calibration].sort((a, b) => a - b);
      this.noiseFloor = sorted[Math.floor(sorted.length / 2)];
      return events;
    }

    const voiced = db >= this.threshold;
    const phase = this.phase;
    if (phase.kind === "idle") {
      this.learnFloor(db, duration);
      if (voiced) {
        this.phase = { kind: "candidate", start: chunkStart, voiced: duration, lastVoice: this.time };
        this.lastRunStart = chunkStart;
        this.lastVoice = this.time;
        events.push(...this.confirmIfLongEnough());
      }
    } else if (phase.kind === "candidate") {
      if (voiced) {
        if (this.time - phase.lastVoice > duration + 0.0001) this.lastRunStart = chunkStart;
        this.phase = { ...phase, voiced: phase.voiced + duration, lastVoice: this.time };
        this.lastVoice = this.time;
        events.push(...this.confirmIfLongEnough());
      } else if (this.time - phase.lastVoice > this.settings.minimumSpeechSeconds) {
        this.phase = { kind: "idle" };
        events.push({ type: "blipIgnored", at: phase.start });
      }
    } else if (voiced) {
      if (this.time - this.lastVoice > 0.2 + duration) this.lastRunStart = chunkStart;
      this.lastVoice = this.time;
    }

    if (this.phase.kind === "speaking") {
      this.adaptDuringTurn(db, duration);
      events.push({ type: "level", value: Math.min(1, Math.max(0, (db - (this.noiseFloor ?? -70)) / 40)) });
      const boundary = this.endIfDue(this.phase.start);
      if (boundary) events.push({ type: "turnEnded", boundary });
    }
    return events;
  }

  /** The live transcript of the turn so far. "done" at the end, then a short quiet, ends it. */
  setTranscript(text: string): DetectorEvent[] {
    this.transcript = text;
    if (this.phase.kind !== "speaking") return [];
    const boundary = this.endIfDue(this.phase.start);
    return boundary ? [{ type: "turnEnded", boundary }] : [];
  }

  /** The "End turn" button or the space bar. */
  endNow(): DetectorEvent[] {
    if (this.phase.kind !== "speaking") return [];
    return [{ type: "turnEnded", boundary: this.finish(this.phase.start, "button", this.time) }];
  }

  private confirmIfLongEnough(): DetectorEvent[] {
    const phase = this.phase;
    if (phase.kind !== "candidate" || phase.voiced < this.settings.minimumSpeechSeconds - 0.0001) return [];
    this.phase = { kind: "speaking", start: phase.start };
    this.recent = [];
    return [{ type: "speechStarted", at: phase.start }];
  }

  /** Between turns the floor follows the room down quickly and up slowly (about ten seconds). */
  private learnFloor(db: number, duration: number) {
    const floor = this.noiseFloor ?? db;
    const rate = db < floor ? Math.min(1, duration / 0.3) : Math.min(1, duration / 10);
    this.noiseFloor = floor + (db - floor) * rate;
  }

  /** During a turn: if the quietest tenth of the last 3 s is still "speech", it is noise. */
  private adaptDuringTurn(db: number, duration: number) {
    this.recent.push({ db, duration });
    let total = this.recent.reduce((sum, c) => sum + c.duration, 0);
    while (total > NOISE_WINDOW_SECONDS && this.recent.length > 1) total -= this.recent.shift()!.duration;
    if (total < NOISE_WINDOW_SECONDS - 0.05) return;
    const sorted = this.recent.map((c) => c.db).sort((a, b) => a - b);
    const quietest = sorted[Math.floor(sorted.length / 10)];
    // Start when nothing in 3 s fell below the threshold; once started, keep going until the
    // floor reaches the noise itself. Stopping at the threshold would leave the noise
    // flickering across it, and the turn would still never end.
    const loudest = sorted[Math.floor((sorted.length * 9) / 10)];
    const steady = loudest - quietest < 8; // speech rises and falls by far more than a fan does
    if (quietest >= this.threshold && steady) this.raisingFloor = true;
    const floor = this.noiseFloor ?? quietest;
    if (this.raisingFloor && quietest > floor + 1) {
      this.noiseFloor = floor + (quietest - floor) * Math.min(1, duration / 1.5);
    } else {
      this.raisingFloor = false;
    }
  }

  private endIfDue(turnStart: number): TurnBoundary | null {
    const quiet = this.time - this.lastVoice;
    const s = this.settings;
    if (quiet >= s.endSilenceSeconds) return this.finish(turnStart, "silence", this.lastVoice + s.trailingSilenceKeptSeconds);
    if (quiet >= s.doneSilenceSeconds && lastWord(this.transcript) === s.doneWord) {
      // Cut where "done" began when the last stretch of sound is short enough to be that word.
      const lastRun = this.lastVoice - this.lastRunStart;
      const end = lastRun < 1.2 && this.lastRunStart > turnStart ? this.lastRunStart : this.lastVoice + s.trailingSilenceKeptSeconds;
      return this.finish(turnStart, "saidDone", end);
    }
    if (this.time - turnStart >= s.maxTurnSeconds) return this.finish(turnStart, "maxLength", this.time);
    return null;
  }

  private finish(turnStart: number, reason: TurnEndReason, audioEnd: number): TurnBoundary {
    let text = this.transcript;
    if (reason === "saidDone") text = removeFinalWord(this.settings.doneWord, text);
    if (reason === "maxLength" && this.recent.length) {
      // Thirty seconds without a pause is often a noise that started. Learn it for next time.
      const sorted = this.recent.map((c) => c.db).sort((a, b) => a - b);
      this.noiseFloor = Math.max(this.noiseFloor ?? -70, sorted[Math.floor(sorted.length / 10)]);
    }
    this.phase = { kind: "idle" };
    this.transcript = "";
    this.recent = [];
    this.raisingFloor = false;
    return {
      audioStart: Math.max(0, turnStart - this.settings.preRollSeconds),
      audioEnd: Math.min(Math.max(audioEnd, turnStart), this.time),
      reason,
      liveTranscript: text.trim(),
    };
  }
}

function lastWord(text: string): string | undefined {
  const words = text.toLowerCase().split(/[^\p{L}']+/u).filter(Boolean);
  return words[words.length - 1];
}

/** "Message Mum, done." becomes "Message Mum". Only a whole word: "abandoned" stays. */
export function removeFinalWord(word: string, text: string): string {
  let trimmed = text.trim().replace(/[^\p{L}\p{N}]+$/u, "");
  if (!trimmed.toLowerCase().endsWith(word.toLowerCase())) return text;
  const before = trimmed.slice(0, trimmed.length - word.length);
  if (/\p{L}$/u.test(before)) return text;
  trimmed = before.replace(/[\s,;:.\-]+$/u, "");
  return trimmed;
}
