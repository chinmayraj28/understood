// The microphone, the patient end-of-turn detector and the live transcript, joined up.
// It hands the page one finished turn at a time: a 16 kHz WAV plus the live transcript's text.

import { DEFAULT_SETTINGS, EndOfTurnDetector, type DetectorEvent, type TurnEndReason } from "./endOfTurn";
import { ScribeLiveTranscriber, SilentTranscriber, type LiveTranscriber } from "./liveTranscript";
import { concat, encodeWav, SAMPLE_RATE, toBase64 } from "./wav";

export interface FinishedTurn {
  wavBase64: string;
  /** The live transcript's final text ("done" removed), or undefined when it heard nothing. */
  realtimeText?: string;
  speechSeconds: number;
  reason: TurnEndReason;
}

export type ListenerStatus = "off" | "starting" | "calibrating" | "waiting" | "speaking" | "finishing";

export interface ListenerTick {
  level: number;
  quietSeconds: number;
  status: ListenerStatus;
}

const CHUNK_SECONDS = 320 / SAMPLE_RATE;
/** Audio kept while nobody speaks: enough for the pre-roll, not a growing recording. */
const IDLE_KEEP_SECONDS = 1.5;

export class Listener {
  onTick: (tick: ListenerTick) => void = () => {};
  onLiveText: (text: string) => void = () => {};
  onSpeechStarted: () => void = () => {};
  onTurn: (turn: FinishedTurn) => void = () => {};
  onNotice: (message: string) => void = () => {};

  private detector = new EndOfTurnDetector({ ...DEFAULT_SETTINGS });
  private context: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private node: AudioWorkletNode | null = null;
  private transcriber: LiveTranscriber = new SilentTranscriber();
  /** Audio since `bufferStart` seconds, in 20 ms chunks. */
  private chunks: Int16Array[] = [];
  private bufferStart = 0;
  private status: ListenerStatus = "off";
  private lastTick = 0;

  get endSilenceSeconds() {
    return this.detector.settings.endSilenceSeconds;
  }
  set endSilenceSeconds(seconds: number) {
    this.detector.settings = { ...this.detector.settings, endSilenceSeconds: seconds };
  }
  get isOn() {
    return this.status !== "off";
  }

  /** Opens the microphone. Throws a plain sentence if permission is refused. */
  async start(options: { liveTranscript: boolean }) {
    if (this.isOn) return;
    this.setStatus("starting");
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
      });
    } catch (error) {
      this.setStatus("off");
      const name = (error as DOMException).name;
      throw new Error(
        name === "NotAllowedError"
          ? "The browser was not allowed to use the microphone. Allow it in the address bar, then try again."
          : "No microphone could be opened.",
      );
    }
    this.context = new AudioContext();
    await this.context.audioWorklet.addModule("/pcm-worklet.js");
    const source = this.context.createMediaStreamSource(this.stream);
    this.node = new AudioWorkletNode(this.context, "pcm-resampler");
    this.node.port.onmessage = (event: MessageEvent<{ pcm: Int16Array; db: number }>) => this.chunk(event.data.pcm, event.data.db);
    source.connect(this.node);
    if (this.context.state === "suspended") await this.context.resume().catch(() => {});

    this.detector = new EndOfTurnDetector({ ...this.detector.settings });
    this.chunks = [];
    this.bufferStart = 0;
    this.setStatus("calibrating");

    this.transcriber = options.liveTranscript ? new ScribeLiveTranscriber() : new SilentTranscriber();
    this.transcriber.onText = (text) => {
      this.onLiveText(text);
      this.handle(this.detector.setTranscript(text));
    };
    this.transcriber.onError = (message) => this.onNotice(message);
    this.transcriber.start().catch(() => {
      this.onNotice("The live transcript is off, so words appear only after each turn.");
      this.transcriber = new SilentTranscriber();
    });
  }

  /** True when the browser is holding the audio back until someone presses a key or clicks. */
  get needsGesture() {
    return this.context?.state === "suspended";
  }
  resume() {
    void this.context?.resume();
  }

  stop() {
    this.transcriber.stop();
    this.node?.disconnect();
    this.stream?.getTracks().forEach((t) => t.stop());
    void this.context?.close();
    this.context = null;
    this.stream = null;
    this.node = null;
    this.setStatus("off");
  }

  /** The "End turn" button and the space bar. */
  endTurn() {
    this.handle(this.detector.endNow());
  }

  private chunk(pcm: Int16Array, db: number) {
    this.chunks.push(pcm);
    this.transcriber.send(pcm);
    this.handle(this.detector.audio(db, CHUNK_SECONDS));
    if (!this.detector.isInTurn && this.status !== "finishing") {
      if (!this.detector.calibrating && this.status === "calibrating") this.setStatus("waiting");
      this.trimIdle();
    }
    const now = performance.now();
    if (now - this.lastTick > 50) {
      this.lastTick = now;
      this.onTick({ level: this.detector.isInTurn ? this.level : 0, quietSeconds: this.detector.quietSeconds, status: this.status });
    }
  }

  private level = 0;

  private handle(events: DetectorEvent[]) {
    for (const event of events) {
      if (event.type === "speechStarted") {
        this.setStatus("speaking");
        this.onSpeechStarted();
      } else if (event.type === "level") {
        this.level = event.value;
      } else if (event.type === "turnEnded") {
        void this.finish(event.boundary.audioStart, event.boundary.audioEnd, event.boundary.reason, event.boundary.liveTranscript);
      }
    }
  }

  private async finish(start: number, end: number, reason: TurnEndReason, detectorText: string) {
    this.setStatus("finishing");
    const from = Math.max(0, Math.round((start - this.bufferStart) / CHUNK_SECONDS));
    const to = Math.max(from, Math.round((end - this.bufferStart) / CHUNK_SECONDS));
    const audio = concat(this.chunks.slice(from, to));
    this.chunks = this.chunks.slice(to);
    this.bufferStart += to * CHUNK_SECONDS;
    const finalText = await this.transcriber.finishTurn();
    const text = reason === "saidDone" ? detectorText || finalText.replace(/[\s,.]*\bdone\W*$/i, "") : finalText || detectorText;
    if (this.isOn) this.setStatus(this.detector.isInTurn ? "speaking" : "waiting");
    this.onTurn({
      wavBase64: toBase64(encodeWav(audio)),
      realtimeText: text.trim() || undefined,
      speechSeconds: audio.length / SAMPLE_RATE,
      reason,
    });
  }

  private trimIdle() {
    const keep = Math.round(IDLE_KEEP_SECONDS / CHUNK_SECONDS);
    if (this.chunks.length > keep * 2) {
      const drop = this.chunks.length - keep;
      this.chunks = this.chunks.slice(drop);
      this.bufferStart += drop * CHUNK_SECONDS;
    }
  }

  private setStatus(status: ListenerStatus) {
    if (this.status === "off" && status === "waiting") return;
    this.status = status;
    this.onTick({ level: 0, quietSeconds: 0, status });
  }
}
