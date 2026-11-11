// The live transcript: words on screen while the person speaks, and the third vote.
//
// ElevenLabs Scribe realtime over a WebSocket, opened with a single-use token from the server
// (the API key never reaches the browser). If it cannot open, the page keeps working: turns go
// to the pipeline without a live transcript, and the page says the live words are off.

import { realtimeToken } from "../api/client";
import { concat, pcmToBase64, SAMPLE_RATE } from "./wav";

export interface LiveTranscriber {
  /** Called with the turn's text so far (finished segments plus the current partial). */
  onText: (text: string) => void;
  onError: (message: string) => void;
  start(): Promise<void>;
  send(pcm: Int16Array): void;
  /** Ends the turn's transcript: asks for a final result, waits briefly, returns it, starts afresh. */
  finishTurn(waitMs?: number): Promise<string>;
  stop(): void;
}

/**
 * Connection details for Scribe realtime, verified by a live run on 9 Nov (web-pipeline).
 * commit_strategy is manual because the server's own silence detection commits after 1.5 s,
 * far too impatient for this speech; our detector decides when a turn ends.
 * No keyterms: the live transcript is the decider's hint-free check on the other two.
 */
export const SCRIBE_REALTIME = {
  url: "wss://api.elevenlabs.io/v1/speech-to-text/realtime",
  params: { model_id: "scribe_v2_realtime", audio_format: "pcm_16000", commit_strategy: "manual", language_code: "en" },
  /** Keyterms given to the live transcript. Sent as realtimeKeyterms with each turn too. */
  keyterms: [] as string[],
  /** Audio is sent in 100 ms pieces (five of the worklet's 20 ms chunks). */
  chunksPerSend: 5,
  /** Waits this long for the final text after asking for it. */
  finalWaitMs: 700,
};

/** Message types that carry no error. Anything else Scribe sends means the live words are off. */
const NORMAL_TYPES = new Set(["session_started", "partial_transcript", "edited_transcript"]);
const isFinal = (type: string) => type.startsWith("committed_transcript") || type.startsWith("final_transcript");

interface ScribeMessage {
  message_type?: string;
  text?: string;
  error?: string;
  message?: string;
}

export class ScribeLiveTranscriber implements LiveTranscriber {
  onText: (text: string) => void = () => {};
  onError: (message: string) => void = () => {};
  private socket: WebSocket | null = null;
  private committed: string[] = [];
  private partial = "";
  private waitingForFinal: (() => void) | null = null;
  private pending: string[] = [];


  private reconnects = 0;
  private stopped = false;

  async start() {
    this.stopped = false;
    const token = await realtimeToken();
    // Stopped while the token was on its way: open nothing.
    if (this.stopped) return;
    const params = new URLSearchParams({ ...SCRIBE_REALTIME.params, token });
    for (const term of SCRIBE_REALTIME.keyterms) params.append("keyterms", term);
    const socket = new WebSocket(`${SCRIBE_REALTIME.url}?${params}`);
    this.socket = socket;
    try {
      await new Promise<void>((resolve, reject) => {
        socket.onopen = () => resolve();
        socket.onerror = () => reject(new Error("The live transcript could not connect."));
      });
    } catch (error) {
      if (this.stopped) return; // closed on purpose while connecting: not a failure
      throw error;
    }
    if (this.stopped || this.socket !== socket) {
      socket.close();
      return;
    }
    socket.onmessage = (event) => this.receive(event.data as string);
    socket.onclose = () => {
      if (this.socket !== socket) return; // closed on purpose by stop()
      this.socket = null;
      // Tokens are single use, so reconnecting means a new token. A few tries, then give up.
      if (this.reconnects < 3) {
        this.reconnects += 1;
        setTimeout(() => {
          if (!this.stopped) this.start().catch(() => this.onError("The live transcript is off. Turns still go through the pipeline."));
        }, 1000);
      } else {
        this.onError("The live transcript closed. Turns still go through the pipeline.");
      }
    };
    for (const chunk of this.pending.splice(0)) socket.send(chunk);
  }

  private receive(raw: string) {
    let message: ScribeMessage;
    try {
      message = JSON.parse(raw) as ScribeMessage;
    } catch {
      return;
    }
    const type = message.message_type ?? "";
    if (type === "session_started") {
      this.reconnects = 0; // a working session: later drops get their full set of retries again
      return;
    }
    if (type === "partial_transcript") {
      this.partial = message.text ?? "";
    } else if (isFinal(type)) {
      if (message.text?.trim()) this.committed.push(message.text.trim());
      this.partial = "";
      this.waitingForFinal?.();
    } else if (NORMAL_TYPES.has(type)) {
      return;
    } else {
      // Any other type is an error (auth_error, rate_limited, commit_throttled, ...). The turn
      // goes on without the live transcript's vote; too little audio is not worth a notice.
      if (type !== "insufficient_audio_activity") this.onError(`The live transcript stopped (${type.replace(/_/g, " ")}). Turns still go through the pipeline.`);
      return;
    }
    this.onText(this.text());
  }

  private text() {
    return [...this.committed, this.partial].filter(Boolean).join(" ").trim();
  }

  private gathered: Int16Array[] = [];

  send(pcm: Int16Array) {
    this.gathered.push(pcm);
    if (this.gathered.length >= SCRIBE_REALTIME.chunksPerSend) this.flush();
  }

  private flush() {
    if (this.gathered.length === 0) return;
    const audio = concat(this.gathered);
    this.gathered = [];
    const message = JSON.stringify({
      message_type: "input_audio_chunk",
      audio_base_64: pcmToBase64(audio),
      commit: false,
      sample_rate: SAMPLE_RATE,
    });
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(message);
    else if (!this.socket && this.pending.length < 50) this.pending.push(message);
  }

  async finishTurn(waitMs = SCRIBE_REALTIME.finalWaitMs): Promise<string> {
    this.flush();
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ message_type: "input_audio_chunk", audio_base_64: "", commit: true, sample_rate: SAMPLE_RATE }));
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, waitMs);
        this.waitingForFinal = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      this.waitingForFinal = null;
    }
    const text = this.text();
    this.committed = [];
    this.partial = "";
    this.onText("");
    return text;
  }

  stop() {
    this.stopped = true;
    const socket = this.socket;
    this.socket = null;
    socket?.close();
  }
}

/** Used when the live transcript is off or unavailable: no words, never an error. */
export class SilentTranscriber implements LiveTranscriber {
  onText: (text: string) => void = () => {};
  onError: (message: string) => void = () => {};
  async start() {}
  send() {}
  async finishTurn() {
    return "";
  }
  stop() {}
}
