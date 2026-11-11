// A scripted stand-in for the server, for tests: each turn's events come out with the same gaps
// as in the script, re-stamped with the current time.

import type { ActRequest, ActResponse, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { normalise } from "../../src/model/learning";
import { sleep, type Transport } from "../../src/model/transport";
import type { Replay } from "./index";

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

