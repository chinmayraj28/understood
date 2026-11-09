// Review finding 10: stopping the live transcript while its token is on the way must not leave
// a socket open, and a working session resets the reconnect count.
import { afterEach, describe, expect, it, vi } from "vitest";
import { ScribeLiveTranscriber } from "../../src/audio/liveTranscript";

class FakeSocket {
  static made: FakeSocket[] = [];
  static OPEN = 1;
  readyState = 0;
  sent: string[] = [];
  closed = false;
  onopen: () => void = () => {};
  onerror: () => void = () => {};
  onclose: () => void = () => {};
  onmessage: (event: { data: string }) => void = () => {};
  constructor(public url: string) {
    FakeSocket.made.push(this);
  }
  open() {
    this.readyState = FakeSocket.OPEN;
    this.onopen();
  }
  send(data: string) {
    this.sent.push(data);
  }
  close() {
    this.closed = true;
  }
}

function tokenThatArrivesLater() {
  let deliver: () => void = () => {};
  vi.stubGlobal(
    "fetch",
    vi.fn(
      () =>
        new Promise((resolve) => {
          deliver = () => resolve(new Response(JSON.stringify({ token: "single-use" }), { status: 200 }));
        }),
    ),
  );
  return () => deliver();
}

afterEach(() => {
  vi.unstubAllGlobals();
  FakeSocket.made = [];
});

describe("Live transcript start and stop", () => {
  it("opens no socket when stopped while the token is on its way", async () => {
    vi.stubGlobal("WebSocket", FakeSocket);
    const deliver = tokenThatArrivesLater();
    const transcriber = new ScribeLiveTranscriber();
    const starting = transcriber.start();
    transcriber.stop();
    deliver();
    await starting;
    expect(FakeSocket.made).toHaveLength(0);
  });

  it("closes the socket when stopped while it is connecting, without reporting an error", async () => {
    vi.stubGlobal("WebSocket", FakeSocket);
    const deliver = tokenThatArrivesLater();
    const transcriber = new ScribeLiveTranscriber();
    const errors: string[] = [];
    transcriber.onError = (message) => errors.push(message);
    const starting = transcriber.start();
    deliver();
    await vi.waitFor(() => expect(FakeSocket.made).toHaveLength(1));
    transcriber.stop();
    FakeSocket.made[0].open();
    await starting;
    expect(FakeSocket.made[0].closed).toBe(true);
    expect(errors).toEqual([]);
  });

  it("uses the token once, puts no keyterms on the live transcript, and resets reconnects on a working session", async () => {
    vi.stubGlobal("WebSocket", FakeSocket);
    const deliver = tokenThatArrivesLater();
    const transcriber = new ScribeLiveTranscriber();
    const starting = transcriber.start();
    deliver();
    await vi.waitFor(() => expect(FakeSocket.made).toHaveLength(1));
    const socket = FakeSocket.made[0];
    socket.open();
    await starting;
    const url = new URL(socket.url);
    expect(url.searchParams.get("token")).toBe("single-use");
    expect(url.searchParams.get("commit_strategy")).toBe("manual");
    expect(url.searchParams.getAll("keyterms")).toEqual([]);

    (transcriber as unknown as { reconnects: number }).reconnects = 2;
    socket.onmessage({ data: JSON.stringify({ message_type: "session_started" }) });
    expect((transcriber as unknown as { reconnects: number }).reconnects).toBe(0);
    transcriber.stop();
  });

  it("treats any unknown message type as an error, but not a quiet moment", async () => {
    vi.stubGlobal("WebSocket", FakeSocket);
    const deliver = tokenThatArrivesLater();
    const transcriber = new ScribeLiveTranscriber();
    const errors: string[] = [];
    transcriber.onError = (message) => errors.push(message);
    const starting = transcriber.start();
    deliver();
    await vi.waitFor(() => expect(FakeSocket.made).toHaveLength(1));
    FakeSocket.made[0].open();
    await starting;
    FakeSocket.made[0].onmessage({ data: JSON.stringify({ message_type: "insufficient_audio_activity" }) });
    FakeSocket.made[0].onmessage({ data: JSON.stringify({ message_type: "quota_exceeded" }) });
    expect(errors).toHaveLength(1);
    expect(errors[0]).toMatch(/quota exceeded/);
    transcriber.stop();
  });
});
