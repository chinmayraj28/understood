// Hearing a recording: a TORGO speaker's voice is set up from their own enrolment clips (never a
// test clip), and a recording is transcribed through the pipeline without acting, asking,
// speaking or learning.
import { describe, expect, it } from "vitest";
import type { DatasetClip, DatasetIndex } from "../../shared/dataset";
import type { ActRequest, ActResponse, PipelineEvent, UnderstandRequest } from "../../shared/pipeline";
import { Conversation } from "../../src/model/conversation";
import type { Transport } from "../../src/model/transport";
import { keytermsFrom, NOBODY, setUpSpeaker, setupClipsFor, SETUP_CLIP_LIMIT } from "../../src/model/voices";
import { MemoryStore } from "../../src/storage/store";

function clip(id: string, prompt: string, split: "enrolment" | "test", repeatedLater = false, speaker = "F03"): DatasetClip {
  return { id, speaker, kind: prompt.includes(" ") ? "sentence" : "word", prompt, seconds: 1, session: "Session1", split, ...(repeatedLater ? { repeatedLater } : {}) };
}

function index(clips: DatasetClip[]): DatasetIndex {
  return { available: true, name: "TORGO", speakers: [{ id: "F03", group: "dysarthric", condition: "cerebral palsy", severity: "moderate", clipCount: clips.length }], clips, results: {} };
}

/** A server stand-in: each recogniser's text per clip, and every request it was sent. */
function fakeServer(heardBy: (request: UnderstandRequest) => { scribe: string; gemini: string }) {
  const requests: UnderstandRequest[] = [];
  async function* understand(request: UnderstandRequest): AsyncGenerator<PipelineEvent> {
    requests.push(request);
    const heard = heardBy(request);
    const at = Date.now();
    yield { type: "turn.started", turnId: request.turnId, at, keyterms: request.keyterms, exampleCount: request.examples.length };
    yield { type: "hear.done", hearer: "scribe", at, text: heard.scribe, seconds: 0.5 };
    yield { type: "hear.done", hearer: "gemini", at, text: heard.gemini, seconds: 1.5 };
    yield { type: "agreement", at, contentWords: {}, agreeing: [], disputedWords: [] };
    yield { type: "phrasebook", at, match: null };
    yield { type: "repair.done", at, reading: { text: heard.gemini, confidence: "medium", alternatives: [], reason: "" }, seconds: 1 };
    yield { type: "decision", at, decision: { kind: "confirm", question: `${heard.gemini}?`, reading: heard.gemini }, rule: "test" };
    yield { type: "turn.done", at, seconds: 3 };
  }
  return { understand, requests };
}

describe("setting up a TORGO speaker's voice", () => {
  it("uses only enrolment clips, prompts said again later first, at most 20", () => {
    const clips = [
      clip("a", "air", "enrolment"),
      clip("t", "air", "test"),
      clip("b", "up", "enrolment", true),
      ...Array.from({ length: 30 }, (_, i) => clip(`e${i}`, `word${i}`, "enrolment")),
    ];
    const chosen = setupClipsFor(index(clips), "F03");
    expect(chosen).toHaveLength(SETUP_CLIP_LIMIT);
    expect(chosen[0].id).toBe("b");
    expect(chosen[1].id).toBe("a");
    expect(chosen.some((c) => c.split === "test")).toBe(false);
  });

  it("gives Scribe the distinct prompts, most frequent first", () => {
    expect(keytermsFrom(["up", "Air", "up.", "down"])).toEqual(["up", "Air", "down"]);
  });

  it("learns heard -> meant from each recogniser that misheard, and keeps five clips for Gemini", async () => {
    const clips = [clip("a", "stubble", "enrolment"), clip("b", "sip", "enrolment"), clip("c", "air", "enrolment"), clip("d", "up", "enrolment"), clip("e", "feet", "enrolment"), clip("f", "beat", "enrolment"), clip("t", "chair", "test")];
    const misheard: Record<string, { scribe: string; gemini: string }> = {
      "setup-a": { scribe: "Stabber", gemini: "stubble" },
      "setup-b": { scribe: "sip", gemini: "sip" },
    };
    const server = fakeServer((r) => misheard[r.turnId] ?? { scribe: "uh", gemini: "uh" });
    const progress: number[] = [];
    const voice = await setUpSpeaker(index(clips), "F03", "F03 (cerebral palsy, moderate)", {
      understand: server.understand,
      loadWav: async (c) => `wav-${c.id}`,
      onProgress: (p) => progress.push(p.done),
    });
    expect(voice.id).toBe("torgo:F03");
    expect(voice.setupClipIds).toEqual(["a", "b", "c", "d", "e", "f"]);
    expect(voice.setupClipIds).not.toContain("t");
    expect(voice.examples).toHaveLength(5);
    expect(voice.keyterms).toContain("stubble");
    expect(voice.phrasebook.some((e) => e.heard === "Stabber" && e.meant === "stubble" && e.hearer === "scribe")).toBe(true);
    // Heard right: nothing to learn.
    expect(voice.phrasebook.some((e) => e.meant === "sip")).toBe(false);
    expect(progress.at(-1)).toBe(6);
    // Setup asks for hearing only, as a transcription.
    for (const r of server.requests) {
      expect(r.purpose).toBe("transcribe");
      expect(r.switches.repair).toBe(false);
      expect(r.phrasebook).toEqual([]);
    }
  });

  it("does not learn phrases longer than the server accepts", async () => {
    const long = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone";
    const server = fakeServer(() => ({ scribe: "something else", gemini: "something else" }));
    const voice = await setUpSpeaker(index([clip("a", long, "enrolment")]), "F03", "F03", { understand: server.understand, loadWav: async () => "w", onProgress: () => {} });
    expect(voice.phrasebook).toEqual([]);
  });

  it("one clip that cannot be heard does not spoil the setup", async () => {
    const server = fakeServer(() => ({ scribe: "uh", gemini: "up" }));
    const voice = await setUpSpeaker(index([clip("a", "up", "enrolment"), clip("b", "air", "enrolment")]), "F03", "F03", {
      understand: server.understand,
      loadWav: async (c) => {
        if (c.id === "a") throw new Error("unreadable");
        return "w";
      },
      onProgress: () => {},
    });
    expect(voice.examples).toHaveLength(1);
  });
});

class RecordingTransport implements Transport {
  readonly kind = "test";
  acts: ActRequest[] = [];
  spoken: string[] = [];
  onSpeaking: (speaking: boolean) => void = () => {};
  constructor(private server: ReturnType<typeof fakeServer>) {}
  understand(request: UnderstandRequest) {
    return this.server.understand(request);
  }
  async act(request: ActRequest): Promise<ActResponse> {
    this.acts.push(request);
    return { action: { kind: "none" }, reply: "", needsConfirmation: false };
  }
  async speak(text: string) {
    this.spoken.push(text);
  }
  stopSpeaking() {}
}

describe("transcribing a recording", () => {
  it("runs the pipeline with the voice's own phrasebook, clips and hints, and an empty context", async () => {
    const server = fakeServer(() => ({ scribe: "Uh", gemini: "up" }));
    const transport = new RecordingTransport(server);
    const conversation = await Conversation.create(transport, new MemoryStore([]));
    const voice = { ...NOBODY, id: "torgo:M05", label: "M05", keyterms: ["up"], examples: [{ wavBase64: "AAAA", text: "up" }], setupPrompts: ["up"] };
    await conversation.transcribe({ wavBase64: "AAAA", realtimeText: "Uh...", speechSeconds: 2.3, recording: { label: "M05: up", reference: "up", voiceLabel: "M05" }, voice });

    const request = server.requests[0];
    expect(request.purpose).toBe("transcribe");
    expect(request.keyterms).toEqual(["up"]);
    expect(request.examples).toHaveLength(1);
    expect(request.context).toEqual({ recentTurns: [] });
    expect(request.realtimeText).toBe("Uh...");

    const state = conversation.getState();
    const turn = state.turns.at(-1)!;
    expect(turn.origin).toBe("file");
    expect(turn.recording?.reference).toBe("up");
    expect(turn.stage).toBe("done");
    // Nothing acted on, asked, spoken or learned.
    expect(transport.acts).toEqual([]);
    expect(transport.spoken).toEqual([]);
    expect(state.pending).toBeUndefined();
    expect(state.entries).toEqual([]);
    expect(state.chat).toEqual([]);
    expect(state.busy).toBe(false);
  });

  it("with no voice given, uses this browser's own phrasebook", async () => {
    const server = fakeServer(() => ({ scribe: "call some", gemini: "call sam" }));
    const own = [{ id: "e1", heard: "call some", meant: "call Sam", hearer: "scribe" as const, timesConfirmed: 2, lastConfirmedAt: 1, source: "confirmation" as const }];
    const conversation = await Conversation.create(new RecordingTransport(server), new MemoryStore(own));
    await conversation.transcribe({ wavBase64: "AAAA", speechSeconds: 1, recording: { label: "file.wav", voiceLabel: "your voice" } });
    expect(server.requests[0].phrasebook).toEqual(own);
  });

  it("earlier recordings never steer a later one", async () => {
    const server = fakeServer(() => ({ scribe: "hello", gemini: "hello" }));
    const conversation = await Conversation.create(new RecordingTransport(server), new MemoryStore([]));
    for (let i = 0; i < 3; i++) await conversation.transcribe({ wavBase64: "AAAA", speechSeconds: 1, recording: { label: `r${i}`, voiceLabel: "nobody" }, voice: NOBODY });
    expect(server.requests.map((r) => r.context.recentTurns)).toEqual([[], [], []]);
  });
});
