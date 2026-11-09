// "Set up your voice": the person reads ten short phrases. Each clip is heard by the
// recognisers (no repair, no phrasebook), stored with the phrase it was meant to be, and every
// recogniser that heard something else becomes a phrasebook entry. The clips also become the
// examples Gemini is shown, so it learns how this person sounds without any training.

import type { HearerName, PipelineEvent } from "../../shared/pipeline";
import { SCRIBE_REALTIME } from "../audio/liveTranscript";
import type { Conversation } from "./conversation";
import { learnEnrolmentPair, normalise, wordMiss } from "./learning";

export const SETUP_PHRASES = [
  "Call Mum",
  "Message Sam I'm running late",
  "Set a timer for ten minutes",
  "Play some music",
  "Yes",
  "No",
  "Call Priya",
  "Remind me to ring Amma at six",
  "Message Dad see you soon",
  "Stop the music",
];

/** Spoken words that steer setup instead of being a phrase. */
export function setupCommand(text: string | undefined): "again" | "skip" | "finish" | null {
  const said = normalise(text ?? "");
  if (["again", "say it again", "try again", "redo"].includes(said)) return "again";
  if (["skip", "next", "skip it"].includes(said)) return "skip";
  if (["finish", "finish setup", "stop setup", "that's enough"].includes(said)) return "finish";
  return null;
}

export interface EnrolResult {
  heard: Partial<Record<HearerName, string>>;
  failures: Partial<Record<HearerName, string>>;
  learned: number;
}

export async function enrolPhrase(conversation: Conversation, phrase: string, wavBase64: string, realtimeText?: string): Promise<EnrolResult> {
  const heard: EnrolResult["heard"] = {};
  const failures: EnrolResult["failures"] = {};
  const events: AsyncIterable<PipelineEvent> = conversation.transport.understand({
    turnId: `setup-${Date.now().toString(36)}`,
    wavBase64,
    realtimeText,
    realtimeKeyterms: SCRIBE_REALTIME.keyterms,
    phrasebook: [],
    examples: [],
    keyterms: phrase.split(/\s+/).filter((w) => /^[A-Z]/.test(w)),
    context: { recentTurns: [] },
    switches: { keyterms: true, gemini: true, examples: false, phrasebook: false, repair: false },
  });
  for await (const event of events) {
    if (event.type === "hear.done") {
      if (event.failure) failures[event.hearer] = event.failure;
      else heard[event.hearer] = event.text;
    }
    if (event.type === "turn.failed") throw new Error(event.message);
    if (event.type === "agreement") break; // the rest is not needed for setup
  }

  let entries = conversation.getState().entries;
  const changed = [];
  for (const [hearer, text] of Object.entries(heard) as [HearerName, string][]) {
    if (!text.trim() || normalise(text) === normalise(phrase)) continue; // heard right: nothing to learn
    const result = learnEnrolmentPair(entries, text, phrase, hearer);
    entries = result.entries;
    changed.push(...result.changed);
  }
  if (changed.length) await conversation.addEntries(entries, changed);
  const difficulty = Math.max(0, ...Object.values(heard).map((t) => wordMiss(t ?? "", phrase)));
  await conversation.addClip({ id: `setup-${normalise(phrase).replace(/ /g, "-")}`, text: phrase, wavBase64, createdAt: Date.now(), source: "enrolment", difficulty });
  return { heard, failures, learned: changed.length };
}
