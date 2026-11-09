// Review finding 9: starting the microphone can fail or be overtaken by Stop. Either way the
// microphone must end up closed and the page must say it is not listening.
import { afterEach, describe, expect, it, vi } from "vitest";
import { Listener } from "../../src/audio/listener";

function fakeBrowser(options: { addModule?: () => Promise<void>; getUserMedia?: () => Promise<unknown> } = {}) {
  const track = { stop: vi.fn() };
  const stream = { getTracks: () => [track] };
  const contexts: { close: ReturnType<typeof vi.fn> }[] = [];
  const nodes: unknown[] = [];
  class FakeAudioContext {
    state = "running";
    close = vi.fn(async () => {});
    audioWorklet = { addModule: options.addModule ?? (async () => {}) };
    constructor() {
      contexts.push(this);
    }
    createMediaStreamSource() {
      return { connect: () => {} };
    }
    resume = async () => {};
  }
  class FakeNode {
    port = { onmessage: null };
    constructor() {
      nodes.push(this);
    }
    disconnect() {}
  }
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia: options.getUserMedia ?? (async () => stream) } });
  vi.stubGlobal("AudioContext", FakeAudioContext);
  vi.stubGlobal("AudioWorkletNode", FakeNode);
  return { track, stream, contexts, nodes };
}

afterEach(() => vi.unstubAllGlobals());

describe("Starting the microphone safely", () => {
  it("closes the microphone and says why when the audio code fails to load", async () => {
    const browser = fakeBrowser({ addModule: () => Promise.reject(new Error("404")) });
    const listener = new Listener();
    const statuses: string[] = [];
    listener.onTick = (tick) => statuses.push(tick.status);
    await expect(listener.start({ liveTranscript: false })).rejects.toThrow(/could not start listening/);
    expect(browser.track.stop).toHaveBeenCalled();
    expect(browser.contexts[0].close).toHaveBeenCalled();
    expect(listener.isOn).toBe(false);
    expect(statuses.at(-1)).toBe("off");
  });

  it("does not open the microphone when Stop is pressed while the browser is still asking", async () => {
    let grant: (value: unknown) => void = () => {};
    const browser = fakeBrowser({ getUserMedia: () => new Promise((resolve) => (grant = resolve)) });
    const listener = new Listener();
    const starting = listener.start({ liveTranscript: false });
    listener.stop();
    grant(browser.stream);
    await starting;
    expect(browser.track.stop).toHaveBeenCalled();
    expect(browser.contexts).toHaveLength(0);
    expect(listener.isOn).toBe(false);
  });

  it("closes everything when Stop is pressed while the audio code is loading", async () => {
    let loaded: () => void = () => {};
    const browser = fakeBrowser({ addModule: () => new Promise<void>((resolve) => (loaded = resolve)) });
    const listener = new Listener();
    const starting = listener.start({ liveTranscript: false });
    await vi.waitFor(() => expect(browser.contexts).toHaveLength(1));
    listener.stop();
    loaded();
    await starting;
    expect(browser.track.stop).toHaveBeenCalled();
    expect(browser.contexts[0].close).toHaveBeenCalled();
    expect(browser.nodes).toHaveLength(0);
    expect(listener.isOn).toBe(false);
  });

  it("starts normally when nothing goes wrong", async () => {
    const browser = fakeBrowser();
    const listener = new Listener();
    await listener.start({ liveTranscript: false });
    expect(listener.isOn).toBe(true);
    expect(browser.nodes).toHaveLength(1);
    listener.stop();
    expect(browser.track.stop).toHaveBeenCalled();
  });
});
