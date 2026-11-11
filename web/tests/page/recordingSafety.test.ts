// While a recording plays out of the speakers, the microphone must not hear it as the person:
// it stays closed, a turn it caught is dropped, and Stop ends playback at any step.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { playAndTranscribe } from "../../src/audio/fileHearing";
import type { LiveTranscriber } from "../../src/audio/liveTranscript";

class FakeTranscriber implements LiveTranscriber {
  onText: (text: string) => void = () => {};
  onError: (message: string) => void = () => {};
  sent = 0;
  stopped = false;
  constructor(private startDelayMs = 0, private finalText = "up") {}
  start() {
    return new Promise<void>((resolve) => setTimeout(resolve, this.startDelayMs));
  }
  send() {
    this.sent++;
  }
  async finishTurn() {
    return this.finalText;
  }
  stop() {
    this.stopped = true;
  }
}

/** Just enough of an AudioContext: a clock that runs in real time, and a silent source. */
function fakeContext(state: AudioContextState = "running"): AudioContext {
  const began = performance.now();
  const context = {
    state,
    get currentTime() {
      return (performance.now() - began) / 1000;
    },
    resume: () => new Promise<void>(() => {}), // a browser that never allows sound
    createBuffer: (_c: number, length: number) => ({ getChannelData: () => new Float32Array(length) }),
    createBufferSource: () => ({ buffer: null, connect() {}, start() {}, stop() {} }),
    destination: {},
  };
  return context as unknown as AudioContext;
}

const tenthOfASecond = new Int16Array(1600);

describe("playing a recording", () => {
  it("streams it to the live recogniser in 20 ms pieces and returns its final text", async () => {
    const transcriber = new FakeTranscriber();
    const result = await playAndTranscribe(tenthOfASecond, { onText() {}, onLevel() {}, signal: new AbortController().signal, context: fakeContext() }, transcriber);
    expect(transcriber.sent).toBe(5);
    expect(result.realtimeText).toBe("up");
    expect(transcriber.stopped).toBe(true);
  });

  it("Stop works while the live recogniser is still connecting", async () => {
    const transcriber = new FakeTranscriber(5000);
    const abort = new AbortController();
    const playing = playAndTranscribe(tenthOfASecond, { onText() {}, onLevel() {}, signal: abort.signal, context: fakeContext() }, transcriber);
    setTimeout(() => abort.abort(), 20);
    const started = Date.now();
    await expect(playing).rejects.toMatchObject({ name: "AbortError" });
    expect(Date.now() - started).toBeLessThan(1000);
    expect(transcriber.stopped).toBe(true);
  });

  it("says so when the browser will not play sound, instead of hanging", async () => {
    const transcriber = new FakeTranscriber();
    const playing = playAndTranscribe(tenthOfASecond, { onText() {}, onLevel() {}, signal: new AbortController().signal, context: fakeContext("suspended") }, transcriber);
    await expect(playing).rejects.toThrow(/did not allow the page to play sound/);
  }, 6000);
});

describe("the microphone and a playing recording (useSession)", () => {
  const session = readFileSync(new URL("../../src/useSession.ts", import.meta.url), "utf8");
  const between = (from: string, to: string) => session.slice(session.indexOf(from), session.indexOf(to, session.indexOf(from)));

  it("a spoken turn caught while a recording plays is dropped before anything else", () => {
    const handle = between("const handleTurn = useCallback(", "[own, handleEnrolTurn, stopListening]");
    expect(handle.indexOf("if (recordingAloud.current) return;")).toBeGreaterThan(0);
    expect(handle.indexOf("if (recordingAloud.current) return;")).toBeLessThan(handle.indexOf("submitTurn"));
  });

  it("starting to listen while a recording plays only books the microphone for afterwards", () => {
    const start = between("const startListening = useCallback(", "listener.start(");
    expect(start).toMatch(/if \(recordingAloud\.current\) \{[\s\S]*micAfterRecording\.current = true;[\s\S]*return;/);
  });

  it("a recording closes the microphone first, and every ending reopens it if it was on", () => {
    const hear = between("const hearRecording = useCallback(", "[own, listener, stopHearing, voiceFor, endRecordingAloud]");
    expect(hear.indexOf("recordingAloud.current = true;")).toBeLessThan(hear.indexOf("listener.stop();"));
    expect(hear).toMatch(/finally \{[\s\S]*if \(recordingAloud\.current\) endRecordingAloud\(\);/);
    expect(between("const stopListening = useCallback(", "}, [listener]);")).toMatch(/micAfterRecording\.current = false/);
  });
});
