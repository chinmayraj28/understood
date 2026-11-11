// The conversation: sends each turn through the pipeline, then acts, asks, or learns.
//
// The rules that decide act-or-ask live on the server, in code. This file only follows the
// decision, and adds the one rule the page owns: anything that reaches another person (a
// message, a call) waits for a spoken yes that has itself gone through the pipeline.
//
// Learning, in plain words:
//   - a spoken yes, or a chosen option: every recogniser that heard something else gets a
//     "heard -> meant" entry (or an existing one is bumped);
//   - a correction ("no, Sam"): entries with the corrected meaning;
//   - a plain "no": nothing;
//   - an action that simply went ahead: nothing, because nobody confirmed what it meant.

import type { ActResponse, PhrasebookEntry, StageSwitches, UnderstandRequest } from "../../shared/pipeline";
import { SCRIBE_REALTIME } from "../audio/liveTranscript";
import type { VoiceStore } from "../storage/store";
import { chooseExamples, keytermsFor, words, type Clip } from "./learning";
import { PHONE_HOME, phoneCancel, type PhoneState } from "./phone";
import { similarity } from "../../shared/rules";
import { afterAct, isExpired, resolveDecision, type Pending } from "./answers";
import type { Transport } from "./transport";
import type { Voice } from "./voices";
import { ALL_ON, bestText, heardText, newTurn, reduceTurn, type TurnModel } from "./turn";

export type { Pending } from "./answers";

export interface ChatLine {
  id: number;
  who: "you" | "assistant" | "note";
  text: string;
  tone?: "question" | "done" | "error" | "learned";
}

export interface ConversationState {
  turns: TurnModel[];
  pending?: Pending;
  failedTries: number;
  chat: ChatLine[];
  phone: PhoneState;
  entries: PhrasebookEntry[];
  /** Ids of entries added or bumped by the latest turn, so the panel can show them arriving. */
  justLearned: string[];
  clipCount: number;
  busy: boolean;
  speaking: boolean;
  switches: StageSwitches;
  persistent: boolean;
}

export interface TurnInput {
  wavBase64: string;
  realtimeText?: string;
  liveText: string;
  speechSeconds?: number;
  origin: TurnModel["origin"];
  label?: string;
  /** performance.now() when the person started speaking. Missing in scripted tests. */
  speechStartedAt?: number;
}

/** A recording to transcribe: a TORGO clip or a file the person chose. */
export interface RecordingInput {
  wavBase64: string;
  /** The live recogniser's final text from playing the recording, if it could be reached. */
  realtimeText?: string;
  speechSeconds: number;
  recording: NonNullable<TurnModel["recording"]>;
  /** Whose voice to hear it as. Undefined means your own (this browser's phrasebook and clips). */
  voice?: Voice;
}

let lineId = 0;
let turnCount = 0;
/** Recordings kept in memory for turns that may still be confirmed. */
const MAX_KEPT_RECORDINGS = 12;
/** A turn this close to what the assistant just said is its own voice leaking back in. */
const ECHO_SIMILARITY = 0.8;

export class Conversation {
  private state: ConversationState;
  private listeners = new Set<() => void>();
  private queue: Promise<void> = Promise.resolve();
  private clips: Clip[] = [];
  private recent: string[] = [];
  private wavByTurn = new Map<string, string>();
  /** The last thing the assistant said, to recognise its own voice coming back as a turn. */
  private lastSpoken = "";
  private abort = new AbortController();

  private constructor(
    readonly transport: Transport,
    private store: VoiceStore,
    entries: PhrasebookEntry[],
    clips: Clip[],
  ) {
    this.clips = clips;
    this.state = {
      turns: [],
      failedTries: 0,
      chat: [],
      phone: PHONE_HOME,
      entries,
      justLearned: [],
      clipCount: clips.length,
      busy: false,
      speaking: false,
      switches: ALL_ON,
      persistent: store.persistent,
    };
    transport.onSpeaking = (speaking) => this.set({ speaking });
  }

  static async create(transport: Transport, store: VoiceStore): Promise<Conversation> {
    const [entries, clips] = await Promise.all([store.loadEntries(), store.loadClips()]);
    return new Conversation(transport, store, entries, clips);
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getState = () => this.state;

  private set(patch: Partial<ConversationState>) {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }

  private patchTurn(turnId: string, update: (turn: TurnModel) => TurnModel) {
    this.set({ turns: this.state.turns.map((t) => (t.turnId === turnId ? update(t) : t)) });
  }

  setSwitches(switches: StageSwitches) {
    this.set({ switches });
  }

  /** Stops a reply mid-word: called the moment the person starts speaking. */
  interrupt() {
    this.transport.stopSpeaking();
  }

  dispose() {
    this.abort.abort();
    this.transport.stopSpeaking();
    this.listeners.clear();
  }

  /** Sends a turn through the pipeline. Turns are handled one at a time, in order. */
  submitTurn(input: TurnInput): Promise<void> {
    // Whatever happens inside (a stop, a timeout, an error), busy is cleared and the next turn runs.
    this.queue = this.queue
      .then(() =>
        this.runTurn(input).finally(() => {
          if (this.state.busy) this.set({ busy: false });
        }),
      )
      .catch(() => {});
    return this.queue;
  }

  /**
   * Hears a recording through the whole pipeline and shows what it understood. Nothing is acted
   * on, asked, spoken or learned: the point is the transcript. The context is empty, as in the
   * evaluation, so earlier recordings cannot steer this one.
   */
  transcribe(input: RecordingInput): Promise<void> {
    this.queue = this.queue
      .then(() =>
        this.runRecording(input).finally(() => {
          if (this.state.busy) this.set({ busy: false });
        }),
      )
      .catch(() => {});
    return this.queue;
  }

  private async runRecording(input: RecordingInput) {
    const { switches } = this.state;
    const turnId = `file-${Date.now().toString(36)}-${++turnCount}`;
    let turn = newTurn({ turnId, origin: "file", label: input.recording.label, liveText: input.realtimeText ?? "", switches });
    turn = { ...turn, speechSeconds: input.speechSeconds, recording: input.recording };
    this.set({ turns: [...this.state.turns.slice(-11), turn], busy: true, justLearned: [] });
    const voice = input.voice;
    const request: UnderstandRequest = {
      turnId,
      wavBase64: input.wavBase64,
      realtimeText: input.realtimeText,
      realtimeKeyterms: SCRIBE_REALTIME.keyterms,
      phrasebook: voice ? voice.phrasebook : this.state.entries,
      examples: voice ? voice.examples : chooseExamples(this.clips),
      // Your own voice: the phrases you have confirmed, as known phrases (not the demo phone's contacts).
      keyterms: voice ? voice.keyterms : [...new Set(this.state.entries.map((e) => e.meant))].slice(0, 40),
      context: { recentTurns: [] },
      switches,
      purpose: "transcribe",
    };
    try {
      for await (const event of this.transport.understand(request, this.abort.signal)) {
        this.patchTurn(turnId, (t) => reduceTurn(t, event, performance.now()));
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      const message = (error as Error).message || "The recording could not be heard.";
      this.patchTurn(turnId, (t) => reduceTurn(t, { type: "turn.failed", at: Date.now(), message }, performance.now()));
    }
  }

  private async runTurn(input: TurnInput) {
    const { switches } = this.state;
    let pending = this.state.pending;

    // A question waits a minute at most; after that, whatever is said is a new request.
    if (pending && isExpired(pending, Date.now())) {
      this.dropPending(`The question "${pending.question}" went unanswered for a minute, so it was dropped.`);
      pending = undefined;
    }
    // An answer only counts if it was spoken after the question finished playing. A "yes"
    // said before (or over) "Send it to Mum?" was not an answer to it.
    if (pending && input.speechStartedAt !== undefined && (pending.askedAt === undefined || input.speechStartedAt < pending.askedAt)) {
      this.note("That was said before the question finished, so it does not count as an answer.", "error");
      await this.askPending(pending, pending.question);
      return;
    }
    if (this.isEcho(input.realtimeText)) {
      this.note("Ignored a turn that sounded like the assistant's own voice.", "error");
      return;
    }

    const turnId = `turn-${Date.now().toString(36)}-${++turnCount}`;
    let turn = newTurn({ turnId, origin: input.origin, label: input.label, liveText: input.liveText, switches, answering: pending?.question });
    turn = { ...turn, speechSeconds: input.speechSeconds };
    if (input.wavBase64) {
      this.wavByTurn.set(turnId, input.wavBase64);
      // Keep only recent recordings: an old turn can no longer be confirmed.
      while (this.wavByTurn.size > MAX_KEPT_RECORDINGS) this.wavByTurn.delete(this.wavByTurn.keys().next().value!);
    }
    this.set({ turns: [...this.state.turns.slice(-11), turn], busy: true, justLearned: [] });

    const request: UnderstandRequest = {
      turnId,
      wavBase64: input.wavBase64,
      realtimeText: input.realtimeText,
      realtimeKeyterms: SCRIBE_REALTIME.keyterms,
      phrasebook: this.state.entries,
      examples: chooseExamples(this.clips),
      keyterms: keytermsFor(this.state.entries),
      context: {
        pendingQuestion: pending?.question,
        expectedAnswers: pending?.expectedAnswers,
        recentTurns: this.recent.slice(-6),
        failedTries: this.state.failedTries,
      },
      switches,
    };

    try {
      for await (const event of this.transport.understand(request, this.abort.signal)) {
        this.patchTurn(turnId, (t) => reduceTurn(t, event, performance.now()));
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      const message = (error as Error).message || "The turn could not be understood.";
      this.patchTurn(turnId, (t) => reduceTurn(t, { type: "turn.failed", at: Date.now(), message }, performance.now()));
    }

    const finished = this.state.turns.find((t) => t.turnId === turnId)!;
    if (finished.failed || !finished.decision) {
      this.note(finished.failed ?? "The server stopped before it decided anything.", "error");
      this.set({ busy: false, failedTries: this.state.failedTries + 1 });
      return;
    }
    if (!input.realtimeText && this.isEcho(heardText(finished))) {
      this.note("Ignored a turn that sounded like the assistant's own voice.", "error");
      this.set({ busy: false });
      return;
    }
    // When it is sure, show what it understood; when it is asking, show what was actually heard.
    const sure = finished.decision.decision.kind === "act";
    const heard = sure ? bestText(finished) : heardText(finished);
    if (heard) this.say("you", heard);
    await this.follow(finished);
    this.set({ busy: false });
  }

  /** Follows the decision: act, ask, or say it cannot hear. */
  private async follow(turn: TurnModel) {
    const outcome = resolveDecision(turn, this.state.pending, this.state.entries);
    if (outcome.learned) await this.learn(outcome.learned.entries, outcome.learned.changed, outcome.learned.clip);
    this.set({ failedTries: outcome.resetTries ? 0 : this.state.failedTries + (outcome.failed ? 1 : 0) });
    if (outcome.phone) this.set({ phone: outcome.phone(this.state.phone) });
    if (outcome.pending && outcome.say) await this.askPending(outcome.pending, outcome.say, outcome.tone);
    else {
      this.set({ pending: outcome.pending });
      if (outcome.say) await this.assistant(outcome.say, outcome.tone);
    }
    if (outcome.actOn) await this.act(outcome.actOn, outcome.actSubject);
  }

  private async act(text: string, subject?: TurnModel) {
    let response: ActResponse;
    try {
      response = await this.transport.act({ text, recentTurns: this.recent.slice(-6) });
    } catch (error) {
      await this.assistant((error as Error).message, "error");
      return;
    }
    const outcome = afterAct(response, this.state.phone, text, subject);
    this.set({ phone: outcome.phone });
    if (outcome.pending) await this.askPending(outcome.pending, outcome.say, outcome.tone);
    else {
      this.set({ pending: undefined });
      await this.assistant(outcome.say, outcome.tone);
    }
  }

  /**
   * Sets the question as waiting, speaks it, and stamps when it finished playing (or was cut
   * off). Only speech that starts after that stamp can answer it.
   */
  private async askPending(pending: Pending, say: string, tone: ChatLine["tone"] = "question") {
    const waiting: Pending = { ...pending, createdAt: pending.createdAt ?? Date.now(), askedAt: undefined };
    this.set({ pending: waiting });
    await this.assistant(say, tone);
    if (this.state.pending === waiting) this.set({ pending: { ...waiting, askedAt: performance.now() } });
  }

  private dropPending(why: string) {
    const pending = this.state.pending;
    this.set({ pending: undefined, phone: pending?.kind === "action" ? phoneCancel(this.state.phone) : this.state.phone });
    this.note(why, "error");
  }

  private isEcho(text: string | undefined): boolean {
    if (!text || words(this.lastSpoken).length < 2) return false;
    return similarity(text, this.lastSpoken) >= ECHO_SIMILARITY;
  }

  private async learn(entries: PhrasebookEntry[], changed: PhrasebookEntry[], clip?: { turnId: string; text: string; difficulty: number }) {
    this.set({ entries, justLearned: changed.map((e) => e.id) });
    for (const entry of changed) this.note(`Learned: "${entry.heard}" means "${entry.meant}"`, "learned");
    await this.store.saveEntries(entries);
    const wav = clip && this.wavByTurn.get(clip.turnId);
    if (clip && wav) await this.addClip({ id: `clip-${clip.turnId}`, text: clip.text, wavBase64: wav, createdAt: Date.now(), source: "confirmation", difficulty: clip.difficulty });
  }

  /** Saves a clip of the person's voice for Gemini's examples (enrolment and confirmations). */
  async addClip(clip: Clip) {
    this.clips = [...this.clips.filter((c) => c.id !== clip.id), clip].slice(-40);
    this.set({ clipCount: this.clips.length });
    await this.store.addClip(clip);
  }

  /** Adds entries learned outside a conversation, such as during setup. */
  async addEntries(entries: PhrasebookEntry[], changed: PhrasebookEntry[]) {
    await this.learn(entries, changed);
  }

  async forget(entryId: string) {
    const entries = this.state.entries.filter((e) => e.id !== entryId);
    this.set({ entries });
    await this.store.saveEntries(entries);
  }

  /** Forgets everything about the person: phrasebook, clips, recordings, the conversation. */
  async clearEverything() {
    this.clips = [];
    this.wavByTurn.clear();
    this.recent = [];
    this.lastSpoken = "";
    this.transport.stopSpeaking();
    this.set({ entries: [], clipCount: 0, justLearned: [], turns: [], chat: [], pending: undefined, failedTries: 0, phone: PHONE_HOME });
    await this.store.clearAll();
  }

  private say(who: ChatLine["who"], text: string, tone?: ChatLine["tone"]) {
    this.set({ chat: [...this.state.chat.slice(-30), { id: ++lineId, who, text, tone }] });
    if (who !== "note") this.recent = [...this.recent, `${who === "you" ? "User" : "Assistant"}: ${text}`].slice(-8);
  }

  private note(text: string, tone: ChatLine["tone"]) {
    this.say("note", text, tone);
  }

  private async assistant(text: string, tone?: ChatLine["tone"]) {
    this.say("assistant", text, tone);
    this.lastSpoken = text;
    await this.transport.speak(text);
  }
}
