// The landing page: one claim, one real example, the route a sentence takes, the measured result,
// and the two promises that matter. The hero is a real result: TORGO speaker M05 saying "up".

import { useEffect, useState, type MouseEvent } from "react";
import { EvaluationTable, useEvalResults, WordsWrongChart } from "../components/Evaluation";
import { href } from "../router";

const STAGES = [
  { name: "Record", text: "Microphone or file" },
  { name: "Hear", text: "Several listeners at once" },
  { name: "Phrasebook", text: "Past mishearings" },
  { name: "Repair", text: "Claude merges them" },
  { name: "Decide", text: "Act, or ask first" },
];

/**
 * Scrolls the landing page to a section ("how", "results", "privacy") and moves focus to its
 * heading, so keyboard and screen-reader users land there too.
 */
export function scrollToSection(section: string) {
  const target = document.getElementById(section);
  if (!target) return;
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  target.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
  document.getElementById(`${section}-title`)?.focus({ preventScroll: true });
}

/**
 * A link to a section whose address is already open changes nothing, so the browser fires no
 * hashchange and the page would not move. Scroll there by hand instead.
 */
export function onSectionLink(section: string) {
  return (event: MouseEvent<HTMLAnchorElement>) => {
    if (window.location.hash !== event.currentTarget.getAttribute("href")) return;
    event.preventDefault();
    scrollToSection(section);
  };
}

export function Landing({ section }: { section?: string }) {
  // #/how and #/results open this page at that section, with focus on its heading.
  useEffect(() => {
    if (section) scrollToSection(section);
    else window.scrollTo({ top: 0 });
  }, [section]);
  const results = useEvalResults();
  const loaded = useTranscriptionResults();
  const transcription = loaded === "failed" ? null : loaded;
  const scribe = results.data?.setups.find((s) => s.id === "scribe");
  const full = results.data?.setups.find((s) => s.id === "phrasebook");
  const pct = (v?: number | null) => (v === undefined || v === null ? "…" : `${Math.round(v * 100)}%`);

  return (
    <main id="main" className="landing">
      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <h1 id="hero-title" tabIndex={-1}>Understands speech that voice assistants get wrong.</h1>
          <p className="hero-lede">For people whose speech is slow, slurred or quiet.</p>
          <a className="button primary hero-action" href={href.pipeline}>
            Try it on a real recording
          </a>
        </div>
        <HeroDiagram />
      </section>

      <section className="band" id="how" aria-labelledby="how-title">
        <h2 id="how-title" tabIndex={-1}>How a sentence travels</h2>
        <ol className="route-map">
          {STAGES.map((stage) => (
            <li key={stage.name}>
              <span className="route-stop" aria-hidden="true" />
              <h3>{stage.name}</h3>
              <p>{stage.text}</p>
            </li>
          ))}
        </ol>
      </section>

      <section className="band" id="results" aria-labelledby="results-title">
        <div className="band-row">
          <div>
            <h2 id="results-title" tabIndex={-1}>
              {transcription
                ? `Words wrong fell from ${pct(transcription.before.wordErrorRate)} to ${pct(transcription.after.wordErrorRate)}`
                : "Measured on real recordings"}
            </h2>
            {transcription && (
              <p className="band-note">
                For speakers with dysarthria, {pct(transcription.before.dysarthric)} to {pct(transcription.after.dysarthric)}. A first
                measurement on {transcription.clips} TORGO recordings. The most severe speech is still often misheard.
              </p>
            )}
          </div>
          {transcription ? (
            <BeforeAfterChart data={transcription} />
          ) : (
            <p className="muted">{loaded === "failed" ? "The results could not be loaded." : "Loading the results…"}</p>
          )}
        </div>
        {(transcription || results.data) && (
          <details className="results-more">
            <summary>How this was measured</summary>
            {transcription && <p className="muted results-earlier">{transcription.note}</p>}
            {results.data && (
              <>
                <p className="muted results-earlier">
                  An earlier evaluation, on 9 November, used the first Swift version, where the third recogniser was Apple&rsquo;s on-device
                  one. Words wrong fell from {pct(scribe?.wordErrorRate)} with Scribe alone to {pct(full?.wordErrorRate)}; it went ahead
                  wrongly on {pct(full?.wrongActionRate)} of recordings.
                </p>
                <WordsWrongChart setups={results.data.setups} />
                <EvaluationTable results={results.data} />
              </>
            )}
          </details>
        )}
      </section>

      <section className="band band-row" aria-labelledby="ask-title">
        <h2 id="ask-title">When it isn&rsquo;t sure, it asks</h2>
        <figure className="ask-sample">
          <blockquote>Message Sam running late?</blockquote>
          <figcaption>
            Scribe heard &ldquo;Mum sis, I&rsquo;m running late&rdquo;. The live transcript heard &ldquo;message Sam running late&rdquo;. A live
            run with a synthetic voice.
          </figcaption>
        </figure>
      </section>

      <section className="band band-row" id="privacy" aria-labelledby="privacy-title">
        <h2 id="privacy-title" tabIndex={-1}>Your voice stays yours</h2>
        <p className="privacy-line">
          Your phrasebook and clips stay in this browser. Audio is sent out only to be heard. The phone on the page is pretend.
        </p>
      </section>
    </main>
  );
}

interface TranscriptionResults {
  clips: number;
  speakers: number;
  note: string;
  before: { wordErrorRate: number; words: number; sentences: number; dysarthric: number; exact: number };
  after: { wordErrorRate: number; words: number; sentences: number; dysarthric: number; exact: number };
  alone: Record<string, number>;
}

/** The held-out before-and-after measurement, written by scripts/exportTranscription.ts. */
function useTranscriptionResults(): TranscriptionResults | null | "failed" {
  const [data, setData] = useState<TranscriptionResults | null | "failed">(null);
  useEffect(() => {
    fetch("/eval/transcription.json")
      .then((r) => (r.ok ? (r.json() as Promise<TranscriptionResults>) : Promise.reject(new Error(String(r.status)))))
      .then(setData)
      .catch(() => setData("failed"));
  }, []);
  return data;
}

/** Words wrong: before, each listener alone, and the pipeline now. */
function BeforeAfterChart({ data }: { data: TranscriptionResults }) {
  const bars = [
    { name: "Before", value: data.before.wordErrorRate, tone: "before" },
    ...Object.entries(data.alone).map(([name, value]) => ({ name, value, tone: "alone" })),
    { name: "Understood now", value: data.after.wordErrorRate, tone: "now" },
  ];
  const most = Math.max(...bars.map((b) => b.value));
  return (
    <figure className="ww-chart">
      <figcaption className="visually-hidden">Share of words wrong on the held-out recordings. Lower is better.</figcaption>
      <ul>
        {bars.map((b) => (
          <li key={b.name} className={b.tone === "now" ? "best" : ""}>
            <span className="ww-name">{b.name}</span>
            <span className="ww-bar" aria-hidden="true">
              <span style={{ width: `${(b.value / most) * 100}%` }} />
            </span>
            <span className="ww-value num">{Math.round(b.value * 100)}%</span>
          </li>
        ))}
      </ul>
    </figure>
  );
}

/** True while the window is at most `px` wide. */
function useNarrow(px: number): boolean {
  const query = `(max-width: ${px}px)`;
  const [narrow, setNarrow] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const list = window.matchMedia(query);
    const onChange = () => setNarrow(list.matches);
    list.addEventListener("change", onChange);
    return () => list.removeEventListener("change", onChange);
  }, [query]);
  return narrow;
}

/**
 * Three recognisers on three tracks, merging into one transcript. The texts are a real run:
 * TORGO speaker M05 saying "up", heard on 11 November 2026.
 */
function HeroDiagram() {
  // A phone gets its own, shorter drawing, so the words stay legible instead of shrinking.
  const compact = useNarrow(600);
  const g = compact
    ? { width: 340, height: 290, gap: 90, top: 55, straight: 130, merge: 250, end: 322 }
    : { width: 560, height: 330, gap: 90, top: 70, straight: 250, merge: 400, end: 536 };
  const mid = g.top + g.gap;
  const lanes = [
    { id: "scribe", name: "Scribe", heard: "“Uh.”", y: g.top, wrong: true },
    { id: "gemini", name: "Gemini", heard: "“up”", y: mid, wrong: false },
    { id: "realtime", name: "Live", heard: "“Uh...”", y: g.top + 2 * g.gap, wrong: true },
  ];
  return (
    <figure className="hero-figure">
      <svg
        className="hero-diagram"
        viewBox={`0 0 ${g.width} ${g.height}`}
        role="img"
        aria-label="Speaker M05 said “up”. Scribe heard “Uh.”, the live transcript heard “Uh...”, and Gemini, shown five of M05's own clips, heard “up”. The pipeline's transcript: “up”, every word right."
      >
        {lanes.map((lane, i) => (
          <g key={lane.id} className={`hero-lane lane-${lane.id}`} style={{ animationDelay: `${i * 140}ms` }}>
            <path
              className="hero-track"
              d={`M 24 ${lane.y} H ${g.straight} C ${g.straight + 70} ${lane.y} ${g.merge - 70} ${mid} ${g.merge} ${mid}`}
              pathLength={1}
            />
            <circle className="hero-station" cx="24" cy={lane.y} r="7" />
            <text className="hero-name" x="44" y={lane.y - 16}>
              {lane.name}
            </text>
            <text className={`hero-heard${lane.wrong ? " wrong" : ""}`} x="44" y={lane.y + 30}>
              {lane.heard}
            </text>
          </g>
        ))}
        <path className="hero-main" d={`M ${g.merge} ${mid} H ${g.end}`} pathLength={1} />
        <circle className="hero-end" cx={g.end} cy={mid} r="11" />
      </svg>
      <div className="hero-result">
        <p className="hero-result-text">&ldquo;up&rdquo;</p>
      </div>
      <figcaption>TORGO speaker M05, saying &ldquo;up&rdquo;. A real run.</figcaption>
    </figure>
  );
}
