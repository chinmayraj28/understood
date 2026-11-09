// Review findings 13, 14 and 15 and test gaps e and g: retrying the microphone, the phone's
// sentence, one announcement per turn, and no forced smooth scrolling.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Listener } from "../../src/audio/listener";
import { PHONE_HOME, phoneAsk, phoneDescription, phonePerform } from "../../src/model/phone";

const source = (path: string) => readFileSync(join(__dirname, "../../src", path), "utf8");

afterEach(() => vi.unstubAllGlobals());

describe("e) The microphone can be tried again after a failed start", () => {
  it("stops the tracks when the audio code fails, then starts on the second try", async () => {
    const tracks: { stop: ReturnType<typeof vi.fn> }[] = [];
    let failLoad = true;
    vi.stubGlobal("navigator", {
      mediaDevices: {
        getUserMedia: async () => {
          const track = { stop: vi.fn() };
          tracks.push(track);
          return { getTracks: () => [track] };
        },
      },
    });
    vi.stubGlobal(
      "AudioContext",
      class {
        state = "running";
        audioWorklet = { addModule: async () => (failLoad ? Promise.reject(new Error("404")) : undefined) };
        close = async () => {};
        resume = async () => {};
        createMediaStreamSource() {
          return { connect: () => {} };
        }
      },
    );
    vi.stubGlobal(
      "AudioWorkletNode",
      class {
        port = { onmessage: null };
        disconnect() {}
      },
    );
    const listener = new Listener();
    await expect(listener.start({ liveTranscript: false })).rejects.toThrow();
    expect(tracks[0].stop).toHaveBeenCalled();
    expect(listener.isOn).toBe(false);
    failLoad = false;
    await listener.start({ liveTranscript: false });
    expect(listener.isOn).toBe(true);
    listener.stop();
  });
});

describe("g) The phone's sentence changes with the screen, not the clock", () => {
  it("describes each screen from state alone", () => {
    const timer = phonePerform(PHONE_HOME, { kind: "timer", minutes: 2 }, 1_000);
    expect(phoneDescription(timer)).toBe("Timer set for 2 minutes.");
    // The same state a minute later reads the same: nothing ticks.
    expect(phoneDescription({ ...timer })).toBe(phoneDescription(timer));
    expect(phoneDescription(phoneAsk(PHONE_HOME, { kind: "message", to: "Mum", text: "running late" }, "Send 'running late' to Mum?"))).toBe(
      "Waiting for your yes: Send 'running late' to Mum?",
    );
    expect(phoneDescription(phonePerform(PHONE_HOME, { kind: "message", to: "Mum", text: "running late" }))).toBe("Sent to Mum: running late");
  });

  it("the phone is not a live region, and its ticking screen is hidden from screen readers", () => {
    const phone = source("components/Phone.tsx");
    expect(phone).not.toMatch(/aria-live/);
    expect(phone).toMatch(/className="phone-screen" aria-hidden="true"/);
    expect(phone).toMatch(/phoneDescription\(phone\)/);
  });
});

describe("14) One announcement per turn", () => {
  it("the conversation log is the turn's live region; agreement and verdict are plain text", () => {
    expect(source("components/SidePanels.tsx")).toMatch(/aria-live="polite"/);
    expect(source("components/HearStation.tsx")).not.toMatch(/role="(status|alert)"|aria-live/);
    expect(source("components/DecisionStation.tsx")).not.toMatch(/role="(status|alert)"|aria-live/);
  });

  it("the page-level region is polite and only speaks failures", () => {
    const app = source("App.tsx");
    expect(app).not.toMatch(/aria-live="assertive"/);
    expect(app).toMatch(/turn\.failed \? `The turn failed/);
  });
});

describe("15) Smooth scrolling respects reduced motion", () => {
  it("every smooth scroll in the code checks the setting first", () => {
    const app = source("App.tsx");
    for (const line of app.split("\n").filter((l) => /behavior:/.test(l))) {
      expect(line).toMatch(/still \? "auto" : "smooth"/);
    }
    expect(app).toMatch(/prefers-reduced-motion: reduce/);
  });
});
