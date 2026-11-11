// Moving between pages: leaving the pipeline closes the microphone for good (until the visitor
// comes back), a recording never plays off the pipeline, and each page change is announced.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const source = (path: string) => readFileSync(join(__dirname, "../../src", path), "utf8");
const slice = (text: string, from: string, to: string) => {
  const start = text.indexOf(from);
  expect(start).toBeGreaterThanOrEqual(0);
  return text.slice(start, text.indexOf(to, start));
};

describe("leaving the pipeline page (useSession.leavePipeline)", () => {
  const session = source("useSession.ts");
  const leave = slice(session, "const leavePipeline = useCallback(", "}, [listener, stopHearing]);");

  it("clears the after-recording booking before stopping the hearing, so the mic cannot reopen on the other page", () => {
    expect(leave.indexOf("micAfterRecording.current = false;")).toBeGreaterThan(0);
    expect(leave.indexOf("micAfterRecording.current = false;")).toBeLessThan(leave.indexOf("stopHearing();"));
    expect(leave).toMatch(/listener\.stop\(\);/);
    expect(leave).toMatch(/setListening\(false\)/);
  });

  it("reports the microphone as on when it was on or booked to reopen after a recording", () => {
    expect(leave.indexOf("const wasOn = listener.isOn || micAfterRecording.current;")).toBeLessThan(leave.indexOf("micAfterRecording.current = false;"));
    expect(leave).toMatch(/return wasOn;/);
  });

  it("closes the voice setup dialog", () => {
    expect(leave).toMatch(/setEnrol\(\(e\) => \(e\.open \? \{ \.\.\.e, open: false \} : e\)\)/);
  });

  it("a start overtaken by a stop does not claim the microphone is on", () => {
    const start = slice(session, "const startListening = useCallback(", "}, [listener]);");
    const awaited = start.indexOf("await listener.start(");
    const guard = start.indexOf("if (!listener.isOn) return;");
    expect(guard).toBeGreaterThan(awaited);
    expect(guard).toBeLessThan(start.indexOf("setListening(true);"));
  });

  it("does not open the microphone by itself on first load: the app does, on the pipeline page only", () => {
    expect(session).not.toMatch(/navigator\.permissions[\s\S]*startListening\(\)/);
  });
});

describe("the app around the pages", () => {
  const app = source("App.tsx");

  it("leaves the pipeline through leavePipeline and remembers whether to resume the microphone", () => {
    const effect = slice(app, "const resumeListening = useRef(false);", "}, [page, listening, leavePipeline, startListening]);");
    expect(effect).toMatch(/if \(page !== "pipeline"\) \{\s*if \(leavePipeline\(\)\) resumeListening\.current = true;/);
    expect(effect).not.toMatch(/stopHearing\(|stopListening\(/);
  });

  it("starts hands-free listening only on the pipeline page", () => {
    const auto = slice(app, "void microphoneAllowed().then(", "});");
    expect(auto).toMatch(/if \(pageRef\.current === "pipeline"\) void startListening\(\);\s*else resumeListening\.current = true;/);
  });

  it("a hear link plays nothing once the visitor has left the pipeline, and says why when it cannot play", () => {
    const hear = slice(app, "void loadDataset().then((load) => {", "}, [ready, route, hearRecording, showNotice]);");
    expect(hear.indexOf('if (pageRef.current !== "pipeline") return;')).toBeLessThan(hear.indexOf("hearRecording("));
    expect(hear).toMatch(/showNotice\(load\.status === "missing" \? load\.reason/);
    expect(hear).toMatch(/That recording isn’t in this copy of TORGO\./);
  });

  it("moves focus to the new page's heading after a page change", () => {
    expect(app).toMatch(/"hero-title" : "pipeline-title"/);
    expect(source("pages/PipelinePage.tsx")).toMatch(/<h1 id="pipeline-title" className="ws-title" tabIndex=\{-1\}>/);
    expect(source("pages/Landing.tsx")).toMatch(/<h1 id="hero-title" tabIndex=\{-1\}>/);
  });
});

describe("pages and links", () => {
  it("the input panel only changes source when the visitor picks one, and keeps every picker mounted", () => {
    const hear = source("components/HearRecording.tsx");
    expect(hear).not.toMatch(/if \(props\.listening\) setSource\("mic"\)/);
    expect(hear).toMatch(/hidden=\{source !== "torgo"\}/);
    expect(hear).toMatch(/hidden=\{source !== "file"\}/);
  });

  it("section links scroll even when the address already matches", () => {
    const chrome = source("components/SiteChrome.tsx");
    expect(chrome).toMatch(/href=\{href\.how\} onClick=\{onSectionLink\("how"\)\}/);
    expect(chrome).toMatch(/href=\{href\.results\} onClick=\{onSectionLink\("results"\)\}/);
    expect(source("pages/Landing.tsx")).toMatch(/window\.location\.hash !== event\.currentTarget\.getAttribute\("href"\)/);
  });

  it("the pipeline page has no complementary regions inside main", () => {
    expect(source("pages/PipelinePage.tsx")).not.toMatch(/<aside/);
  });

  it("the sticky side columns do not trap the page's scrolling", () => {
    expect(source("styles/workspace.css")).not.toMatch(/overscroll-behavior: contain/);
  });

  it("scroll targets stop below the sticky header", () => {
    expect(source("styles/hear.css")).toMatch(/#hear-title \{\s*scroll-margin-top: 80px;/);
    expect(source("styles/workspace.css")).toMatch(/#result-area \{\s*scroll-margin-top: 80px;/);
    expect(source("styles/site.css")).toMatch(/#how,\s*#results,\s*#privacy \{\s*scroll-margin-top: 80px;/);
  });
});
