// The research page: it leads with the leave-one-speaker-out test and falls back to the earlier
// test when the results file has none, its numbers come from the results file, the tester only
// ever picks a fair clip for the fair test, requests are aborted when the clip changes or the
// page closes, and the page is reached and announced like the others.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ResearchClip, ResearchResults } from "../../shared/research";
import { pickOne, ResearchView } from "../../src/pages/Research";

const source = (path: string) => readFileSync(join(__dirname, "../../src", path), "utf8");
const page = source("pages/Research.tsx");
/** The source without comments, so a comment cannot hide or fake a match. */
const code = page.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

/** The published results file, as the hosted site serves it. */
const results = JSON.parse(readFileSync(join(__dirname, "../../public/research/results.json"), "utf8")) as ResearchResults;

const render = (r: ResearchResults | null | "failed") => renderToStaticMarkup(createElement(ResearchView, { results: r }));
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/&#x27;|&rsquo;/g, "’").replace(/\s+/g, " ");
/** The body rows of the table labelled by a heading id, each as its plain text. */
function tableRows(html: string, titleId: string): string[] {
  const table = html.match(new RegExp(`<table[^>]*aria-labelledby="${titleId}"[\\s\\S]*?</table>`))?.[0] ?? "";
  const body = table.match(/<tbody>([\s\S]*?)<\/tbody>/)?.[1] ?? "";
  return [...body.matchAll(/<tr>([\s\S]*?)<\/tr>/g)].map((m) => text(m[1]).trim());
}
/** Section headings in page order. */
const headings = (html: string) => [...html.matchAll(/<h([12])[^>]*>([\s\S]*?)<\/h\1>/g)].map((m) => `h${m[1]} ${text(m[2]).trim()}`);

function clip(id: string, extra: Partial<ResearchClip> = {}): ResearchClip {
  return { id, speaker: "M05", kind: "word", prompt: "up", seconds: 1, role: "holdout", seen: false, dysarthric: true, ...extra };
}

describe("the results file", () => {
  it("has the leave-one-speaker-out test beside the earlier one", () => {
    expect(results.loso?.model).toBe("openai/whisper-large-v3-turbo");
    expect(results.loso?.speakers).toBe(8);
    expect(results.loso?.rows.map((r) => r.key)).toEqual(["all", "new-prompt", "sentence", "word", "new-prompt-sentence", "new-prompt-word"]);
    expect(results.loso?.perSpeaker).toHaveLength(8);
    for (const row of results.loso?.rows ?? []) {
      for (const rate of [row.untuned, row.tuned]) {
        expect(rate.low).toBeLessThanOrEqual(rate.wer);
        expect(rate.wer).toBeLessThanOrEqual(rate.high);
      }
    }
    // The earlier test's rows are still there for its table.
    expect(results.heldOut.map((r) => r.key)).toEqual(expect.arrayContaining(["unseen", "dysarthric-unseen", "unseen-sentence", "unseen-word"]));
  });
});

describe("the page with the leave-one-speaker-out test", () => {
  const html = render(results);

  it("builds the headline from the test on a person the model never heard", () => {
    expect(html).toMatch(/<h1 id="research-title" tabindex="-1">On a person it never heard, training cut words wrong from 46% to 31%<\/h1>/);
    expect(text(html)).toMatch(/Whisper large-v3-turbo, trained on everyone else and tested on one speaker it had never heard, for each of eight speakers/);
  });

  it("shows the sections in order", () => {
    expect(headings(html)).toEqual([
      "h1 On a person it never heard, training cut words wrong from 46% to 31%",
      "h2 The result",
      "h2 Speaker by speaker",
      "h2 How it was tested",
      "h2 Try a clip it never trained on",
      "h2 When the model has heard the speaker",
      "h2 What this does not show",
    ]);
  });

  it("puts the four main rows in order, untuned then trained, with their ranges", () => {
    const rows = tableRows(html, "result-title");
    expect(rows.map((r) => r.split(/ \d/)[0])).toEqual(["All clips", "New voice and new words", "Sentences", "Single words"]);
    expect(rows[0]).toMatch(/^All clips 940 clips 940 46\.4% likely between 42\.0 – and 50\.9 31\.4% likely between 28\.1 – and 34\.8$/);
    expect(rows[1]).toMatch(/40\.8% .* 33\.7%/);
  });

  it("has eight speaker rows, sorted by speaker, in whole percents", () => {
    const rows = tableRows(html, "speakers-title");
    expect(rows).toEqual(["F01 81% 44%", "F03 36% 28%", "F04 14% 8%", "M01 63% 46%", "M02 86% 75%", "M03 5% 2%", "M04 89% 55%", "M05 41% 20%"]);
  });

  it("keeps the earlier test as a smaller table", () => {
    const rows = tableRows(html, "earlier-title");
    expect(rows.map((r) => r.split(/ \d/)[0])).toEqual(["All speakers", "Speakers with dysarthria", "Sentences", "Single words"]);
    expect(rows[0]).toMatch(/35\.6% 24\.6%$/);
  });

  it("says what it does not show, with the smaller gain on new words from the data", () => {
    const limits = text(html.match(/<ul class="limits">[\s\S]*?<\/ul>/)?.[0] ?? "");
    expect(limits).toMatch(/Eight speakers is far too few/);
    expect(limits).toMatch(/the gain is smaller: from 41% to 34%\./);
    expect(limits).toMatch(/not everyday conversation/);
  });

  it("uses real table headers", () => {
    expect(html.match(/<th scope="col"/g)?.length).toBe(4 + 3 + 4);
    expect(html.match(/<th scope="row"/g)?.length).toBe(4 + 8 + 4);
  });
});

describe("an older results file without the test", () => {
  const { loso: _gone, ...older } = results;
  const html = render(older);

  it("falls back to the earlier headline and leaves out the new tables", () => {
    expect(html).toMatch(/<h1 id="research-title" tabindex="-1">Training on the voice cut words wrong from 36% to 25%<\/h1>/);
    expect(tableRows(html, "result-title")).toEqual([]);
    expect(tableRows(html, "speakers-title")).toEqual([]);
    expect(headings(html)).toEqual([
      "h1 Training on the voice cut words wrong from 36% to 25%",
      "h2 Try a clip it never trained on",
      "h2 When the model has heard the speaker",
      "h2 What this does not show",
    ]);
    expect(text(html)).not.toMatch(/the gain is smaller/);
  });

  it("shows a loading and a failed state for the results file", () => {
    expect(code).toMatch(/fetch\("\/research\/results\.json"/);
    expect(render(null)).toMatch(/Loading the results…/);
    expect(render("failed")).toMatch(/The results could not be loaded\./);
  });
});

describe("the findings come from the data", () => {
  it("never hard-codes a percentage", () => {
    expect(page).not.toMatch(/\d(\.\d+)?\s*(%|per ?cent)/i);
  });

  it("rounds to whole numbers in the heading and one decimal in the tables", () => {
    expect(code).toMatch(/const whole = \(v: number\) => `\$\{Math\.round\(v \* 100\)\}%`;/);
    expect(code).toMatch(/const oneDecimal = \(v: number\) => `\$\{\(v \* 100\)\.toFixed\(1\)\}%`;/);
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
    expect(source("App.tsx")).toMatch(/research: "research-title"/);
  });

  it("speaks politely, never assertively", () => {
    expect(page).not.toMatch(/aria-live="assertive"/);
    expect(code).toMatch(/className="clip-live-result" aria-live="polite"/);
  });

  it("uses real buttons, and the bars are decoration beside numbers in their own cells", () => {
    expect(code).not.toMatch(/<(div|span)[^>]*onClick/);
    expect(code).toMatch(/<span className="rate-bars" aria-hidden="true">/);
    expect(code).toMatch(/<span className="rate-value num">\{oneDecimal\(rate\.wer\)\}<\/span>/);
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
