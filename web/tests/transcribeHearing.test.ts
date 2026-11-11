// How a recording is heard: Gemini gets the transcription prompt with the speaker's clips in one
// message, each labelled as a reference, and the new clip last; Scribe v3 without fillers.
import { describe, expect, it } from "vitest";
import { geminiBody, geminiInstruction, geminiTranscribeInstruction, maxTranscribeExamples, scribeForm } from "../server/hearers";
import { claudeBody, thinkingOff } from "../server/claude";
import { repairData, transcribeInstructions } from "../server/repair";

const examples = Array.from({ length: 12 }, (_, i) => ({ wavBase64: `EX${i}`, text: `phrase ${i}` }));
const base = { wavBase64: "NEW", keyterms: [], examples, signal: new AbortController().signal, seconds: 15 };

describe("hearing a recording", () => {
  it("puts the examples in one labelled message with the new clip last", () => {
    const body = geminiBody({ ...base, purpose: "transcribe", model: "google/gemini-3.1-pro-preview" });
    expect(body.model).toBe("google/gemini-3.1-pro-preview");
    const messages = body.messages as { role: string; content: unknown }[];
    expect(messages.map((m) => m.role)).toEqual(["system", "user"]);
    expect(messages[0].content).toBe(geminiTranscribeInstruction);
    const parts = messages[1].content as { type: string; text?: string; input_audio?: { data: string } }[];
    const audio = parts.filter((p) => p.type === "input_audio").map((p) => p.input_audio!.data);
    expect(audio.at(-1)).toBe("NEW");
    expect(audio).toHaveLength(maxTranscribeExamples + 1);
    expect(parts[0].text).toMatch(/^Reference recording 1 of 10\. This person said: "phrase 0"$/);
    expect(parts.at(-2)!.text).toMatch(/new recording, not one of the references/);
  });

  it("keeps the conversation layout and Flash for a spoken turn", () => {
    const body = geminiBody(base);
    expect(body.model).toBe("google/gemini-3.8-flash");
    const messages = body.messages as { role: string }[];
    expect(messages[0]).toMatchObject({ content: geminiInstruction });
    expect(messages.filter((m) => m.role === "assistant")).toHaveLength(5);
  });

  it("the transcription prompt does not frame the speech as phone commands", () => {
    expect(geminiTranscribeInstruction).not.toMatch(/phone|command/i);
    expect(transcribeInstructions).not.toMatch(/phone|command/i);
  });

  it("asks Scribe v3 to leave fillers out", () => {
    const form = scribeForm(base);
    expect(form.get("model_id")).toBe("scribe_v3");
    expect(form.get("no_verbatim")).toBe("true");
  });

  it("shows Claude the speaker's phrases as known phrases for a recording", () => {
    const data = repairData({ hypotheses: [{ hearer: "gemini4", text: "up", seconds: 1 }], phrasebookMatch: null, context: {}, knownWords: ["up", "air"], purpose: "transcribe" });
    expect(data).toContain("<known_phrases><phrase>up</phrase><phrase>air</phrase></known_phrases>");
    expect(data).toContain('<transcript hearer="gemini4">up</transcript>');
  });

  it("turns thinking off the way each Claude model accepts", () => {
    expect(thinkingOff("claude-haiku-5-5")).toEqual({ type: "disabled" });
    expect(thinkingOff("claude-sonnet-5-5")).toEqual({ type: "between_tools" });
    expect(thinkingOff("claude-opus-5-5")).toEqual({ type: "adaptive" });
    expect(claudeBody({ instructions: "x", input: "y", schema: {}, model: "claude-opus-5-5" }).model).toBe("claude-opus-5-5");
  });
});
