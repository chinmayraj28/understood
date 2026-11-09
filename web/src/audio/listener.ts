// The microphone, the patient end-of-turn detector and the live transcript, joined up.
// It hands the page one finished turn at a time: a 16 kHz WAV plus the live transcript's text.

import { DEFAULT_SETTINGS, EndOfTurnDetector, type DetectorEvent, type TurnEndReason } from "./endOfTurn";
import { ScribeLiveTranscriber, SilentTranscriber, type LiveTranscriber } from "./liveTranscript";
import { StreamGate } from "./streamGate";
import { concat, encodeWav, SAMPLE_RATE, toBase64 } from "./wav";

export interface FinishedTurn {
  wavBase64: string;
  /** The live transcript's final text ("done" removed), or undefined when it heard nothing. */
  realtimeText?: string;
  speechSeconds: number;
  reason: TurnEndReason;
  /** performance.now() when the person started speaking: an answer must start after its question. */
  speechStartedAt: number;
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
/** Audio from just before a sound that goes out with it: the detector's pre-roll, 0.4 s. */
const PREROLL_CHUNKS = Math.round(0.4 / CHUNK_SECONDS);

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
  private gate = new StreamGate(PREROLL_CHUNKS);
  private speechStartedAt = 0;
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

  /** Bumped by every start and stop, so a start that is overtaken by a stop gives up. */
  private startToken = 0;

  /**
   * Opens the microphone. Throws a plain sentence if it cannot. If stop() is called while this
   * is still waiting (on permission, or on the audio worklet), the microphone is closed again
   * and nothing is left running.
   */
  async start(options: { liveTranscript: boolean }) {
    if (this.isOn) return;
    const token = ++this.startToken;
    const overtaken = () => token !== this.startToken;
    this.setStatus("starting");
    let stream: MediaStream | null = null;
    let context: AudioContext | null = null;
    let node: AudioWorkletNode | null = null;
    let ready = false;
    try {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
        });
      } catch (error) {
        const name = (error as DOMException).name;
        throw new Error(
          name === "NotAllowedError"
            ? "The browser was not allowed to use the microphone. Allow it in the address bar, then try again."
            : "No microphone could be opened.",
        );
      }
      if (overtaken()) return;
      context = new AudioContext();
      try {
        await context.audioWorklet.addModule("/pcm-worklet.js");
      } catch {
        throw new Error("The page could not start listening: its audio code failed to load. Reload the page and try again.");
      }
      if (overtaken()) return;
      const source = context.createMediaStreamSource(stream);
      node = new AudioWorkletNode(context, "pcm-resampler");
      node.port.onmessage = (event: MessageEvent<{ pcm: Int16Array; db: number }>) => this.chunk(event.data.pcm, event.data.db);
      source.connect(node);
      if (context.state === "suspended") await context.resume().catch(() => {});
      if (overtaken()) return;
      ready = true;
    } finally {
      if (!ready) {
        // Failed or stopped part-way: close whatever was opened.
        stream?.getTracks().forEach((t) => t.stop());
        node?.disconnect();
        void context?.close().catch(() => {});
        if (!overtaken()) this.setStatus("off");
      }
    }

    this.stream = stream;
    this.context = context;
    this.node = node;
    this.detector = new EndOfTurnDetector({ ...this.detector.settings });
    this.chunks = [];
    this.bufferStart = 0;
    this.gate = new StreamGate(PREROLL_CHUNKS);
    this.setStatus("calibrating");

    this.transcriber = options.liveTranscript ? new ScribeLiveTranscriber() : new SilentTranscriber();
    this.transcriber.onText = (text) => {
      this.onLiveText(text);
      this.handle(this.detector.setTranscript(text));
    };
    this.transcriber.onError = (message) => this.onNotice(message);
    const transcriber = this.transcriber;
    transcriber.start().catch(() => {
      if (this.transcriber !== transcriber) return;
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
    this.startToken += 1;
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
    this.handle(this.detector.audio(db, CHUNK_SECONDS));
    // Only a turn (and the moment before it) goes to the live transcript, never the quiet room.
    const gate = this.gate.next(this.detector.hearingSound, this.chunks);
    for (const piece of gate.send) this.transcriber.send(piece);
    // A sound that was not a turn (a cough): close it off so its words do not join the next turn.
    if (gate.closed && this.status !== "finishing") void this.transcriber.finishTurn();
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
        // The sound began a moment before it was confirmed as speech.
        this.speechStartedAt = performance.now() - this.detector.settings.minimumSpeechSeconds * 1000;
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
      speechStartedAt: this.speechStartedAt,
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
