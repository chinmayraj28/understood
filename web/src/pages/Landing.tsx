// The landing page: what Understood is, how a sentence travels through it, how well it works,
// and the way into the pipeline. The hero is a real result: TORGO speaker M05 saying "up".

import { useEffect, useState, type MouseEvent } from "react";
import { EvaluationTable, useEvalResults, WordsWrongChart } from "../components/Evaluation";
import { href } from "../router";

const STAGES = [
  {
    name: "Record",
    text: "A sentence is spoken, or a recording is played. The live transcript writes it down as it goes.",
  },
  {
    name: "Hear it three ways",
    text: "ElevenLabs Scribe, Gemini shown a few clips of the same voice, and the live transcript all hear it at once.",
  },
  {
    name: "Check the phrasebook",
    text: "Mishearings this person confirmed before are looked up: “call some” has meant “call Sam” twice.",
  },
  {
    name: "Repair",
    text: "Claude Haiku weighs the three texts and the phrasebook into one reading, and says how sure it is.",
  },
  {
    name: "Decide",
    text: "A rule in code acts, or asks one short question first. Claude on its own never makes it act.",
  },
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
  const scribe = results.data?.setups.find((s) => s.id === "scribe");
  const full = results.data?.setups.find((s) => s.id === "phrasebook");
  const pct = (v?: number | null) => (v === undefined || v === null ? "…" : `${Math.round(v * 100)}%`);

  return (
    <main id="main" className="landing">
      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <h1 id="hero-title" tabIndex={-1}>Understands speech that voice assistants get wrong.</h1>
          <p className="hero-lede">
            Slow, slurred or quiet speech, common with cerebral palsy, ALS, Parkinson&rsquo;s and stroke, defeats ordinary
            recognisers. Understood hears each sentence three ways, checks it against what this person has said before, and repairs
            it into one transcript, showing every step as it happens.
          </p>
          <div className="hero-actions">
            <a className="button primary" href={href.pipeline}>
              Try it on a real recording
            </a>
            <a className="button" href={href.how} onClick={onSectionLink("how")}>
              See how it works
            </a>
          </div>
        </div>
        <HeroDiagram />
      </section>

      <section className="band" id="how" aria-labelledby="how-title">
        <div className="band-head">
          <h2 id="how-title" tabIndex={-1}>How a sentence travels</h2>
          <p>Five stops, each shown live on the pipeline page with its real timing.</p>
        </div>
        <ol className="route-map">
          {STAGES.map((stage, i) => (
            <li key={stage.name}>
              <span className="route-stop" aria-hidden="true">
                {i + 1}
              </span>
              <h3>{stage.name}</h3>
              <p>{stage.text}</p>
            </li>
          ))}
        </ol>
      </section>

      <section className="band split" aria-labelledby="ask-title">
        <div className="split-copy">
          <h2 id="ask-title">It asks before it acts</h2>
          <p>
            Someone who cannot use their hands cannot undo a wrong action. So when the recognisers disagree, Understood asks one short
            question instead of guessing.
          </p>
          <ul className="plain-list">
            <li>Acting needs two recognisers to agree, or a phrase this person has confirmed at least twice.</li>
            <li>A yes counts only when it is just a yes, said after the question finished.</li>
            <li>The model never chooses who a message goes to.</li>
          </ul>
        </div>
        <figure className="decision-sample">
          <div className="sample-heard">
            <p>
              <span className="lane-dot dot-scribe" aria-hidden="true" /> Scribe <q>Mum sis, I&rsquo;m running late</q>
            </p>
            <p>
              <span className="lane-dot dot-gemini" aria-hidden="true" /> Gemini <span className="muted">timed out</span>
            </p>
            <p>
              <span className="lane-dot dot-realtime" aria-hidden="true" /> Live <q>message Sam running late</q>
            </p>
          </div>
          <div className="sample-question">
            <p className="sample-label">Asks first</p>
            <p className="sample-text">&ldquo;Message Sam running late?&rdquo;</p>
            <p className="sample-rule">Claude thought this likely but was not sure of a word that matters.</p>
          </div>
          <figcaption className="muted">A live run on 11 November, with a synthetic voice.</figcaption>
        </figure>
      </section>

      <section className="band" id="results" aria-labelledby="results-title">
        <div className="band-head">
          <h2 id="results-title" tabIndex={-1}>Measured on real recordings</h2>
          <p>
            {results.data
              ? `${results.data.utterances} recordings of ${results.data.speakers} speakers from TORGO, most with dysarthria from cerebral palsy. Each speaker's setup was learned from their own earlier clips and tested on later ones.`
              : "Recordings of people with dysarthria from TORGO."}
          </p>
        </div>
        <div className="results-grid">
          <div className="results-lead">
            <p className="results-sentence">
              Words wrong fell from <strong>{pct(scribe?.wordErrorRate)}</strong> with Scribe alone to <strong>{pct(full?.wordErrorRate)}</strong>{" "}
              with the full pipeline, and to <strong>{pct(full?.seenWordErrorRate)}</strong> on phrases the person had said before. It went ahead
              wrongly on <strong>{pct(full?.wrongActionRate)}</strong> of recordings.
            </p>
            <p className="muted">
              One dataset, a handful of speakers, single runs, mostly single words: a first measurement, not a benchmark. In the evaluation the
              third recogniser was Apple&rsquo;s on-device one; this site uses ElevenLabs realtime instead.
            </p>
          </div>
          {results.data ? <WordsWrongChart setups={results.data.setups} /> : <p className="muted">{results.failed ? "The results could not be loaded." : "Loading the results…"}</p>}
        </div>
        {results.data && (
          <details className="results-more">
            <summary>Show the full table</summary>
            <EvaluationTable results={results.data} />
          </details>
        )}
      </section>

      <section className="band split" id="privacy" aria-labelledby="privacy-title">
        <div className="split-copy">
          <h2 id="privacy-title" tabIndex={-1}>Your voice stays yours</h2>
          <p>Speech recordings of a disabled person are health data, so they are handled that way.</p>
        </div>
        <ul className="fact-list">
          <li>
            <h3>Kept in your browser</h3>
            <p>Your phrasebook and voice clips live in this browser. The server stores nothing.</p>
          </li>
          <li>
            <h3>Sent only to be heard</h3>
            <p>Audio goes to ElevenLabs, and to Gemini through OpenRouter, and text to Claude, only while a sentence is being understood.</p>
          </li>
          <li>
            <h3>A pretend phone</h3>
            <p>Messages and calls on the page are pretend. Nothing reaches a real person.</p>
          </li>
        </ul>
      </section>

      <section className="closing" aria-labelledby="closing-title">
        <h2 id="closing-title">Hear it on a real recording</h2>
        <p>Pick a TORGO speaker and a clip, or upload your own. You will see what each recogniser heard and every word it got right or wrong.</p>
        <div className="hero-actions">
          <a className="button primary" href={href.pipeline}>
            Open the pipeline
          </a>
          <a className="button" href={href.recordings}>
            Browse the recordings
          </a>
        </div>
      </section>
    </main>
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
        <p className="hero-result-score">Every word right</p>
      </div>
      <figcaption>
        TORGO speaker M05, cerebral palsy, moderate to severe. Two recognisers heard &ldquo;uh&rdquo;; Gemini, shown five of M05&rsquo;s own
        clips, heard &ldquo;up&rdquo;. A real run, 11 November.
      </figcaption>
    </figure>
  );
}
