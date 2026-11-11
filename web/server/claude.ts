// One structured call to Claude through the Messages API, with fetch.
//
// Why fetch and not the Anthropic SDK: this is one short request shape, the same one the Swift
// AnthropicStructuredModel.swift sends (verified live on 8 Nov 2026), and keeping the server free
// of extra packages keeps it small and runnable on Cloudflare Workers unchanged.
//
// JSON comes back through structured outputs (`output_config.format` with a JSON Schema), so the
// reply always matches the schema. Thinking is off and effort low: this is a latency-sensitive
// call with a 3-second budget, and Haiku 5.5 accepts disabled thinking at low effort.
// (Checked against the claude-api reference on 9 Nov 2026: API version 2026-10-21, which rejects
// temperature, so none is sent.)

import { send, ServiceFailure } from "./http";

export const messagesEndpoint = "https://api.anthropic.com/v1/messages";
export const apiVersion = "2026-10-21";
/** Haiku 5.5: 1.3 to 1.7 s per repair in the 8 Nov measurement, inside the 3-second budget. */
export const claudeModel = "claude-haiku-5-5";
/**
 * For a recording, Opus merges the transcripts: on TORGO dev clips it made the fewest word errors
 * of Haiku, Sonnet and Opus (11.4% against 12.4% and more, docs/TRANSCRIPTION.md). Speed matters
 * less there; a spoken turn keeps Haiku.
 */
export const transcribeRepairModel = "claude-opus-5-5";

export interface StructuredRequest {
  instructions: string;
  input: string;
  schema: Record<string, unknown>;
  signal: AbortSignal;
  seconds: number;
  /** Defaults to claudeModel. */
  model?: string;
}

/**
 * How each model is told not to think first (checked against the API on 11 Nov 2026): Haiku takes
 * "disabled", Sonnet 5.5 "between_tools", and Opus 5.5 only "adaptive" with a low effort.
 */
export function thinkingOff(model: string): Record<string, string> {
  if (model.startsWith("claude-sonnet-5")) return { type: "between_tools" };
  if (model.startsWith("claude-opus-5")) return { type: "adaptive" };
  return { type: "disabled" };
}

/** The request body. Separate so tests can check it against the docs. */
export function claudeBody(request: Pick<StructuredRequest, "instructions" | "input" | "schema" | "model">): Record<string, unknown> {
  return {
    model: request.model ?? claudeModel,
    max_tokens: 1024,
    system: request.instructions,
    messages: [{ role: "user", content: request.input }],
    output_config: { format: { type: "json_schema", schema: request.schema }, effort: "low" },
    thinking: thinkingOff(request.model ?? claudeModel),
  };
}

/** Returns the JSON object Claude wrote, matching `schema`. Throws a ServiceFailure on any failure. */
export async function askClaude(apiKey: string, request: StructuredRequest): Promise<Record<string, unknown>> {
  if (!apiKey) throw new ServiceFailure("There's no Anthropic key, so Claude can't be used.");
  const response = await send(messagesEndpoint, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": apiVersion },
    body: JSON.stringify(claudeBody(request)),
    signal: request.signal,
  }, "Claude", request.seconds);
  return objectFromReply(await response.json().catch(() => null));
}

/** The JSON object inside the first text block of a Messages API reply. */
export function objectFromReply(reply: unknown): Record<string, unknown> {
  const message = reply as { stop_reason?: string; content?: { type?: string; text?: string }[] } | null;
  if (!message || typeof message !== "object") throw new ServiceFailure("Claude sent back something I couldn't read.");
  if (message.stop_reason === "refusal") throw new ServiceFailure("Claude declined to answer that.");
  if (message.stop_reason === "max_tokens") throw new ServiceFailure("Claude's answer was cut off.");
  const text = message.content?.find((block) => block.type === "text")?.text ?? "";
  try {
    const parsed = JSON.parse(text) as unknown;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
  } catch {
    // fall through
  }
  throw new ServiceFailure("Claude's answer was not in the expected form.");
}
