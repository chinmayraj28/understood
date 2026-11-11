// Whose voice a recording is heard as. Each voice brings what the pipeline knows about that
// person: their phrasebook, a few of their clips for Gemini, and the words they tend to say.
//
//   - "Your voice": what you set up in this browser (the conversation's own phrasebook and clips).
//   - "Nobody in particular": nothing known, so only the recognisers and Claude's repair help.
//   - A TORGO speaker: set up from that speaker's own enrolment clips, exactly as the evaluation
//     did (eval/README.md, section 2). Up to 20 clips, prompts said again later first; each is
//     heard by Scribe, and where Scribe heard something else the phrasebook learns "heard ->
//     meant". Their prompts become the known phrases Claude is shown, and five clips become the
//     examples both Gemini listeners hear. Test clips are never used, so a test clip is heard fairly.

import type { DatasetClip, DatasetIndex } from "../../shared/dataset";
import type { HearerName, PhrasebookEntry, PipelineEvent, SpeechExample, UnderstandRequest } from "../../shared/pipeline";
import { scoringWords } from "../../shared/wordErrors";
import { chooseExamples, learnEnrolmentPair, normalise, wordMiss, words, type Clip } from "./learning";

export interface Voice {
  id: string;
  label: string;
  phrasebook: PhrasebookEntry[];
  examples: SpeechExample[];
  keyterms: string[];
  /** The clips this voice was set up from: hearing one of them again is not a fair test. */
  setupClipIds: string[];
  /** Normalised prompts of those clips: a test clip saying one of them is "seen". */
  setupPrompts: string[];
}

export const NOBODY: Voice = { id: "nobody", label: "Nobody in particular", phrasebook: [], examples: [], keyterms: [], setupClipIds: [], setupPrompts: [] };

/** The evaluation's cap on set-up clips per speaker. */
export const SETUP_CLIP_LIMIT = 20;
/** The server's limit on words in a phrasebook phrase. */
const MAX_PHRASE_WORDS = 20;

/** A speaker's set-up clips, chosen as the evaluation chose them. */
export function setupClipsFor(index: DatasetIndex, speaker: string, limit = SETUP_CLIP_LIMIT): DatasetClip[] {
  const enrolment = index.clips.filter((c) => c.speaker === speaker && c.split === "enrolment");
  const repeated = enrolment.filter((c) => c.repeatedLater);
  const rest = enrolment.filter((c) => !c.repeatedLater);
  return [...repeated, ...rest].slice(0, limit);
}

/** Distinct prompts, most frequent first: the hints Scribe is given for this speaker. */
export function keytermsFrom(prompts: string[], limit = 200): string[] {
  const counts = new Map<string, { count: number; first: number; text: string }>();
  prompts.forEach((prompt, index) => {
    const key = scoringWords(prompt).join(" ");
    if (!key) return;
    const seen = counts.get(key);
    counts.set(key, { count: (seen?.count ?? 0) + 1, first: seen?.first ?? index, text: seen?.text ?? prompt });
  });
  return [...counts.values()]
    .sort((a, b) => (a.count !== b.count ? b.count - a.count : a.first - b.first))
    .slice(0, limit)
    .map((v) => v.text);
}

export interface SetupProgress {
  done: number;
  total: number;
}

export interface SetupDeps {
  understand(request: UnderstandRequest, signal?: AbortSignal): AsyncIterable<PipelineEvent>;
  /** The clip's 16 kHz mono WAV as base64. */
  loadWav(clip: DatasetClip): Promise<string>;
  onProgress(progress: SetupProgress): void;
  signal?: AbortSignal;
}

/** Sets up a TORGO speaker's voice from their enrolment clips. Three clips are heard at a time. */
export async function setUpSpeaker(index: DatasetIndex, speaker: string, label: string, deps: SetupDeps): Promise<Voice> {
  const clips = setupClipsFor(index, speaker);
  const keyterms = keytermsFrom(clips.map((c) => c.prompt));
  let entries: PhrasebookEntry[] = [];
  const kept: Clip[] = [];
  let done = 0;
  deps.onProgress({ done, total: clips.length });

  const work = clips.map((clip, order) => async () => {
    const wavBase64 = await deps.loadWav(clip);
    const heard = await hearForSetup(deps, wavBase64, keyterms, clip.id);
    for (const [hearer, text] of Object.entries(heard) as [HearerName, string][]) {
      if (!text.trim() || normalise(text) === normalise(clip.prompt)) continue; // heard right: nothing to learn
      if (words(text).length > MAX_PHRASE_WORDS || words(clip.prompt).length > MAX_PHRASE_WORDS) continue;
      entries = learnEnrolmentPair(entries, text, clip.prompt, hearer).entries;
    }
    const difficulty = Math.max(0, ...Object.values(heard).map((t) => wordMiss(t ?? "", clip.prompt)));
    // createdAt keeps recording order, so "most recent" means the speaker's latest set-up clips.
    kept.push({ id: clip.id, text: clip.prompt, wavBase64, createdAt: order, source: "enrolment", difficulty });
    deps.onProgress({ done: ++done, total: clips.length });
  });
  await inBatches(work, 3, deps.signal);

  return {
    id: `torgo:${speaker}`,
    label,
    phrasebook: entries,
    examples: chooseExamples(kept),
    keyterms,
    setupClipIds: clips.map((c) => c.id),
    setupPrompts: clips.map((c) => scoringWords(c.prompt).join(" ")),
  };
}

/** Hears one set-up clip with Scribe alone, as a recording (no hints), so the phrasebook matches what Scribe hears later. */
async function hearForSetup(deps: SetupDeps, wavBase64: string, keyterms: string[], clipId: string): Promise<Partial<Record<HearerName, string>>> {
  const heard: Partial<Record<HearerName, string>> = {};
  const events = deps.understand(
    {
      turnId: `setup-${clipId}`,
      wavBase64,
      phrasebook: [],
      examples: [],
      keyterms,
      context: { recentTurns: [] },
      // Scribe alone: the phrasebook matches Scribe's mishearings, and setting up 20 clips stays fast.
      switches: { keyterms: true, gemini: false, examples: false, phrasebook: false, repair: false },
      purpose: "transcribe",
    },
    deps.signal,
  );
  for await (const event of events) {
    if (event.type === "hear.done" && !event.failure) heard[event.hearer] = event.text;
    if (event.type === "turn.failed") throw new Error(event.message);
    if (event.type === "agreement") break; // the rest is not needed for setup
  }
  return heard;
}

async function inBatches(jobs: (() => Promise<void>)[], size: number, signal?: AbortSignal) {
  let next = 0;
  const failures: unknown[] = [];
  const runner = async () => {
    while (next < jobs.length) {
      if (signal?.aborted) throw new DOMException("Stopped", "AbortError");
      const job = jobs[next++];
      // One clip that cannot be heard does not spoil the setup; the rest still teach.
      await job().catch((error) => {
        if ((error as Error).name === "AbortError") throw error;
        failures.push(error);
      });
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, jobs.length) }, runner));
  if (failures.length === jobs.length && jobs.length > 0) throw failures[0];
}
