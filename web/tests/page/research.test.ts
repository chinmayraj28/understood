// The research page: its numbers come from the results file, the tester only ever picks a fair
// clip for the fair test, requests are aborted when the clip changes or the page closes, and the
// page is reached and announced like the others.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { ResearchClip } from "../../shared/research";
import { pickOne } from "../../src/pages/Research";

const source = (path: string) => readFileSync(join(__dirname, "../../src", path), "utf8");
const page = source("pages/Research.tsx");
/** The source without comments, so a comment cannot hide or fake a match. */
const code = page.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

function clip(id: string, extra: Partial<ResearchClip> = {}): ResearchClip {
  return { id, speaker: "M05", kind: "word", prompt: "up", seconds: 1, role: "holdout", seen: false, dysarthric: true, ...extra };
}

describe("the findings come from the data", () => {
  it("never hard-codes a percentage", () => {
    expect(page).not.toMatch(/\d(\.\d+)?\s*(%|per ?cent)/i);
  });

  it("rounds to whole numbers in the heading and one decimal elsewhere", () => {
    expect(code).toMatch(/const whole = \(v: number\) => `\$\{Math\.round\(v \* 100\)\}%`;/);
    expect(code).toMatch(/const oneDecimal = \(v: number\) => `\$\{\(v \* 100\)\.toFixed\(1\)\}%`;/);
    expect(code).toMatch(/Training on the voice cut words wrong from \$\{whole\(lead\.untuned\.wer\)\} to \$\{whole\(lead\.tuned\.wer\)\}/);
    expect(code).toMatch(/row\.key === "unseen"/);
  });

  it("shows a loading and a failed state for the results file", () => {
    expect(code).toMatch(/fetch\("\/research\/results\.json"/);
    expect(code).toMatch(/Loading the results…/);
    expect(code).toMatch(/The results could not be loaded\./);
  });
});

describe("the clip tester", () => {
  it("picks the fair test only from held-out clips whose prompt was never trained on", () => {
    expect(code).toMatch(/c\.role === "holdout" && c\.seen === false && matches\(c\)/);
    expect(code).toMatch(/const clip = pickOne\(fair, picked\?\.clip\);/);
  });

  it("labels a training clip as an unfair test", () => {
    expect(code).toMatch(/c\.role === "train" && matches\(c\)/);
    expect(code).toMatch(/The model trained on this clip, so this is not a fair test\./);
  });

  it("never picks the same clip twice in a row while there is another", () => {
    const clips = [clip("a"), clip("b")];
    for (let i = 0; i < 50; i++) expect(pickOne(clips, clips[0])?.id).toBe("b");
    expect(pickOne([clip("a")], clip("a"))?.id).toBe("a");
    expect(pickOne([], clip("a"))).toBeUndefined();
    const seen = new Set(Array.from({ length: 200 }, () => pickOne([clip("a"), clip("b"), clip("c")])?.id));
    expect(seen).toEqual(new Set(["a", "b", "c"]));
  });

  it("aborts every request: each fetch carries a signal, and each owner aborts it on cleanup", () => {
    const fetches = code.match(/fetch\(/g) ?? [];
    const signalled = code.match(/fetch\([^;]*?signal: controller\.signal/g) ?? [];
    expect(fetches.length).toBeGreaterThanOrEqual(4);
    expect(signalled.length).toBe(fetches.length);
    expect(code).toMatch(/return \(\) => controller\.abort\(\);/);
    expect(code).toMatch(/return \(\) => current\.current\?\.abort\(\);/);
    // The card is remounted for every clip (keyed by its id), and its cleanup aborts the live request.
    expect(code).toMatch(/<ClipCard key=\{picked\.clip\.id\}/);
    expect(code).toMatch(/\(\) => \(\) => \{\s*request\.current\?\.abort\(\);\s*audio\.current\?\.pause\(\);/);
  });

  it("fetches only the results file, the three research routes and the clip audio", () => {
    const urls = [...code.matchAll(/fetch\(\s*("[^"]*"|[^,)]+)/g)].map((m) => m[1]);
    expect(urls.sort()).toEqual(['"/api/research/clips"', '"/api/research/status"', '"/api/research/transcribe"', '"/research/results.json"'].sort());
    expect(code).toMatch(/new Audio\(clipAudioUrl\(clip\.id\)\)/);
  });

  it("shows the exact start command when the live model is not running, and re-checks after a failure", () => {
    expect(code).toMatch(/const START_COMMAND = "cd train && uv run python serve\.py";/);
    expect(code).toMatch(/<code>\{START_COMMAND\}<\/code>/);
    expect(code).toMatch(/disabled=\{!isLive \|\| live\.state === "busy"\}/);
    const failures = code.match(/setLive\(\{ state: "failed", message[^}]*\}\);\s*onRecheck\(\);/g) ?? [];
    expect(failures.length).toBe(2);
  });

  it("says once, quietly, that the tester is local only when the routes are missing", () => {
    expect(code).toMatch(/r\.status === 403 \|\| r\.status === 404 \|\| \(r\.ok && !json\)/);
    expect(code).toMatch(/The tester runs only on the owner’s computer, because the TORGO recordings may not be redistributed\./);
  });

  it("keeps nothing between visits", () => {
    expect(code).not.toMatch(/localStorage|sessionStorage|indexedDB/);
  });
});

describe("accessibility", () => {
  it("has one h1, focusable for page changes, and the app focuses it", () => {
    expect(code.match(/<h1/g)).toHaveLength(1);
    expect(code).toMatch(/<h1 id="research-title" tabIndex=\{-1\}>/);
    expect(source("App.tsx")).toMatch(/route\.page === "research" \? "research-title"/);
  });

  it("speaks politely, never assertively", () => {
    expect(page).not.toMatch(/aria-live="assertive"/);
    expect(code).toMatch(/className="clip-live-result" aria-live="polite"/);
  });

  it("uses real buttons and does not rely on colour alone for the numbers", () => {
    expect(code).not.toMatch(/<(div|span)[^>]*onClick/);
    expect(code).toMatch(/<span className="pair-value num">\{oneDecimal\(row\.untuned\.wer\)\}<\/span>/);
    expect(code).toMatch(/<span className="pair-value num">\{oneDecimal\(row\.tuned\.wer\)\}<\/span>/);
  });

  it("is linked from the header after Recordings", () => {
    const chrome = source("components/SiteChrome.tsx");
    expect(chrome.indexOf("Research")).toBeGreaterThan(chrome.indexOf("Recordings"));
    expect(chrome).toMatch(/href=\{href\.research\} aria-current=\{page === "research" \? "page" : undefined\}/);
  });

  it("styles are loaded and motion is left to the shared reduced-motion rule", () => {
    expect(source("main.tsx")).toMatch(/import "\.\/styles\/research\.css";/);
    expect(source("styles/research.css")).not.toMatch(/animation|transition/);
  });
});
