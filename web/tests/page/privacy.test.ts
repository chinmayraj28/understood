// Review finding 8: room audio between turns never leaves the browser, and the page makes no
// request to a font service.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { EndOfTurnDetector } from "../../src/audio/endOfTurn";
import { StreamGate } from "../../src/audio/streamGate";

const CHUNK = 0.02;
const PREROLL = 20;

/** Feeds sound levels through the detector and the gate, as the listener does. Returns what was sent. */
function stream(levels: number[]) {
  const detector = new EndOfTurnDetector();
  const gate = new StreamGate(PREROLL);
  const kept: Int16Array[] = [];
  const sent: number[] = [];
  let closes = 0;
  levels.forEach((db, i) => {
    const chunk = new Int16Array([i]); // each chunk carries its own index
    kept.push(chunk);
    detector.audio(db, CHUNK);
    const out = gate.next(detector.hearingSound, kept);
    sent.push(...out.send.map((c) => c[0]));
    if (out.closed) closes += 1;
  });
  return { sent, closes };
}

const repeat = (db: number, seconds: number) => Array<number>(Math.round(seconds / CHUNK)).fill(db);

describe("Only turns are streamed to the live transcript", () => {
  it("sends nothing at all while the room is quiet", () => {
    expect(stream(repeat(-60, 20)).sent).toEqual([]);
  });

  it("sends nothing from a steady −47 dBFS room", () => {
    expect(stream(repeat(-47, 20)).sent).toEqual([]);
  });

  it("sends a turn with the 0.4 s before it, and nothing after it ends", () => {
    const levels = [...repeat(-65, 2), ...repeat(-25, 1), ...repeat(-65, 6)];
    const { sent } = stream(levels);
    const firstLoud = 100; // 2 s of quiet at 20 ms a chunk
    expect(sent[0]).toBe(firstLoud - PREROLL);
    expect(sent).toEqual([...new Set(sent)]); // nothing sent twice
    // The turn ends 2.5 s after the speech; nothing from later quiet goes out.
    const lastSpeech = firstLoud + 50;
    expect(Math.max(...sent)).toBeLessThan(lastSpeech + Math.round(2.6 / CHUNK));
    expect(sent.length).toBeLessThan(levels.length - 100);
  });

  it("closes off a cough so its words do not join the next turn", () => {
    const { closes } = stream([...repeat(-65, 1), ...repeat(-25, 0.1), ...repeat(-65, 2)]);
    expect(closes).toBe(1);
  });
});

describe("No request to a font service", () => {
  const root = join(__dirname, "../..");
  const files = (dir: string): string[] =>
    readdirSync(dir).flatMap((name) => {
      const path = join(dir, name);
      return statSync(path).isDirectory() ? files(path) : [path];
    });

  it("index.html and the page's code name no Google Fonts host", () => {
    for (const path of [join(root, "index.html"), ...files(join(root, "src"))]) {
      expect(readFileSync(path, "utf8"), path).not.toMatch(/fonts\.(googleapis|gstatic)\.com/);
    }
  });

  it("the fonts the page uses are served from /fonts", () => {
    const css = readFileSync(join(root, "src/styles/fonts.css"), "utf8");
    for (const match of css.matchAll(/url\("\/fonts\/([^"]+)"\)/g)) {
      expect(statSync(join(root, "public/fonts", match[1])).size).toBeGreaterThan(1000);
    }
  });
});
