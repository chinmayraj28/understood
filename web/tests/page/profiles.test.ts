// Profiles: names are tidied and never clash, the first profile keeps the old database, and a
// deleted profile is never heard as.
import { describe, expect, it } from "vitest";
import { voiceStillThere } from "../../src/components/VoiceSelect";
import { abandonedDrafts, cleanProfileName, databaseName, FIRST_PROFILE, freeProfileName, loadActiveProfile, loadProfiles, MIN_SETUP_PHRASES } from "../../src/storage/profiles";

describe("profiles", () => {
  it("always has at least one profile, which keeps the database used before profiles", () => {
    expect(loadProfiles()).toEqual([FIRST_PROFILE]);
    expect(databaseName(FIRST_PROFILE.id)).toBe("understood");
    expect(databaseName("abc")).toBe("understood-profile-abc");
  });

  it("falls back to the first profile when the saved one is gone", () => {
    expect(loadActiveProfile([FIRST_PROFILE])).toBe(FIRST_PROFILE.id);
  });

  it("tidies names and never gives two profiles the same one", () => {
    expect(cleanProfileName("  Sam   Jones  ")).toBe("Sam Jones");
    expect(cleanProfileName("x".repeat(80))).toHaveLength(40);
    const list = [FIRST_PROFILE, { id: "b", name: "Sam", createdAt: 1 }];
    expect(freeProfileName(list, "sam")).toBe("sam 2");
    expect(freeProfileName(list, "Priya")).toBe("Priya");
  });

  it("a chosen profile that was deleted falls back, and a TORGO speaker stays", () => {
    const list = [FIRST_PROFILE];
    expect(voiceStillThere("profile:gone", list, "profile:default")).toBe("profile:default");
    expect(voiceStillThere("profile:default", list, "speaker")).toBe("profile:default");
    expect(voiceStillThere("torgo:F03", list, "profile:default")).toBe("torgo:F03");
    expect(voiceStillThere(null, list, "speaker")).toBe("speaker");
  });

  it("a profile being made is not kept unless finished, and needs three phrases to be saved", async () => {
    const saved = [FIRST_PROFILE, { id: "d1", name: "Half made", createdAt: 1, draft: true }];
    const store = new Map<string, string>([["understood.profiles", JSON.stringify(saved)], ["understood.activeProfile", JSON.stringify("d1")]]);
    const { vi } = await import("vitest");
    vi.stubGlobal("localStorage", { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v) });
    try {
      expect(loadProfiles()).toEqual([FIRST_PROFILE]);
      expect(abandonedDrafts().map((p) => p.id)).toEqual(["d1"]);
      expect(loadActiveProfile(loadProfiles())).toBe(FIRST_PROFILE.id);
    } finally {
      vi.unstubAllGlobals();
    }
    expect(MIN_SETUP_PHRASES).toBe(3);
    const { readFileSync } = await import("node:fs");
    const page = readFileSync(new URL("../../src/pages/ProfilesPage.tsx", import.meta.url), "utf8");
    expect(page).toMatch(/disabled=\{!enough\} onClick=\{finish\}/);
  });

  it("offers no 'Nobody in particular' anywhere", async () => {
    const { readFileSync } = await import("node:fs");
    for (const file of ["components/HearRecording.tsx", "components/VoiceSelect.tsx", "model/voices.ts", "useSession.ts"]) {
      expect(readFileSync(new URL(`../../src/${file}`, import.meta.url), "utf8")).not.toMatch(/Nobody in particular|"nobody"/);
    }
  });
});
