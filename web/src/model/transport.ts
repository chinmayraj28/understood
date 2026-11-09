// Where a turn's events, actions and spoken replies come from.
//
// The conversation does not know whether it is talking to the real server or playing back an
// example: both are a Transport. That is how replays run the exact same page code as live turns.

import type { ActRequest, ActResponse, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { act, understand } from "../api/client";
import { ReplyPlayer } from "../audio/player";
import type { Replay } from "../fixtures";
import { normalise } from "./learning";

export interface Transport {
  readonly kind: "live" | "replay";
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

/**
 * Plays back an example. Events come out with the same gaps as in the script, re-stamped with
 * the current time, so stopwatches and the timing strip behave as they would live.
 */
export class ReplayTransport implements Transport {
  readonly kind = "replay" as const;
  private turnIndex = 0;
  onSpeaking: (speaking: boolean) => void = () => {};
  private finishSpeaking: (() => void) | null = null;

  constructor(
    private replay: Replay,
    private speed = 1,
  ) {}

  async *understand(_request: UnderstandRequest, signal?: AbortSignal): AsyncGenerator<PipelineEvent> {
    const turn = this.replay.turns[this.turnIndex++];
    if (!turn) {
      yield { type: "turn.failed", at: Date.now(), message: "This example has no more turns." };
      return;
    }
    const base = Date.now();
    let previous = 0;
    for (const event of turn.events) {
      await sleep((event.at - previous) / this.speed, signal);
      previous = event.at;
      yield { ...event, at: base + event.at } as PipelineEvent;
    }
  }

  async act(request: ActRequest): Promise<ActResponse> {
    await sleep(420 / this.speed);
    return (
      this.replay.acts[normalise(request.text)] ?? {
        action: { kind: "none" },
        reply: "This example has no action for that.",
        needsConfirmation: false,
      }
    );
  }

  /** No audio in replays: the reply is shown, and the pause is about as long as saying it. */
  async speak(text: string) {
    this.onSpeaking(true);
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, Math.min(2600, 400 + text.length * 45) / this.speed);
      this.finishSpeaking = () => {
        clearTimeout(timer);
        resolve();
      };
    });
    this.finishSpeaking = null;
    this.onSpeaking(false);
  }

  stopSpeaking() {
    this.finishSpeaking?.();
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
