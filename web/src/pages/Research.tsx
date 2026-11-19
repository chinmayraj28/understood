// The research page: what fine-tuning a speech model on the speakers' own recordings did.
//
// Part A, the findings, reads /research/results.json (numbers only), so it works on the hosted
// site. Part B, the clip tester, needs the local server: TORGO's text and audio never leave this
// computer, so a hosted copy shows one sentence instead. Every number comes from the data.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { clipAudioUrl } from "../../shared/dataset";
import type {
  ResearchClip,
  ResearchClipsResponse,
  ResearchDevRow,
  ResearchResults,
  ResearchRow,
  ResearchSpeaker,
  ResearchSplit,
  ResearchStatus,
  ResearchTranscribeRequest,
  ResearchTranscribeResponse,
} from "../../shared/research";
import { alignWords, countErrors, type AlignedWord } from "../../shared/wordErrors";

/** Whole numbers in headings, one decimal everywhere else. Values are fractions. */
const whole = (v: number) => `${Math.round(v * 100)}%`;
const oneDecimal = (v: number) => `${(v * 100).toFixed(1)}%`;
const bare = (v: number) => (v * 100).toFixed(1);
/** The confidence level of every interval in the file: a convention, not a result. */
const CONFIDENCE = 95;

const START_COMMAND = "cd train && uv run python serve.py";

const HELD_OUT_ORDER = ["unseen", "dysarthric-unseen", "unseen-word", "unseen-sentence", "all"];

const ROLES: { role: ResearchSplit["role"]; name: string; use: string }[] = [
  { role: "train", name: "Train", use: "The model learns from these" },
  { role: "val", name: "Validation", use: "Picks when to stop" },
  { role: "dev", name: "Dev", use: "Picks the model" },
  { role: "holdout", name: "Held-out", use: "Scored once" },
];

const STAGES: { stage: ResearchDevRow["stage"]; name: string }[] = [
  { stage: "untuned", name: "Untuned" },
  { stage: "tuned", name: "Tuned, all speakers" },
  { stage: "personalised", name: "Tuned per speaker" },
];

export function Research() {
  const results = useResearchResults();
  const data = results === "failed" ? null : results;

  return (
    <main id="main" className="research">
      <Finding results={results} />
      {/* The tester comes second: in a live demo it is one scroll away from the headline. */}
      <Tester />
      {data && (
        <>
          <SplitSection results={data} />
          <ModelsSection rows={data.dev} />
          <SpeakersSection speakers={data.perSpeaker} />
          <LimitsSection results={data} />
        </>
      )}
    </main>
  );
}

/* ───────────── Part A: the findings ───────────── */

function useResearchResults(): ResearchResults | null | "failed" {
  const [data, setData] = useState<ResearchResults | null | "failed">(null);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/research/results.json", { signal: controller.signal })
      .then((r) => (r.ok ? (r.json() as Promise<ResearchResults>) : Promise.reject(new Error(String(r.status)))))
      .then((body) => {
        if (!Array.isArray(body?.heldOut)) throw new Error("not the results file");
        setData(body);
      })
      .catch(() => {
        if (!controller.signal.aborted) setData("failed");
      });
    return () => controller.abort();
  }, []);
  return data;
}

/** The chosen model's short name ("Whisper large-v3-turbo"), from the dev rows when they name it. */
function modelName(results: ResearchResults): string {
  const id = results.model.toLowerCase();
  return results.dev.find((row) => id.includes(row.model.toLowerCase()))?.name ?? results.model;
}

function Finding({ results }: { results: ResearchResults | null | "failed" }) {
  const data = results === "failed" ? null : results;
  const lead = data?.heldOut.find((row) => row.key === "unseen");
  const title = lead
    ? lead.tuned.wer < lead.untuned.wer
      ? `Training on the voice cut words wrong from ${whole(lead.untuned.wer)} to ${whole(lead.tuned.wer)}`
      : `Training on the voice did not cut words wrong: ${whole(lead.untuned.wer)} before, ${whole(lead.tuned.wer)} after`
    : "What training on the voice did";

  return (
    <section className="research-hero" aria-labelledby="research-title">
      <div>
        <h1 id="research-title" tabIndex={-1}>
          {title}
        </h1>
        {data && lead && (
          <p className="research-lede">
            {modelName(data)}, tuned on {data.personalised ? "each speaker’s own" : "the speakers’"} recordings. Tested once on{" "}
            {lead.clips.toLocaleString()} held-out clips whose prompts it never trained on.
          </p>
        )}
        {results === null && <p className="muted research-lede">Loading the results…</p>}
        {results === "failed" && <p className="muted research-lede">The results could not be loaded.</p>}
      </div>
      {data && <HeldOutChart rows={data.heldOut} />}
    </section>
  );
}

function HeldOutChart({ rows }: { rows: ResearchRow[] }) {
  const shown = HELD_OUT_ORDER.map((key) => rows.find((row) => row.key === key)).filter((row): row is ResearchRow => !!row);
  if (shown.length === 0) return null;
  const most = Math.max(...shown.flatMap((row) => [row.untuned.wer, row.tuned.wer]), 0.0001);
  return (
    <figure className="pair-chart">
      <figcaption>
        Share of words wrong, lower is better. Small numbers: the tuned model&rsquo;s {CONFIDENCE}% interval.
      </figcaption>
      <ul>
        {shown.map((row) => (
          <li key={row.key}>
            <p className="pair-name">
              {row.label} <span className="pair-clips">{row.clips.toLocaleString()} clips</span>
            </p>
            <div className="pair-line before">
              <span className="pair-tag">Untuned</span>
              <Bar value={row.untuned.wer} most={most} />
              <span className="pair-value num">{oneDecimal(row.untuned.wer)}</span>
            </div>
            <div className="pair-line after">
              <span className="pair-tag">Tuned</span>
              <Bar value={row.tuned.wer} most={most} />
              <span className="pair-value num">{oneDecimal(row.tuned.wer)}</span>
              <span className="pair-ci">
                <span className="visually-hidden">{CONFIDENCE}% interval </span>
                {bare(row.tuned.low)}–{bare(row.tuned.high)}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </figure>
  );
}

function Bar({ value, most }: { value: number; most: number }) {
  return (
    <span className="pair-bar" aria-hidden="true">
      <span style={{ width: `${Math.min(100, (value / most) * 100)}%` }} />
    </span>
  );
}

function SplitSection({ results }: { results: ResearchResults }) {
  const parts = ROLES.map((r) => ({ ...r, split: results.split.find((s) => s.role === r.role) })).filter(
    (p): p is (typeof ROLES)[number] & { split: ResearchSplit } => !!p.split,
  );
  if (parts.length === 0) return null;
  const holdout = parts.find((p) => p.role === "holdout")?.split;
  return (
    <section className="band" aria-labelledby="split-title">
      <h2 id="split-title">How the data was split</h2>
      <div className="split-bar" aria-hidden="true">
        {parts.map((p) => (
          <span key={p.role} className={`split-part role-${p.role}`} style={{ flexGrow: p.split.clips }} />
        ))}
      </div>
      <ul className="split-legend">
        {parts.map((p) => (
          <li key={p.role}>
            <span className={`split-swatch role-${p.role}`} aria-hidden="true" />
            <span>
              <strong>{p.name}</strong> <span className="num">{p.split.clips.toLocaleString()}</span> clips
              <span className="split-use">{p.use}</span>
            </span>
          </li>
        ))}
      </ul>
      <p className="band-note split-note">
        Speakers read the same prompts, so a model can learn the prompts instead of the voice. The honest number counts only clips whose
        prompt no speaker said in training
        {holdout ? (
          <>
            : {holdout.neverTrained.toLocaleString()} of the {holdout.clips.toLocaleString()} held-out clips.
          </>
        ) : (
          "."
        )}
      </p>
    </section>
  );
}

function ModelsSection({ rows }: { rows: ResearchDevRow[] }) {
  if (rows.length === 0) return null;
  const models = [...new Set(rows.map((row) => row.model))];
  const best = rows.reduce((a, b) => (b.unseen < a.unseen ? b : a));
  return (
    <section className="band" aria-labelledby="models-title">
      <h2 id="models-title">{best.name} did best on the dev clips</h2>
      <p className="band-note">The model was chosen here, before the held-out clips were scored. Share of words wrong, lower is better.</p>
      <div className="table-wrap dev-wrap" role="region" aria-label="Each model on the dev clips" tabIndex={0}>
        <table className="dev-table">
          <thead>
            <tr>
              <th scope="col">Model</th>
              <th scope="col">Stage</th>
              <th scope="col">Never trained on</th>
              <th scope="col">All</th>
              <th scope="col">Single words</th>
              <th scope="col">Sentences</th>
            </tr>
          </thead>
          {models.map((model) => {
            const group = STAGES.map((s) => ({ ...s, row: rows.find((r) => r.model === model && r.stage === s.stage) })).filter(
              (s): s is (typeof STAGES)[number] & { row: ResearchDevRow } => !!s.row,
            );
            return (
              <tbody key={model}>
                {group.map((s, i) => (
                  <tr key={s.stage}>
                    {i === 0 && (
                      <th scope="rowgroup" rowSpan={group.length} className="dev-model">
                        {s.row.name}
                      </th>
                    )}
                    <th scope="row" className="dev-stage">
                      {s.name}
                    </th>
                    <td className="num">
                      {s.row === best ? (
                        <mark className="dev-best">
                          {oneDecimal(s.row.unseen)}
                          <span className="visually-hidden"> (lowest)</span>
                        </mark>
                      ) : (
                        oneDecimal(s.row.unseen)
                      )}
                    </td>
                    <td className="num">{oneDecimal(s.row.all)}</td>
                    <td className="num">{oneDecimal(s.row.words)}</td>
                    <td className="num">{oneDecimal(s.row.sentences)}</td>
                  </tr>
                ))}
              </tbody>
            );
          })}
        </table>
      </div>
    </section>
  );
}

function SpeakersSection({ speakers }: { speakers: ResearchSpeaker[] }) {
  if (speakers.length === 0) return null;
  // Speakers with dysarthria first, each group in the file's order.
  const ordered = [...speakers.filter((s) => s.dysarthric), ...speakers.filter((s) => !s.dysarthric)];
  const most = Math.max(...speakers.flatMap((s) => [s.untuned, s.tuned]), 0.0001);
  const dysarthric = speakers.filter((s) => s.dysarthric);
  const worst = dysarthric.length ? dysarthric.reduce((a, b) => (b.tuned > a.tuned ? b : a)) : null;
  return (
    <section className="band" aria-labelledby="speakers-title">
      <h2 id="speakers-title">Speaker by speaker</h2>
      <p className="band-note">
        The most severe speakers are still often misheard
        {worst ? (
          <>
            : the tuned model still gets {oneDecimal(worst.tuned)} of {worst.speaker}&rsquo;s words wrong.
          </>
        ) : (
          "."
        )}
      </p>
      <p className="speaker-key" aria-hidden="true">
        <span className="key before" /> Untuned <span className="key after" /> Tuned
      </p>
      <ul className="speaker-grid">
        {ordered.map((s) => (
          <li key={s.speaker} className={s.dysarthric ? "" : "control"}>
            <p className="speaker-name">
              <strong>{s.speaker}</strong> <span>{s.dysarthric ? "dysarthria" : "no dysarthria"}</span>
            </p>
            <div className="speaker-bars" aria-hidden="true">
              <span className="pair-line before">
                <Bar value={s.untuned} most={most} />
              </span>
              <span className="pair-line after">
                <Bar value={s.tuned} most={most} />
              </span>
            </div>
            <p className="speaker-values num">
              <span className="visually-hidden">Untuned </span>
              {oneDecimal(s.untuned)} <span aria-hidden="true">→</span>
              <span className="visually-hidden">, tuned</span> {oneDecimal(s.tuned)}
            </p>
          </li>
        ))}
      </ul>
    </section>
  );
}

function LimitsSection({ results }: { results: ResearchResults }) {
  return (
    <section className="band" aria-labelledby="limits-title">
      <h2 id="limits-title">What this does not show</h2>
      <ul className="limits">
        <li>The model alone, not the full pipeline.</li>
        <li>One run, with one seed.</li>
        <li>{results.speakers} speakers, from one dataset.</li>
        <li>The models overfit quickly, so when to stop matters.</li>
      </ul>
    </section>
  );
}

/* ───────────── Part B: the clip tester (local only) ───────────── */

type ClipsLoad = { status: "loading" } | { status: "ready"; clips: ResearchClip[] } | { status: "local-only" } | { status: "failed" };
type StatusLoad = { checking: true } | { checking: false; status: ResearchStatus | null };
type Kind = "all" | "word" | "sentence";
interface Picked {
  clip: ResearchClip;
  /** False for a training clip shown for contrast. */
  fair: boolean;
}

const LOCAL_ONLY = "The tester runs only on the owner’s computer, because the TORGO recordings may not be redistributed.";

function useResearchClips(): ClipsLoad {
  const [load, setLoad] = useState<ClipsLoad>({ status: "loading" });
  useEffect(() => {
    const controller = new AbortController();
    (async () => {
      try {
        const r = await fetch("/api/research/clips", { signal: controller.signal });
        // The hosted site has no such route (a 404, or its own page instead of JSON); the local
        // server refuses other machines (403).
        const json = (r.headers.get("content-type") ?? "").includes("application/json");
        if (r.status === 403 || r.status === 404 || (r.ok && !json)) return setLoad({ status: "local-only" });
        if (!r.ok) return setLoad({ status: "failed" });
        const body = (await r.json()) as ResearchClipsResponse;
        setLoad(body.available && Array.isArray(body.clips) ? { status: "ready", clips: body.clips } : { status: "local-only" });
      } catch {
        if (!controller.signal.aborted) setLoad({ status: "failed" });
      }
    })();
    return () => controller.abort();
  }, []);
  return load;
}

function useResearchStatus(): [StatusLoad, () => void] {
  const [load, setLoad] = useState<StatusLoad>({ checking: true });
  const current = useRef<AbortController | null>(null);
  const check = useCallback(() => {
    current.current?.abort();
    const controller = new AbortController();
    current.current = controller;
    setLoad({ checking: true });
    fetch("/api/research/status", { signal: controller.signal })
      .then((r) => (r.ok ? (r.json() as Promise<ResearchStatus>) : null))
      .then((status) => {
        if (!controller.signal.aborted) setLoad({ checking: false, status });
      })
      .catch(() => {
        if (!controller.signal.aborted) setLoad({ checking: false, status: null });
      });
  }, []);
  useEffect(() => {
    check();
    return () => current.current?.abort();
  }, [check]);
  return [load, check];
}

/** One clip at random, never the one already shown when there is any other. */
export function pickOne(clips: ResearchClip[], current?: ResearchClip): ResearchClip | undefined {
  const pool = clips.length > 1 && current ? clips.filter((c) => c.id !== current.id) : clips;
  return pool[Math.floor(Math.random() * pool.length)];
}

function Tester() {
  const load = useResearchClips();
  return (
    <section className="band tester" aria-labelledby="tester-title">
      <h2 id="tester-title">Try a clip it never trained on</h2>
      {load.status === "loading" && <p className="muted tester-quiet">Looking for the clips…</p>}
      {load.status === "local-only" && <p className="muted tester-quiet">{LOCAL_ONLY}</p>}
      {load.status === "failed" && <p className="muted tester-quiet">The clips could not be loaded. Is the server running?</p>}
      {load.status === "ready" && <TesterControls clips={load.clips} />}
    </section>
  );
}

function TesterControls({ clips }: { clips: ResearchClip[] }) {
  const [speaker, setSpeaker] = useState("all");
  const [kind, setKind] = useState<Kind>("all");
  const [picked, setPicked] = useState<Picked | null>(null);
  const [status, recheck] = useResearchStatus();

  const speakers = useMemo(() => {
    const byId = new Map<string, boolean>();
    for (const c of clips) byId.set(c.speaker, c.dysarthric);
    return [...byId.entries()].sort((a, b) => Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0])).map(([id]) => id);
  }, [clips]);

  const matches = useCallback((c: ResearchClip) => (speaker === "all" || c.speaker === speaker) && (kind === "all" || c.kind === kind), [speaker, kind]);
  // The fair test: a held-out clip whose prompt no speaker said in training.
  const fair = useMemo(() => clips.filter((c) => c.role === "holdout" && c.seen === false && matches(c)), [clips, matches]);
  const training = useMemo(() => clips.filter((c) => c.role === "train" && matches(c)), [clips, matches]);

  const pickFair = () => {
    const clip = pickOne(fair, picked?.clip);
    if (clip) setPicked({ clip, fair: true });
  };
  const pickTraining = () => {
    const clip = pickOne(training, picked?.clip);
    if (clip) setPicked({ clip, fair: false });
  };

  const count = fair.length === 0 ? "No held-out clips match." : `${fair.length.toLocaleString()} held-out ${fair.length === 1 ? "clip matches" : "clips match"}.`;

  return (
    <>
      <div className="tester-controls">
        <label className="tester-field">
          <span>Speaker</span>
          <select value={speaker} onChange={(e) => setSpeaker(e.target.value)}>
            <option value="all">All</option>
            {speakers.map((id) => (
              <option key={id} value={id}>
                {id}
              </option>
            ))}
          </select>
        </label>
        <div className="tester-field">
          <span id="kind-label">Kind</span>
          <div className="segmented" role="group" aria-labelledby="kind-label">
            {(
              [
                ["all", "All"],
                ["word", "Words"],
                ["sentence", "Sentences"],
              ] as const
            ).map(([value, name]) => (
              <button key={value} type="button" className={kind === value ? "on" : ""} aria-pressed={kind === value} onClick={() => setKind(value)}>
                {name}
              </button>
            ))}
          </div>
        </div>
        <button type="button" className="button primary" onClick={pickFair} disabled={fair.length === 0}>
          Random clip
        </button>
      </div>
      <p className="tester-count" aria-live="polite">
        {count}
      </p>

      {picked && <ClipCard key={picked.clip.id} picked={picked} status={status} onRecheck={recheck} />}

      <p className="tester-contrast">
        <button type="button" className="button quiet small" onClick={pickTraining} disabled={training.length === 0}>
          A training clip, for contrast
        </button>
      </p>
    </>
  );
}

type Live = { state: "idle" } | { state: "busy" } | { state: "done"; result: ResearchTranscribeResponse } | { state: "failed"; message: string };

function roleWords(clip: ResearchClip): string {
  if (clip.role === "holdout") return clip.seen ? "Held-out, prompt also in training" : "Held-out, never trained on";
  if (clip.role === "train") return "Training clip";
  if (clip.role === "val") return "Validation clip";
  return "Dev clip";
}

/** Reads the server's plain message from a failed response, whatever shape it came in. */
async function failureMessage(r: Response): Promise<string> {
  const fallback = `The live model could not hear the clip (${r.status}).`;
  try {
    const text = await r.text();
    try {
      const body = JSON.parse(text) as Record<string, unknown>;
      for (const key of ["error", "message", "reason"]) if (typeof body[key] === "string" && body[key]) return body[key] as string;
    } catch {
      // not JSON
    }
    return text && text.length < 300 && !text.trimStart().startsWith("<") ? text : fallback;
  } catch {
    return fallback;
  }
}

/** The chosen clip. It is remounted for every new clip, so leaving it stops its audio and its request. */
function ClipCard({ picked, status, onRecheck }: { picked: Picked; status: StatusLoad; onRecheck: () => void }) {
  const { clip } = picked;
  const [playing, setPlaying] = useState(false);
  const [audioFailed, setAudioFailed] = useState(false);
  const [live, setLive] = useState<Live>({ state: "idle" });
  const audio = useRef<HTMLAudioElement | null>(null);
  const request = useRef<AbortController | null>(null);

  // A new clip or leaving the page: abort the live request and stop the audio.
  useEffect(
    () => () => {
      request.current?.abort();
      audio.current?.pause();
      audio.current = null;
    },
    [],
  );

  const togglePlay = () => {
    if (playing && audio.current) {
      audio.current.pause();
      audio.current.currentTime = 0;
      setPlaying(false);
      return;
    }
    // Only one clip plays at a time on the site.
    document.querySelectorAll("audio").forEach((a) => a.pause());
    audio.current ??= new Audio(clipAudioUrl(clip.id));
    audio.current.onended = () => setPlaying(false);
    setAudioFailed(false);
    setPlaying(true);
    audio.current.play().catch(() => {
      setPlaying(false);
      setAudioFailed(true);
    });
  };

  const hearLive = async () => {
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setLive({ state: "busy" });
    try {
      const body: ResearchTranscribeRequest = { clipId: clip.id };
      const r = await fetch("/api/research/transcribe", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      if (!r.ok) {
        const message = await failureMessage(r);
        if (controller.signal.aborted) return;
        setLive({ state: "failed", message });
        onRecheck();
        return;
      }
      const result = (await r.json()) as ResearchTranscribeResponse;
      if (controller.signal.aborted) return;
      setLive({ state: "done", result });
    } catch {
      if (controller.signal.aborted) return;
      setLive({ state: "failed", message: "The live model could not be reached." });
      onRecheck();
    }
  };

  const isLive = !status.checking && status.status?.live === true;

  return (
    <article className={`clip-card${picked.fair ? "" : " unfair"}`} aria-labelledby="clip-card-title">
      <header className="clip-card-head">
        <h3 id="clip-card-title">
          {clip.speaker}, {clip.kind === "sentence" ? "a sentence" : "a single word"}
        </h3>
        <p className="clip-role">{roleWords(clip)}</p>
        {!picked.fair && <p className="clip-unfair">The model trained on this clip, so this is not a fair test.</p>}
        <button type="button" className="button small" onClick={togglePlay} aria-pressed={playing}>
          {playing ? "Stop" : "Play the clip"}
        </button>
        {audioFailed && <p className="muted">The recording could not be played.</p>}
      </header>

      <dl className="clip-lines">
        <div className="clip-line said">
          <dt>What was said</dt>
          <dd className="clip-said">&ldquo;{clip.prompt}&rdquo;</dd>
        </div>
        <ScoredLine name="Untuned model" prompt={clip.prompt} text={clip.untuned} />
        <ScoredLine name="Tuned model" prompt={clip.prompt} text={clip.tuned} />
      </dl>

      <div className="clip-live">
        <button type="button" className="button primary small" onClick={hearLive} disabled={!isLive || live.state === "busy"} aria-busy={live.state === "busy"}>
          {live.state === "busy" ? "Listening…" : "Hear it live"}
        </button>
        {!status.checking && !isLive && (
          <p className="clip-start">
            The tuned model is not running. Start it with <code>{START_COMMAND}</code>{" "}
            <button type="button" className="link-button" onClick={onRecheck}>
              Check again
            </button>
          </p>
        )}
        {status.checking && <p className="muted clip-start">Checking whether the tuned model is running…</p>}
      </div>

      <div className="clip-live-result" aria-live="polite">
        {live.state === "done" && (
          <dl className="clip-lines">
            <ScoredLine
              name="Tuned model, live"
              prompt={clip.prompt}
              text={live.result.text}
              note={`${live.result.seconds.toFixed(1)} s, heard by the model tuned on ${live.result.voice}`}
            />
          </dl>
        )}
        {live.state === "failed" && <p className="clip-error">{live.message}</p>}
      </div>
    </article>
  );
}

function ScoredLine({ name, prompt, text, note }: { name: string; prompt: string; text?: string; note?: string }) {
  if (text === undefined) {
    return (
      <div className="clip-line">
        <dt>{name}</dt>
        <dd className="muted">not scored</dd>
      </div>
    );
  }
  const count = countErrors(prompt, text);
  const rate = count.referenceWords ? count.errors / count.referenceWords : 0;
  return (
    <div className="clip-line">
      <dt>{name}</dt>
      <dd>
        <p className="aligned">
          <span className="visually-hidden">Wrote &ldquo;{text || "nothing"}&rdquo;. Word by word: </span>
          {alignWords(prompt, text).map((w, i) => (
            <Word key={i} word={w} />
          ))}
        </p>
        <p className="clip-score">
          <span className={`score-badge${count.errors === 0 ? " perfect" : rate > 0.5 ? " poor" : ""}`}>
            {count.errors === 0
              ? "Every word right"
              : `${count.errors} of ${count.referenceWords} ${count.referenceWords === 1 ? "word" : "words"} wrong`}
          </span>
          {note && <span className="muted"> {note}</span>}
        </p>
      </dd>
    </div>
  );
}

function Word({ word }: { word: AlignedWord }) {
  switch (word.op) {
    case "ok":
      return <span className="w ok">{word.word} </span>;
    case "sub":
      return (
        <span className="w sub">
          <del>{word.word}</del>
          <span className="visually-hidden"> heard as </span>
          <ins>{word.heard}</ins>{" "}
        </span>
      );
    case "del":
      return (
        <span className="w del">
          <del>{word.word}</del> <span className="visually-hidden">(missed)</span>
        </span>
      );
    case "ins":
      return (
        <span className="w ins">
          <ins>{word.heard}</ins> <span className="visually-hidden">(added)</span>
        </span>
      );
  }
}
