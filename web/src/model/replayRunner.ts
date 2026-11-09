// Plays an example conversation through the real page code: the live transcript writes itself
// word by word with a made-up waveform, then the turn goes to the Conversation exactly as a
// spoken turn would, with a ReplayTransport standing in for the server.

import type { Replay } from "../fixtures";
import type { Conversation } from "./conversation";
import { sleep } from "./transport";

export interface ReplayHooks {
  /** The live transcript and loudness while the example "speaks"; replaying=false when it stops. */
  onLive(text: string, level: number, replaying: boolean): void;
}

export async function runReplay(
  replay: Replay,
  conversation: Conversation,
  hooks: ReplayHooks,
  signal: AbortSignal,
  origin: "replay" | "evaluation" = "replay",
) {
  for (const turn of replay.turns) {
    let text = "";
    let lastWordAt = 0;
    const started = performance.now();
    // A pretend voice: loud while a word is landing, nearly silent in the pauses.
    const levels = setInterval(() => {
      const since = performance.now() - started - lastWordAt;
      const speaking = since < 420 && performance.now() - started < turn.speechSeconds * 1000;
      const level = speaking ? 0.3 + 0.45 * Math.abs(Math.sin(since / 37)) * (0.6 + Math.random() * 0.4) : 0.02 + Math.random() * 0.02;
      hooks.onLive(text, level, true);
    }, 45);
    try {
      hooks.onLive("", 0, true);
      for (const [at, partial] of turn.partials) {
        await sleep(at - (performance.now() - started), signal);
        text = partial;
        lastWordAt = at;
      }
      await sleep(turn.speechSeconds * 1000 + 500 - (performance.now() - started), signal);
    } finally {
      clearInterval(levels);
    }
    hooks.onLive(text, 0, false);
    if (signal.aborted) return;
    await conversation.submitTurn({
      wavBase64: "",
      realtimeText: text || undefined,
      liveText: text,
      speechSeconds: turn.speechSeconds,
      origin,
      label: replay.title,
    });
    if (signal.aborted) return;
    await sleep(1100, signal);
  }
}
