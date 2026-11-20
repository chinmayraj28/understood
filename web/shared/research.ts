// The Research page's data: what training a speech model on recordings of dysarthric speech did,
// on speakers it never heard (the leave-one-speaker-out test) and on speakers it trained on.
//
// Two sources, kept apart on purpose:
//   - /research/results.json (in public/): numbers only. Safe to publish, so the findings show on
//     the hosted site too.
//   - /api/research/* (local server only): each clip's prompt and what the models wrote, and the
//     live tuned model. TORGO text and audio never leave this computer, exactly as for
//     /api/dataset.

/** A share of words wrong with its 95% interval, all as fractions (0.246 is 24.6%). */
export interface ResearchRate {
  wer: number;
  low: number;
  high: number;
}

/** One row of the held-out table: the same clips heard by the untuned and the tuned model. */
export interface ResearchRow {
  /** "unseen", "all", "dysarthric-unseen", "unseen-word", ... */
  key: string;
  /** Plain words for the page: "Prompts never trained on". */
  label: string;
  clips: number;
  untuned: ResearchRate;
  tuned: ResearchRate;
}

/** One model at one stage, on the dev clips (used to choose the model). Fractions. */
export interface ResearchDevRow {
  /** "whisper", "granite" or "parakeet". */
  model: string;
  /** "Whisper large-v3-turbo". */
  name: string;
  /** "untuned", "tuned" (all speakers together) or "personalised" (then per speaker). */
  stage: "untuned" | "tuned" | "personalised";
  unseen: number;
  all: number;
  words: number;
  sentences: number;
}

export interface ResearchSpeaker {
  speaker: string;
  dysarthric: boolean;
  /** Share of words wrong on that speaker's held-out clips. */
  untuned: number;
  tuned: number;
}

/** How many clips play each part, fixed before any training. */
export interface ResearchSplit {
  role: "train" | "val" | "dev" | "holdout";
  clips: number;
  minutes: number;
  /** Of these, clips whose prompt no speaker said in the training clips. */
  neverTrained: number;
}

/** One speaker in the leave-one-speaker-out test, scored by a model that never heard them. */
export interface ResearchLosoSpeaker {
  speaker: string;
  /** Share of words wrong. Known to whole percents only (0.44 is 44%). */
  untuned: number;
  tuned: number;
}

/**
 * The leave-one-speaker-out test: for each speaker with dysarthria, a model trained on every
 * other speaker, then tested on that one speaker, whom it had never heard.
 */
export interface ResearchLoso {
  date: string;
  /** The model's Hugging Face id. */
  model: string;
  /** How many speakers were left out in turn. */
  speakers: number;
  note: string;
  /** "all", "new-prompt", "sentence", "word", "new-prompt-sentence", "new-prompt-word". */
  rows: ResearchRow[];
  perSpeaker: ResearchLosoSpeaker[];
}

/** /research/results.json */
export interface ResearchResults {
  /** The leave-one-speaker-out test. Missing from results files written before 20 Nov 2026. */
  loso?: ResearchLoso;
  date: string;
  /** The chosen model's Hugging Face id. */
  model: string;
  personalised: boolean;
  speakers: number;
  secondsPerClip: number;
  trainingMinutes: number;
  split: ResearchSplit[];
  heldOut: ResearchRow[];
  dev: ResearchDevRow[];
  perSpeaker: ResearchSpeaker[];
}

/** One clip in the tester. */
export interface ResearchClip {
  id: string;
  speaker: string;
  /** "word" or "sentence". */
  kind: string;
  /** What the speaker was asked to say. */
  prompt: string;
  seconds: number;
  role: "train" | "val" | "dev" | "holdout";
  /** True when the prompt (or, for a single word, the word) is somewhere in the training clips. */
  seen: boolean;
  dysarthric: boolean;
  /** What the untuned model wrote, when it was scored on this clip (dev and held-out only). */
  untuned?: string;
  /** What the tuned model wrote on Colab. */
  tuned?: string;
}

/** GET /api/research/clips */
export type ResearchClipsResponse = { available: true; clips: ResearchClip[] } | { available: false; reason: string };

/** GET /api/research/status */
export interface ResearchStatus {
  /** The saved Colab results are on this computer. */
  saved: boolean;
  /** The tuned model is running on this computer and can hear a clip now. */
  live: boolean;
  /** For example "openai/whisper-large-v3-turbo, tuned". */
  model?: string;
}

/** POST /api/research/transcribe. Exactly one of clipId and wavBase64. */
export interface ResearchTranscribeRequest {
  /** A TORGO clip: heard by that speaker's own tuned model. */
  clipId?: string;
  /** Any 16 kHz mono 16-bit WAV, base64: heard by the all-speakers tuned model. */
  wavBase64?: string;
}

export interface ResearchTranscribeResponse {
  text: string;
  /** How long the model took, in seconds. */
  seconds: number;
  /** Which tuned model heard it: a speaker id, or "all speakers". */
  voice: string;
}

/** The address of the local model service (train/serve.py). */
export const RESEARCH_MODEL_URL = "http://127.0.0.1:8791";
