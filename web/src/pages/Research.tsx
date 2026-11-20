// The research page: does training a speech model on dysarthric speech help on a stranger?
//
// The findings read /research/results.json (numbers only), so they work on the hosted site. They
// lead with the leave-one-speaker-out test (`loso`); a results file written before that test has
// no `loso`, and the page then falls back to the earlier test's headline. The clip tester needs
// the local server: TORGO's text and audio never leave this computer, so a hosted copy shows one
// sentence instead. Every number comes from the data.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { clipAudioUrl } from "../../shared/dataset";
import type {
  ResearchClip,
  ResearchClipsResponse,
  ResearchDevRow,
  ResearchLoso,
  ResearchRate,
  ResearchResults,
  ResearchRow,
  ResearchStatus,
  ResearchTranscribeRequest,
  ResearchTranscribeResponse,
} from "../../shared/research";
import { alignWords, countErrors, type AlignedWord } from "../../shared/wordErrors";

/** Whole numbers in headings and per speaker, one decimal in the tables. Values are fractions. */
const whole = (v: number) => `${Math.round(v * 100)}%`;
const oneDecimal = (v: number) => `${(v * 100).toFixed(1)}%`;
const bare = (v: number) => (v * 100).toFixed(1);
/** The confidence level of every interval in the file: a convention, not a result. */
const CONFIDENCE = 95;

const START_COMMAND = "cd train && uv run python serve.py";

/** The main table's rows, in this order. The file has two more, kept for completeness. */
const RESULT_ORDER = ["all", "new-prompt", "sentence", "word"];

/** The earlier test's rows, with plainer names than the file's. */
const EARLIER_ROWS: { key: string; label: string }[] = [
  { key: "unseen", label: "All speakers" },
  { key: "dysarthric-unseen", label: "Speakers with dysarthria" },
  { key: "unseen-sentence", label: "Sentences" },
  { key: "unseen-word", label: "Single words" },
];

const COUNTS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"];
/** Small counts as words ("eight"), larger ones as digits. */
const say = (n: number) => COUNTS[n] ?? n.toLocaleString();
const capital = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export function Research() {
  return <ResearchView results={useResearchResults()} />;
}

/** The page for given results: null while loading, "failed" when the file could not be read. */
export function ResearchView({ results }: { results: ResearchResults | null | "failed" }) {
  const data = results === "failed" ? null : results;
  const loso = data?.loso;

  return (
    <main id="main" className="research">
      <Hero results={results} />
      {loso && (
        <>
          <ResultSection loso={loso} />
          <SpeakersSection loso={loso} />
          <MethodSection loso={loso} />
        </>
      )}
      <Tester />
      {data && (
        <>
          <EarlierSection rows={data.heldOut} />
          <LimitsSection results={data} />
        </>
      )}
    </main>
  );
}

/* ───────────── The findings ───────────── */

function useResearchResults(): ResearchResults | null | "failed" {
  const [data, setData] = useState<ResearchResults | null | "failed">(null);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/research/results.json", { signal: controller.signal })
      .then((r) => (r.ok ? (r.json() as Promise<ResearchResults>) : Promise.reject(new Error(String(r.status)))))
      .then((body) => {
        if (!Array.isArray(body?.heldOut)) throw new Error("not the results file");
        // An older file has no leave-one-speaker-out test; a broken one is treated the same way.
        const loso = body.loso && Array.isArray(body.loso.rows) && Array.isArray(body.loso.perSpeaker) ? body.loso : undefined;
        setData({ ...body, loso });
      })
      .catch(() => {
        if (!controller.signal.aborted) setData("failed");
      });
    return () => controller.abort();
  }, []);
  return data;
}

/** A model's short name ("Whisper large-v3-turbo"), from the dev rows when they name it. */
function modelName(id: string, dev: ResearchDevRow[]): string {
  const lower = id.toLowerCase();
  return dev.find((row) => lower.includes(row.model.toLowerCase()))?.name ?? id;
}

function Hero({ results }: { results: ResearchResults | null | "failed" }) {
  const data = results === "failed" ? null : results;
  const fresh = data?.loso?.rows.find((row) => row.key === "all");
  const lead = data?.heldOut.find((row) => row.key === "unseen");

  let title = "What training on dysarthric speech did";
  if (fresh) {
    title =
      fresh.tuned.wer < fresh.untuned.wer
        ? `On a person it never heard, training cut words wrong from ${whole(fresh.untuned.wer)} to ${whole(fresh.tuned.wer)}`
        : `On a person it never heard, training did not cut words wrong: ${whole(fresh.untuned.wer)} before, ${whole(fresh.tuned.wer)} after`;
  } else if (lead) {
    title =
      lead.tuned.wer < lead.untuned.wer
        ? `Training on the voice cut words wrong from ${whole(lead.untuned.wer)} to ${whole(lead.tuned.wer)}`
        : `Training on the voice did not cut words wrong: ${whole(lead.untuned.wer)} before, ${whole(lead.tuned.wer)} after`;
  }

  return (
    <section className="research-hero" aria-labelledby="research-title">
      <h1 id="research-title" tabIndex={-1}>
        {title}
      </h1>
      {data?.loso && fresh && (
        <p className="research-lede">
          {modelName(data.loso.model, data.dev)}, trained on everyone else and tested on one speaker it had never heard, for each of{" "}
          {say(data.loso.speakers)} speakers with dysarthria in turn.
        </p>
      )}
      {data && !fresh && lead && (
        <p className="research-lede">
          {modelName(data.model, data.dev)}, trained on the speakers&rsquo; recordings and tested on {lead.clips.toLocaleString()} clips whose
          words it never trained on.
        </p>
      )}
      {results === null && <p className="muted research-lede">Loading the results…</p>}
      {results === "failed" && <p className="muted research-lede">The results could not be loaded.</p>}
    </section>
  );
}

function ResultSection({ loso }: { loso: ResearchLoso }) {
  const rows = RESULT_ORDER.map((key) => loso.rows.find((row) => row.key === key)).filter((row): row is ResearchRow => !!row);
  if (rows.length === 0) return null;
  return (
    <section className="band" aria-labelledby="result-title">
      <h2 id="result-title">The result</h2>
      <p className="band-note">Share of words wrong on speakers the model never heard. Lower is better.</p>
      <RateTable rows={rows} labelledBy="result-title" head="Which clips" ranges />
      <p className="rate-note">Small numbers show the likely range ({CONFIDENCE}% confidence).</p>
    </section>
  );
}

/** Words wrong, untuned beside trained. The trained column carries the emphasis. */
function RateTable({ rows, labelledBy, head, ranges = false }: { rows: ResearchRow[]; labelledBy: string; head: string; ranges?: boolean }) {
  const most = Math.max(...rows.flatMap((row) => [row.untuned.wer, row.tuned.wer]), 0.0001);
  return (
    <div className="rate-wrap">
      <table className="rate-table" aria-labelledby={labelledBy}>
        <thead>
          <tr>
            <th scope="col">{head}</th>
            <th scope="col" className="rate-clips">
              Clips
            </th>
            <th scope="col" className="rate-before">
              <Key kind="before" />
              Untuned
            </th>
            <th scope="col" className="rate-after">
              <Key kind="after" />
              Trained
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key}>
              <th scope="row">
                <span className="rate-label">{row.label}</span>
                <span className="rate-clips-inline">
                  {row.clips.toLocaleString()} clips
                </span>
                <Bars before={row.untuned.wer} after={row.tuned.wer} most={most} />
              </th>
              <td className="rate-clips num">{row.clips.toLocaleString()}</td>
              <td className="rate-before">
                <Rate rate={row.untuned} range={ranges} />
              </td>
              <td className="rate-after">
                <Rate rate={row.tuned} range={ranges} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Rate({ rate, range }: { rate: ResearchRate; range: boolean }) {
  return (
    <>
      <span className="rate-value num">{oneDecimal(rate.wer)}</span>
      {range && (
        <span className="rate-range">
          <span className="visually-hidden">likely between </span>
          {bare(rate.low)}
          <span aria-hidden="true">–</span>
          <span className="visually-hidden"> and </span>
          {bare(rate.high)}
        </span>
      )}
    </>
  );
}

function Key({ kind }: { kind: "before" | "after" }) {
  return <span className={`rate-key ${kind}`} aria-hidden="true" />;
}

/** Two thin bars on one scale. Decoration only: the numbers sit in their own cells. */
function Bars({ before, after, most }: { before: number; after: number; most: number }) {
  return (
    <span className="rate-bars" aria-hidden="true">
      <span className="rate-bar before">
        <span style={{ width: `${Math.min(100, (before / most) * 100)}%` }} />
      </span>
      <span className="rate-bar after">
        <span style={{ width: `${Math.min(100, (after / most) * 100)}%` }} />
      </span>
    </span>
  );
}

function SpeakersSection({ loso }: { loso: ResearchLoso }) {
  if (loso.perSpeaker.length === 0) return null;
  const speakers = [...loso.perSpeaker].sort((a, b) => a.speaker.localeCompare(b.speaker));
  const most = Math.max(...speakers.flatMap((s) => [s.untuned, s.tuned]), 0.0001);
  return (
    <section className="band" aria-labelledby="speakers-title">
      <h2 id="speakers-title">Speaker by speaker</h2>
      <p className="band-note">Each speaker was scored by a model that had never heard them.</p>
      <div className="rate-wrap narrow">
        <table className="rate-table" aria-labelledby="speakers-title">
          <thead>
            <tr>
              <th scope="col">Speaker</th>
              <th scope="col" className="rate-before">
                <Key kind="before" />
                Untuned
              </th>
              <th scope="col" className="rate-after">
                <Key kind="after" />
                Trained
              </th>
            </tr>
          </thead>
          <tbody>
            {speakers.map((s) => (
              <tr key={s.speaker}>
                <th scope="row">
                  <span className="rate-label">{s.speaker}</span>
                  <Bars before={s.untuned} after={s.tuned} most={most} />
                </th>
                <td className="rate-before">
                  <span className="rate-value num">{whole(s.untuned)}</span>
                </td>
                <td className="rate-after">
                  <span className="rate-value num">{whole(s.tuned)}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function MethodSection({ loso }: { loso: ResearchLoso }) {
  return (
    <section className="band" aria-labelledby="method-title">
      <h2 id="method-title">How it was tested</h2>
      <ol className="method-steps">
        <li>
          <strong>Train</strong>
          <span>on everyone except one speaker with dysarthria.</span>
        </li>
        <li>
          <strong>Test</strong>
          <span>on that speaker, whose voice the model has never heard.</span>
        </li>
        <li>
          <strong>Repeat</strong>
          <span>for all {say(loso.speakers)} speakers, and add up the results.</span>
        </li>
      </ol>
      <p className="method-data">
        The recordings are TORGO: {say(loso.speakers)} speakers with dysarthria and three without, reading words and sentences aloud. About two
        hours of training audio, including a second microphone.
      </p>
    </section>
  );
}

function EarlierSection({ rows }: { rows: ResearchRow[] }) {
  const shown = EARLIER_ROWS.flatMap(({ key, label }) => {
    const row = rows.find((r) => r.key === key);
    return row ? [{ ...row, label }] : [];
  });
  if (shown.length === 0) return null;
  return (
    <section className="band" aria-labelledby="earlier-title">
      <h2 id="earlier-title">When the model has heard the speaker</h2>
      <p className="band-note">The earlier, easier test: new words and sentences from speakers it trained on.</p>
      <RateTable rows={shown} labelledBy="earlier-title" head="Which clips" />
    </section>
  );
}

function LimitsSection({ results }: { results: ResearchResults }) {
  const speakers = results.loso?.speakers ?? results.perSpeaker.filter((s) => s.dysarthric).length;
  const newWords = results.loso?.rows.find((row) => row.key === "new-prompt");
  return (
    <section className="band" aria-labelledby="limits-title">
      <h2 id="limits-title">What this does not show</h2>
      <ul className="limits">
        <li>
          {capital(say(speakers))} speakers is far too few, and the most severe still have about half their words wrong.
        </li>
        {newWords && newWords.tuned.wer < newWords.untuned.wer && (
          <li>
            When the words are new too, the gain is smaller: from {whole(newWords.untuned.wer)} to {whole(newWords.tuned.wer)}.
          </li>
        )}
        <li>TORGO is people reading aloud, not everyday conversation.</li>
      </ul>
    </section>
  );
}

/* ───────────── The clip tester (local only) ───────────── */

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
      <p className="band-note">This model comes from the earlier test: it has heard these speakers, but never these words.</p>
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
