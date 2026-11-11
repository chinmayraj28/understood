// A recording played as if it were being spoken now: it plays out of the speakers at its own
// pace while it streams to the live recogniser (Scribe realtime), so the live transcript writes
// itself on the page and its final text is the third vote, exactly as for a spoken turn.
//
// The microphone must be off while this runs, or it would hear the speakers.

import { RECORDING_REALTIME_MODEL, ScribeLiveTranscriber, type LiveTranscriber } from "./liveTranscript";
import { SAMPLE_RATE } from "./wav";

/** 20 ms, the microphone's piece size; the transcriber sends five at a time (100 ms). */
const PIECE = SAMPLE_RATE / 50;
/** How often the page wakes to send what has played. */
const STEP_MS = 100;
/** After the last piece, how long to wait for the live recogniser's final words. */
const FINAL_WAIT_MS = 2500;
/** How long to wait for the browser to allow sound before saying so. */
const SOUND_WAIT_MS = 3000;

export interface PlayHooks {
  onText(text: string): void;
  /** Loudness 0...1 of the piece now playing, for the waveform. */
  onLevel(level: number): void;
  signal: AbortSignal;
  /**
   * The audio context to play through. Make it in the click that chose the recording, so the
   * browser allows it to play; one made later may stay silent until the next click.
   */
  context: AudioContext;
}

export interface PlayResult {
  /** The live recogniser's final text, or undefined when it could not be reached. */
  realtimeText?: string;
  realtimeFailure?: string;
}

const stopped = () => new DOMException("Stopped", "AbortError");

export async function playAndTranscribe(pcm: Int16Array, hooks: PlayHooks, transcriber: LiveTranscriber = new ScribeLiveTranscriber(RECORDING_REALTIME_MODEL)): Promise<PlayResult> {
  const { signal, context } = hooks;
  if (signal.aborted) throw stopped();
  let source: AudioBufferSourceNode | null = null;
  const onAbort = () => {
    source?.stop();
    transcriber.stop();
  };
  signal.addEventListener("abort", onAbort, { once: true });

  let failure: string | undefined;
  transcriber.onText = hooks.onText;
  transcriber.onError = (message) => (failure = message);
  try {
    // Connecting can take a while; Stop does not wait for it.
    const connecting = transcriber.start().then(
      () => true,
      (error: Error) => {
        failure = error.message || "The live transcript could not connect.";
        return false;
      },
    );
    const connected = await Promise.race([connecting, untilAborted(signal)]);
    if (signal.aborted) throw stopped();

    if (context.state !== "running") {
      const allowed = await Promise.race([context.resume().then(() => true, () => false), wait(SOUND_WAIT_MS, signal).then(() => false)]);
      if (!allowed || (context.state as AudioContextState) !== "running") throw new Error("The browser did not allow the page to play sound. Click the page once and try again.");
    }

    const buffer = context.createBuffer(1, pcm.length, SAMPLE_RATE);
    const channel = buffer.getChannelData(0);
    for (let i = 0; i < pcm.length; i++) channel[i] = pcm[i] / 32768;
    source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    const startAt = context.currentTime + 0.05;
    source.start(startAt);

    // The audio is sent as it plays, at the pace a person would say it. Each time the page wakes
    // it sends everything played so far, in 20 ms pieces, so a background tab (where the browser
    // slows timers to once a second) still keeps up with the sound.
    let sent = 0;
    // If the audio clock ever stalls, the rest is sent anyway once the clip should have ended.
    const deadline = performance.now() + (pcm.length / SAMPLE_RATE) * 1000 + 5000;
    while (sent < pcm.length) {
      if (signal.aborted) throw stopped();
      const clock = performance.now() > deadline ? Infinity : context.currentTime - startAt;
      const played = Math.min(pcm.length, Math.max(0, Math.floor(clock * SAMPLE_RATE)));
      const upTo = played >= pcm.length ? pcm.length : played - (played % PIECE);
      for (; sent < upTo; sent += PIECE) {
        const piece = pcm.subarray(sent, Math.min(upTo, sent + PIECE));
        if (connected) transcriber.send(piece);
      }
      if (upTo > 0) hooks.onLevel(level(pcm.subarray(Math.max(0, upTo - SAMPLE_RATE / 10), upTo)));
      if (sent < pcm.length) await wait(STEP_MS, signal);
    }
    hooks.onLevel(0);
    if (!connected) return { realtimeFailure: failure };
    const text = await transcriber.finishTurn(FINAL_WAIT_MS);
    if (signal.aborted) throw stopped();
    return failure ? { realtimeText: text || undefined, realtimeFailure: failure } : { realtimeText: text };
  } finally {
    signal.removeEventListener("abort", onAbort);
    transcriber.stop();
  }
}

function untilAborted(signal: AbortSignal): Promise<never> {
  return new Promise((_, reject) => {
    if (signal.aborted) return reject(stopped());
    signal.addEventListener("abort", () => reject(stopped()), { once: true });
  });
}

function level(piece: Int16Array): number {
  let sum = 0;
  for (let i = 0; i < piece.length; i++) sum += (piece[i] / 32768) ** 2;
  return Math.min(1, Math.sqrt(sum / Math.max(1, piece.length)) * 6);
}

function wait(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(stopped());
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(stopped());
      },
      { once: true },
    );
  });
}
