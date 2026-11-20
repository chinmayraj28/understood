// The landing page: one claim, one real example, the route a sentence takes, and the measured
// result. The hero is a real result: TORGO speaker M05 saying "Alfalfa is healthy for you."

import { useEffect, useState } from "react";
import { href } from "../router";

const STAGES = [
  { name: "Record", text: "Microphone or file" },
  { name: "Hear", text: "Several listeners at once" },
  { name: "Phrasebook", text: "Past mishearings" },
  { name: "Repair", text: "Claude merges them" },
];

/**
 * The pipeline as it runs today (server/understand.ts, server/hearers.ts, server/claude.ts,
 * src/audio/liveTranscript.ts). `alone` names the matching key in transcription.json.
 */
const TECH_STEPS: { name: string; model: string; text: string; alone?: string }[] = [
  {
    name: "1. Record",
    model: "your browser",
    text: "Takes one sentence, from a recording or from your microphone, and sends it on.",
  },
  {
    name: "2a. Hear: Scribe",
    model: "ElevenLabs scribe_v3",
    text: "Ordinary speech-to-text. It is given no list of words to expect.",
    alone: "Scribe v3 alone",
  },
  {
    name: "2b. Hear: Gemini",
    model: "Google gemini-3.1-pro-preview",
    text: "First shown 5 earlier clips of this speaker with what they said, so it learns how they sound. Then it writes down the new clip.",
    alone: "Gemini 3.1 Pro alone",
  },
  {
    name: "2c. Hear: Gemini 4",
    model: "Google gemini-4-carbon",
    text: "Shown the same 5 clips. A second opinion that makes different mistakes from the first Gemini.",
  },
  {
    name: "2d. Hear: Live",
    model: "ElevenLabs scribe_v3_live",
    text: "Writes the words down while the sentence is still being said (scribe_v2_realtime from the microphone).",
    alone: "Live transcript alone",
  },
  {
    name: "3. Phrasebook",
    model: "no model, plain code",
    text: "Looks for mishearings it has already learned for this speaker. For example, Scribe once heard \u201cMum sis\u201d when they meant \u201cmessage Sam\u201d.",
  },
  {
    name: "4. Repair",
    model: "Anthropic claude-opus-5-5",
    text: "Reads all four transcripts and any phrasebook match, and writes the one final transcript.",
    alone: "together",
  },
];

/**
 * Scrolls the landing page to a section ("how", "results") and moves focus to its
 * heading, so keyboard and screen-reader users land there too.
 */
export function scrollToSection(section: string) {
  const target = document.getElementById(section);
  if (!target) return;
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  target.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
  document.getElementById(`${section}-title`)?.focus({ preventScroll: true });
}

export function Landing({ section }: { section?: string }) {
  // #/how and #/results open this page at that section, with focus on its heading.
  useEffect(() => {
    if (section) scrollToSection(section);
    else window.scrollTo({ top: 0 });
  }, [section]);
  const loaded = useTranscriptionResults();
  const transcription = loaded === "failed" ? null : loaded;
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
              <>
                <p className="band-note">
                  The % is how many words it gets wrong out of every 100 words a person says. Lower is better.
                </p>
                <p className="band-note">
                  For people with dysarthria, it went from {pct(transcription.before.dysarthric)} wrong to{" "}
                  {pct(transcription.after.dysarthric)} wrong. Tested on {transcription.clips} real recordings from the TORGO
                  dataset. The hardest speech to understand is still often misheard.
                </p>
              </>
            )}
          </div>
          {transcription ? (
            <BeforeAfterChart data={transcription} />
          ) : (
            <p className="muted">{loaded === "failed" ? "The results could not be loaded." : "Loading the results…"}</p>
          )}
        </div>
        {transcription && (
          <div className="results-how">
            <h3>How this was measured</h3>
            <ul>
              <li>
                We used {transcription.clips} recordings from TORGO, a research collection of {transcription.speakers} real people
                reading words and sentences aloud. Some have dysarthria and some do not, for comparison.
              </li>
              <li>
                We know what each person was reading, so we compared that with what the system wrote down and counted the wrong
                words.
              </li>
              <li>
                None of these recordings were used while building the system, so it was not tuned to pass this test. To learn a
                voice, it was only shown that person&rsquo;s own earlier recordings.
              </li>
              <li>
                &ldquo;Before&rdquo; is the system on the morning of 11 November. &ldquo;Now&rdquo; is after it was rebuilt that
                day.
              </li>
            </ul>
          </div>
        )}
        <div className="results-how">
          <h3>What runs, step by step</h3>
          <p className="muted">
            The same for a recording and for your microphone. The four listeners in step 2 hear the sentence at the same time, not
            one after another; each gets up to 15 seconds, and Claude up to 8. &ldquo;Alone&rdquo; is words wrong when that model is
            used by itself, on the same test.
          </p>
          <ol className="tech-steps">
            {TECH_STEPS.map((step) => (
              <li key={step.name}>
                <div className="tech-head">
                  <h4>{step.name}</h4>
                  <code>{step.model}</code>
                  {step.alone && transcription && (
                    <span className="tech-score num">
                      {step.alone === "together" ? "all together" : "alone"}{" "}
                      {pct(step.alone === "together" ? transcription.after.wordErrorRate : transcription.alone[step.alone])} wrong
                    </span>
                  )}
                </div>
                <p>{step.text}</p>
              </li>
            ))}
          </ol>
        </div>
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
    { name: "Now: all listeners together", value: data.after.wordErrorRate, tone: "now" },
  ];
  const most = Math.max(...bars.map((b) => b.value));
  return (
    <figure className="ww-chart">
      <figcaption className="ww-caption">Words wrong out of every 100. Lower is better.</figcaption>
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
 * TORGO speaker M05 saying "Alfalfa is healthy for you.", a held-out test clip the voice was not
 * set up with, heard on 20 November 2026 (web/scripts/evalTranscription.ts).
 */
function HeroDiagram() {
  // A phone gets its own, shorter drawing, so the words stay legible instead of shrinking.
  const compact = useNarrow(600);
  const g = compact
    ? { width: 340, height: 290, gap: 90, top: 55, straight: 215, merge: 285, end: 322 }
    : { width: 560, height: 330, gap: 90, top: 70, straight: 330, merge: 470, end: 536 };
  const mid = g.top + g.gap;
  const lanes = [
    { id: "scribe", name: "Scribe", heard: "“Our father is happy for you.”", y: g.top, wrong: true },
    { id: "gemini", name: "Gemini", heard: "“Alfalfa is healthy for you.”", y: mid, wrong: false },
    { id: "realtime", name: "Live", heard: "“Alfalfa is healthy for you.”", y: g.top + 2 * g.gap, wrong: false },
  ];
  return (
    <figure className="hero-figure">
      <svg
        className="hero-diagram"
        viewBox={`0 0 ${g.width} ${g.height}`}
        role="img"
        aria-label="Speaker M05 said “Alfalfa is healthy for you.” Scribe heard “Our father is happy for you.” Gemini, shown five of M05's own clips, and the live transcript both heard “Alfalfa is healthy for you.” The pipeline's transcript: “Alfalfa is healthy for you.”, every word right."
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
            <text className={`hero-heard${lane.wrong ? " wrong" : ""}`} x="44" y={lane.y + 28}>
              {lane.heard}
            </text>
          </g>
        ))}
        <path className="hero-main" d={`M ${g.merge} ${mid} H ${g.end}`} pathLength={1} />
        <circle className="hero-end" cx={g.end} cy={mid} r="11" />
      </svg>
      <div className="hero-result">
        <p className="hero-result-text">&ldquo;Alfalfa is healthy for you.&rdquo;</p>
      </div>
      <figcaption>TORGO speaker M05, saying &ldquo;Alfalfa is healthy for you.&rdquo; A real run.</figcaption>
    </figure>
  );
}
