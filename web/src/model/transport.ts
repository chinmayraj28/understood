// Where a turn's events, actions and spoken replies come from.
//
// The conversation talks to a Transport, not to the server directly, so tests can stand in a
// scripted one (tests/fixtures/replayTransport.ts) and run the exact same page code.

import type { ActRequest, ActResponse, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { act, understand } from "../api/client";
import { ReplyPlayer } from "../audio/player";

export interface Transport {
  readonly kind: string;
  understand(request: UnderstandRequest, signal?: AbortSignal): AsyncIterable<PipelineEvent>;
  act(request: ActRequest): Promise<ActResponse>;
  /** Speaks a reply. Resolves when it has finished or been cut off. */
  speak(text: string): Promise<void>;
  stopSpeaking(): void;
  onSpeaking: (speaking: boolean) => void;
}

/** The real server, and the reply spoken through the speakers. */
export class LiveTransport implements Transport {
  readonly kind = "live" as const;
  private player = new ReplyPlayer();
  speechMuted = false;

  set onSpeaking(handler: (speaking: boolean) => void) {
    this.player.onSpeaking = handler;
  }
  get onSpeaking() {
    return this.player.onSpeaking;
  }

  understand(request: UnderstandRequest, signal?: AbortSignal) {
    return understand(request, signal);
  }
  act(request: ActRequest) {
    return act(request);
  }
  async speak(text: string) {
    if (this.speechMuted) return;
    try {
      await this.player.speak(text);
    } catch {
      // A reply that cannot be spoken is still shown on the page; nothing else depends on it.
    }
  }
  stopSpeaking() {
    this.player.stop();
  }
}

export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new DOMException("Stopped", "AbortError"));
    const timer = setTimeout(resolve, Math.max(0, ms));
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(new DOMException("Stopped", "AbortError"));
    });
  });
}
