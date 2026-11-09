// What every outside call shares: one way to send a request with a time limit and turn a failed
// reply into a short sentence the page can show. Uses only fetch and Web APIs, so it runs on
// Node and on Cloudflare Workers alike. Never logs a request body: it holds the person's voice.

/** A failure explained in plain words ("ElevenLabs took too long to answer."). */
export class ServiceFailure extends Error {}

/** A signal that fires when `parent` does or after `ms`, whichever comes first. */
export function withTimeLimit(ms: number, parent?: AbortSignal): AbortSignal {
  const timer = AbortSignal.timeout(ms);
  return parent ? AbortSignal.any([parent, timer]) : timer;
}

/**
 * Sends the request and returns a successful (2xx) reply. Any other reply, or no reply, becomes a
 * `ServiceFailure` naming the service. `seconds` is only used to word a time-out.
 */
export async function send(url: string, init: RequestInit, service: string, seconds: number): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(url, init);
  } catch (error) {
    const name = (error as { name?: string })?.name;
    if (name === "TimeoutError" || (name === "AbortError" && init.signal?.reason?.name === "TimeoutError")) {
      throw new ServiceFailure(`timed out after ${seconds} s`);
    }
    if (name === "AbortError") throw new ServiceFailure("cancelled");
    throw new ServiceFailure(`I couldn't reach ${service}. The internet may be down.`);
  }
  if (!response.ok) {
    // Read and drop the body so the connection is freed; it is service text, kept private anyway.
    await response.text().catch(() => "");
    throw failureFor(response.status, service);
  }
  return response;
}

/** The plain sentence for an HTTP status. */
export function failureFor(status: number, service: string): ServiceFailure {
  if (status === 401 || status === 403) return new ServiceFailure(`${service} didn't accept the key.`);
  if (status === 402) return new ServiceFailure(`The ${service} account has run out of credit.`);
  if (status === 408 || status === 504) return new ServiceFailure(`${service} took too long to answer.`);
  if (status === 413) return new ServiceFailure(`That recording was too long for ${service}.`);
  if (status === 400 || status === 422) return new ServiceFailure(`${service} couldn't use that request.`);
  if (status === 429) return new ServiceFailure(`${service} is busy right now.`);
  if (status >= 500 && status <= 599) return new ServiceFailure(`${service} had a problem on its side.`);
  return new ServiceFailure(`${service} gave an answer I didn't expect.`);
}

/** The message to show for any error: a ServiceFailure's own words, otherwise a generic line. */
export function plainMessage(error: unknown, service: string): string {
  if (error instanceof ServiceFailure) return error.message;
  const name = (error as { name?: string })?.name;
  if (name === "TimeoutError") return "timed out";
  return `${service} gave an answer I didn't expect.`;
}

/** Decodes base64 to bytes with Web APIs only (no Node Buffer), so it also runs on Workers. */
export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

/** How many bytes a base64 string decodes to, without decoding it. */
export function decodedLength(base64: string): number {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}
