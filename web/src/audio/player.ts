// Plays the assistant's spoken reply: 16 kHz mono PCM16 bytes, streamed from /api/speak.
// Chunks are scheduled back to back as they arrive, so speech starts before the download ends.
// `stop()` cuts it off at once; the page calls it the moment the person starts speaking.

import { speakStream } from "../api/client";

const SAMPLE_RATE = 16000;

export class ReplyPlayer {
  private context: AudioContext | null = null;
  private sources: AudioBufferSourceNode[] = [];
  private abort: AbortController | null = null;
  private playing = false;
  /** Called with true when speech starts and false when it ends or is cut off. */
  onSpeaking: (speaking: boolean) => void = () => {};

  private audio(): AudioContext {
    if (!this.context) this.context = new AudioContext();
    if (this.context.state === "suspended") void this.context.resume();
    return this.context;
  }

  get isPlaying() {
    return this.playing;
  }

  /** Speaks `text`. Resolves when the reply has finished playing or was stopped. */
  async speak(text: string): Promise<void> {
    this.stop();
    const abort = new AbortController();
    this.abort = abort;
    const context = this.audio();
    const stream = await speakStream(text, abort.signal);
    const reader = stream.getReader();
    let nextTime = context.currentTime + 0.05;
    let leftover: Uint8Array | null = null;
    this.setPlaying(true);
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done || abort.signal.aborted) break;
        let bytes = value;
        if (leftover) {
          const joined = new Uint8Array(leftover.length + value.length);
          joined.set(leftover);
          joined.set(value, leftover.length);
          bytes = joined;
          leftover = null;
        }
        // PCM16 is two bytes a sample; carry an odd byte over to the next chunk.
        const usable = bytes.length - (bytes.length % 2);
        if (usable < bytes.length) leftover = bytes.slice(usable);
        if (usable === 0) continue;
        const samples = new Int16Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + usable));
        const buffer = context.createBuffer(1, samples.length, SAMPLE_RATE);
        const channel = buffer.getChannelData(0);
        for (let i = 0; i < samples.length; i++) channel[i] = samples[i] / 32768;
        const source = context.createBufferSource();
        source.buffer = buffer;
        source.connect(context.destination);
        nextTime = Math.max(nextTime, context.currentTime + 0.02);
        source.start(nextTime);
        nextTime += buffer.duration;
        this.sources.push(source);
      }
      const remaining = nextTime - context.currentTime;
      if (!abort.signal.aborted && remaining > 0) await wait(remaining * 1000, abort.signal);
    } finally {
      if (this.abort === abort) {
        this.sources = [];
        this.setPlaying(false);
      }
    }
  }

  /** Cuts the reply off now. */
  stop() {
    this.abort?.abort();
    this.abort = null;
    for (const source of this.sources) {
      try {
        source.stop();
      } catch {
        /* already stopped */
      }
    }
    this.sources = [];
    this.setPlaying(false);
  }

  private setPlaying(value: boolean) {
    if (this.playing === value) return;
    this.playing = value;
    this.onSpeaking(value);
  }
}

function wait(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}
