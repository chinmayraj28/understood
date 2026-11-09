// The browser's patient end-of-turn detector (web/src/audio/endOfTurn.ts), fed made-up sound
// levels. Its clock is the audio itself, so every case is exact and needs no microphone.
import { describe, expect, it } from "vitest";
import { EndOfTurnDetector, removeFinalWord, type DetectorEvent } from "../../src/audio/endOfTurn";

const CHUNK = 0.02; // the worklet posts 20 ms chunks

/** A stretch of sound: its level in dBFS and how long it lasts. `wobble` adds a steady ±dB ripple. */
type Stretch = { db: number; seconds: number; wobble?: number };

interface Run {
  events: { at: number; event: DetectorEvent }[];
  detector: EndOfTurnDetector;
}

function feed(stretches: Stretch[], transcript?: { at: number; text: string }): Run {
  const detector = new EndOfTurnDetector();
  const events: Run["events"] = [];
  let time = 0;
  let step = 0;
  for (const { db, seconds, wobble = 1 } of stretches) {
    for (let i = 0; i < Math.round(seconds / CHUNK); i++) {
      time += CHUNK;
      step += 1;
      if (transcript && Math.abs(time - transcript.at) < CHUNK / 2) {
        for (const event of detector.setTranscript(transcript.text)) events.push({ at: time, event });
      }
      // A deterministic ripple instead of random noise, so every run is the same.
      const level = db + wobble * Math.sin(step * 1.7);
      for (const event of detector.audio(level, CHUNK)) if (event.type !== "level") events.push({ at: time, event });
    }
  }
  return { events, detector };
}

function ends(run: Run) {
  return run.events.flatMap(({ at, event }) => (event.type === "turnEnded" ? [{ at, ...event.boundary }] : []));
}

function starts(run: Run) {
  return run.events.filter(({ event }) => event.type === "speechStarted");
}

describe("End of turn: patient by design", () => {
  it("does not end the turn during a 2-second pause inside a sentence", () => {
    const run = feed([
      { db: -65, seconds: 1 },
      { db: -25, seconds: 1.5 },
      { db: -65, seconds: 2 },
      { db: -25, seconds: 1 },
      { db: -65, seconds: 3 },
    ]);
    const ended = ends(run);
    expect(ended).toHaveLength(1);
    expect(ended[0].reason).toBe("silence");
    // Speech stopped at 5.5 s; the turn ends 2.5 s of quiet later, not at the pause.
    expect(ended[0].at).toBeGreaterThan(7.9);
    expect(ended[0].at).toBeLessThan(8.1);
  });

  it("waits longer when the setting says so", () => {
    const detector = new EndOfTurnDetector();
    detector.settings = { ...detector.settings, endSilenceSeconds: 4 };
    let endedAt = 0;
    let time = 0;
    for (const [db, seconds] of [[-65, 1], [-25, 1], [-65, 5]] as const) {
      for (let i = 0; i < seconds / CHUNK; i++) {
        time += CHUNK;
        if (detector.audio(db, CHUNK).some((e) => e.type === "turnEnded")) endedAt = time;
      }
    }
    expect(endedAt).toBeGreaterThan(5.9);
  });

  it("ignores a blip shorter than 0.3 s", () => {
    const run = feed([
      { db: -65, seconds: 1 },
      { db: -25, seconds: 0.2 },
      { db: -65, seconds: 3 },
    ]);
    expect(starts(run)).toHaveLength(0);
    expect(run.events.some(({ event }) => event.type === "blipIgnored")).toBe(true);
  });

  it("ends early when the last word is \"done\", and takes the word off", () => {
    const run = feed(
      [
        { db: -65, seconds: 1 },
        { db: -25, seconds: 2 },
        { db: -65, seconds: 1.5 },
      ],
      { at: 3.1, text: "Message Mum, done." },
    );
    const ended = ends(run);
    expect(ended).toHaveLength(1);
    expect(ended[0].reason).toBe("saidDone");
    expect(ended[0].liveTranscript).toBe("Message Mum");
    expect(ended[0].at).toBeLessThan(4); // well before 2.5 s of quiet
  });

  it("ends a turn on the End turn button", () => {
    const run = feed([
      { db: -65, seconds: 1 },
      { db: -25, seconds: 1 },
    ]);
    const ended = run.detector.endNow();
    expect(ended[0]).toMatchObject({ type: "turnEnded", boundary: { reason: "button" } });
  });
});

describe("End of turn: the room's noise (the 9 Nov bug)", () => {
  it("never starts a turn in a steady −47 dBFS room with nobody speaking", () => {
    const run = feed([{ db: -47, seconds: 20 }]);
    expect(run.events).toHaveLength(0);
  });

  it("never starts a turn in a −47 dBFS room that wobbles by ±4 dB", () => {
    const run = feed([{ db: -47, seconds: 20, wobble: 4 }]);
    expect(starts(run)).toHaveLength(0);
  });

  it("hears speech over a −47 dBFS room, and ends the turn after it", () => {
    const run = feed([
      { db: -47, seconds: 1 },
      { db: -25, seconds: 2 },
      { db: -47, seconds: 4 },
    ]);
    expect(starts(run)).toHaveLength(1);
    expect(ends(run)).toHaveLength(1);
    expect(ends(run)[0].at).toBeLessThan(5.7);
  });

  it("measures the room first: a click in the first half second does not start a turn", () => {
    const run = feed([
      { db: -25, seconds: 0.1 },
      { db: -65, seconds: 0.4 },
      { db: -65, seconds: 1 },
    ]);
    expect(starts(run)).toHaveLength(0);
  });

  it("still ends the turn when the room gets louder after it was measured", () => {
    // Quiet while measuring, then a fan comes on, then speech, then the fan carries on.
    const run = feed([
      { db: -70, seconds: 0.5 },
      { db: -45, seconds: 2 },
      { db: -25, seconds: 2 },
      { db: -45, seconds: 10 },
    ]);
    expect(ends(run)).toHaveLength(1);
    expect(run.detector.noiseFloor!).toBeGreaterThan(-50); // it learnt the fan
  });

  it("does not mistake continuous, varying speech for noise", () => {
    const stretches: Stretch[] = [{ db: -65, seconds: 1 }];
    for (let i = 0; i < 40; i++) stretches.push({ db: i % 2 ? -20 : -34, seconds: 0.1, wobble: 0 });
    stretches.push({ db: -65, seconds: 3 });
    const run = feed(stretches);
    const ended = ends(run);
    expect(ended).toHaveLength(1);
    // Ends 2.5 s after the speech (which stopped at 5 s), not part-way through it.
    expect(ended[0].at).toBeGreaterThan(7.4);
    expect(run.detector.noiseFloor!).toBeLessThan(-60);
  });

  it("cuts a turn off at 30 s of changing sound", () => {
    const stretches: Stretch[] = [{ db: -65, seconds: 1 }];
    for (let i = 0; i < 320; i++) stretches.push({ db: i % 2 ? -18 : -32, seconds: 0.1, wobble: 0 });
    const ended = ends(feed(stretches));
    expect(ended[0].reason).toBe("maxLength");
  });
});

describe("Taking \"done\" off the end", () => {
  it("removes a final done with its punctuation", () => {
    expect(removeFinalWord("done", "Message Mum, done.")).toBe("Message Mum");
  });
  it("leaves a word that only ends in done", () => {
    expect(removeFinalWord("done", "abandoned")).toBe("abandoned");
  });
});
