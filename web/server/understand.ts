// Runs one turn through the pipeline and reports each step as a PipelineEvent, in the order
// documented in shared/pipeline.ts. Ported from the Swift Understander.swift. The hearers and
// Claude are passed in, so tests can run the whole turn with fakes and no network.

import { DEMO_CONTACTS, type HearerName, type PhrasebookMatch, type PipelineEvent, type Reading, type UnderstandRequest } from "../shared/pipeline";
import { decide } from "../shared/rules/decider";
import { trustedPhrasebookMatch } from "../shared/rules/evidence";
import { bestMatch, matchesByHearer, phrasebookKeyterms } from "../shared/rules/phrasebook";
import { words } from "../shared/rules/speechText";
import { acceptedKeyterms, agreementSummary, keytermLimit } from "../shared/rules/turn";
import type { DecisionInput, Hypothesis } from "../shared/rules/types";
import { secondListenerModel, transcribeGeminiModel, type HearingRequest } from "./hearers";
import { plainMessage, withTimeLimit } from "./http";
import type { RepairInput } from "./repair";

export interface UnderstandDeps {
  hearScribe(request: HearingRequest): Promise<string>;
  hearGemini(request: HearingRequest): Promise<string>;
  repair(input: RepairInput, signal: AbortSignal, seconds: number): Promise<Reading>;
  now(): number;
  /** A recogniser slower than this counts as failed for this turn; the others go on. */
  hearerSeconds: number;
  /** The repair call is abandoned after this, and the decider works without a reading. */
  repairSeconds: number;
}

/** Time limits for a recording being transcribed, where accuracy matters more than speed. */
export const TRANSCRIBE_LIMITS = { hearerSeconds: 15, repairSeconds: 8, secondListenerSeconds: 15 };

/**
 * What the recognisers are told: the expected answers first (most likely in this turn), then the
 * person's own phrases, then the page's words and the demo contacts (not when transcribing a
 * recording, which is not talking to the phone). Within Scribe's rules, at most 100. The
 * phrasebook's phrases are left out when the phrasebook is switched off.
 */
export function hintsFor(request: UnderstandRequest, now: number): string[] {
  if (!request.switches.keyterms) return [];
  // A recording is heard without hints: on TORGO dev clips the speaker's set-up phrases as Scribe
  // keyterms raised words wrong from 25.2% to 28.2%, pulling new sentences towards known ones.
  // Claude still sees them as known phrases (below), where it can weigh them.
  if (request.purpose === "transcribe") return [];
  const own = request.switches.phrasebook ? phrasebookKeyterms(request.phrasebook, keytermLimit, now) : [];
  return acceptedKeyterms([...(request.context.expectedAnswers ?? []), ...own, ...request.keyterms, ...DEMO_CONTACTS], keytermLimit);
}

export async function understandTurn(
  request: UnderstandRequest, deps: UnderstandDeps, emit: (event: PipelineEvent) => void, signal?: AbortSignal,
): Promise<void> {
  const start = deps.now();
  const at = () => deps.now();
  const transcribing = request.purpose === "transcribe";
  const hearerSeconds = transcribing ? Math.max(deps.hearerSeconds, TRANSCRIBE_LIMITS.hearerSeconds) : deps.hearerSeconds;
  const repairSeconds = transcribing ? Math.max(deps.repairSeconds, TRANSCRIBE_LIMITS.repairSeconds) : deps.repairSeconds;
  const keyterms = hintsFor(request, start);
  const examples = request.switches.gemini && request.switches.examples ? request.examples.slice(0, 5) : [];
  emit({ type: "turn.started", turnId: request.turnId, at: start, keyterms, exampleCount: examples.length });

  // Stage 2: the hearers, in parallel, each with its own time limit.
  const hearers: { name: HearerName; hear: (r: HearingRequest) => Promise<string>; seconds?: number }[] = [{ name: "scribe", hear: deps.hearScribe }];
  if (request.switches.gemini) {
    if (transcribing) {
      // A recording is heard by two independent Gemini models with the transcription prompt:
      // listeners that make different mistakes are what lets the merge correct them.
      hearers.push({ name: "gemini", hear: (r) => deps.hearGemini({ ...r, model: transcribeGeminiModel }) });
      hearers.push({ name: "gemini4", hear: (r) => deps.hearGemini({ ...r, model: secondListenerModel }), seconds: TRANSCRIBE_LIMITS.secondListenerSeconds });
    } else {
      hearers.push({ name: "gemini", hear: deps.hearGemini });
    }
  }
  for (const hearer of hearers) emit({ type: "hear.started", hearer: hearer.name, at: at() });
  emit({ type: "hear.started", hearer: "realtime", at: at() });

  // The realtime transcript was heard in the browser while the person spoke, so it is done at once.
  const realtimeText = (request.realtimeText ?? "").trim();
  const realtime: Hypothesis = realtimeText
    ? { hearer: "realtime", text: realtimeText, seconds: 0 }
    : { hearer: "realtime", text: "", seconds: 0, failure: "The live transcript had no words." };
  emit({ type: "hear.done", hearer: "realtime", at: at(), text: realtime.text, seconds: 0, ...(realtime.failure ? { failure: realtime.failure } : {}) });

  const heard = await Promise.all(hearers.map(async ({ name, hear, seconds: own }): Promise<Hypothesis> => {
    const limit = own ?? hearerSeconds;
    const began = deps.now();
    let hypothesis: Hypothesis;
    try {
      const text = await hear({
        wavBase64: request.wavBase64, keyterms, examples,
        signal: withTimeLimit(limit * 1000, signal), seconds: limit,
        ...(transcribing ? { purpose: "transcribe" as const } : {}),
      });
      hypothesis = { hearer: name, text: text.trim(), seconds: (deps.now() - began) / 1000 };
    } catch (error) {
      hypothesis = { hearer: name, text: "", seconds: (deps.now() - began) / 1000, failure: plainMessage(error, name) };
    }
    emit({ type: "hear.done", hearer: name, at: at(), text: hypothesis.text, seconds: hypothesis.seconds, ...(hypothesis.failure ? { failure: hypothesis.failure } : {}) });
    return hypothesis;
  }));
  // Results keep one order (Scribe, Gemini, realtime) whatever order they finished in.
  const hypotheses = [...heard, realtime];
  const transcripts = hypotheses.map((hypothesis) => hypothesis.text).filter((text) => words(text).length > 0);

  emit({ type: "agreement", at: at(), ...agreementSummary(hypotheses) });

  // Stage 3a: the phrasebook. Same-recogniser matches are what the decider may act on; the best
  // one overall is shown, and given to the repair stage as a hint.
  const compared = new Map<string, number>(); // each heard/stored pair is compared once
  const byHearer = request.switches.phrasebook ? matchesByHearer(request.phrasebook, hypotheses, start, compared) : {};
  const hint = request.switches.phrasebook ? bestMatch(request.phrasebook, transcripts, start, compared) : null;
  const heardAny = hypotheses.filter((hypothesis) => words(hypothesis.text).length > 0);
  const trusted = trustedPhrasebookMatch(heardAny, byHearer);
  const shown: PhrasebookMatch | null = trusted ? { ...trusted, strong: true } : hint ? { ...hint, strong: false } : null;
  emit({ type: "phrasebook", at: at(), match: shown });

  const input: DecisionInput = {
    hypotheses, matchesByHearer: byHearer, hintedTerms: keyterms, realtimeKeyterms: request.realtimeKeyterms ?? [], context: request.context,
    failedTries: request.context.failedTries ?? 0,
  };

  // Fast path: when the evidence alone already lets the decider act (agreement, a strong
  // phrasebook match, an expected answer, or "stop"), the repair call is skipped.
  let decided = decide(input);
  if (decided.decision.kind === "act") {
    emit({ type: "repair.skipped", at: at(), why: "The evidence alone was enough to act, so Claude was not asked." });
  } else if (transcripts.length === 0) {
    emit({ type: "repair.skipped", at: at(), why: "Nothing was heard, so there was nothing to repair." });
  } else if (!request.switches.repair) {
    emit({ type: "repair.skipped", at: at(), why: "Repair is switched off." });
  } else {
    emit({ type: "repair.started", at: at() });
    const began = deps.now();
    try {
      // Contacts first: Claude is shown at most 40 known words, and the contacts must be among them.
      const knownWords = transcribing ? (request.switches.keyterms ? request.keyterms : []) : [...DEMO_CONTACTS, ...request.keyterms];
      input.reading = await deps.repair(
        { hypotheses, phrasebookMatch: hint, context: request.context, knownWords, purpose: request.purpose, examplesShown: examples.length },
        withTimeLimit(repairSeconds * 1000, signal),
        repairSeconds,
      );
      emit({ type: "repair.done", at: at(), reading: input.reading, seconds: (deps.now() - began) / 1000 });
    } catch (error) {
      // Claude down or slow: decide without a reading (agreement, phrasebook, else ask).
      emit({ type: "repair.skipped", at: at(), why: `Claude didn't answer (${plainMessage(error, "Claude")}), so it decides without a reading.` });
    }
    decided = decide(input);
  }

  emit({ type: "decision", at: at(), decision: decided.decision, rule: decided.rule });
  emit({ type: "turn.done", at: at(), seconds: (deps.now() - start) / 1000 });
}
