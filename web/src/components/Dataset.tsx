// The dataset view: every TORGO recording on this computer, playable, with what the evaluation's
// pipeline heard for the clips it tested. The audio is read from the person's own disk by the
// local server; it is never part of the page or the repo (TORGO may not be redistributed).

import { useEffect, useMemo, useRef, useState, type SyntheticEvent } from "react";
import type { DatasetClip, DatasetIndex, DatasetResult } from "../../shared/dataset";
import { clipAudioUrl } from "../../shared/dataset";
import { loadDataset, type DatasetLoad } from "../model/datasetLoader";
import {
  decisionWords,
  filterClips,
  hearerName,
  matchesPrompt,
  NO_FILTER,
  orderSpeakers,
  PAGE_SIZE,
  secondsLabel,
  setupName,
  speakerDescription,
  type DatasetFilter,
} from "../model/dataset";

type Load = { status: "loading" } | DatasetLoad;

export function Dataset() {
  const [load, setLoad] = useState<Load>({ status: "loading" });
  const [filter, setFilter] = useState<DatasetFilter>(NO_FILTER);
  const [shown, setShown] = useState(PAGE_SIZE);
  const heading = useRef<HTMLHeadingElement>(null);

  // Opening the view moves focus to its heading, so a screen reader starts here.
  useEffect(() => heading.current?.focus(), []);

  useEffect(() => {
    let gone = false;
    void loadDataset().then((result) => {
      if (!gone) setLoad(result);
    });
    return () => {
      gone = true;
    };
  }, []);

  const update = (change: Partial<DatasetFilter>) => {
    setFilter((f) => ({ ...f, ...change }));
    setShown(PAGE_SIZE);
  };

  return (
    <section className="dataset" aria-labelledby="dataset-title">
      <div className="dataset-head">
        <h1 id="dataset-title" tabIndex={-1} ref={heading}>
          The recordings
        </h1>
        <p>
          Every clip from TORGO on this computer: people with dysarthria from cerebral palsy, and speakers without it for comparison. Play
          any clip. For the clips the evaluation tested, open it to see what each recogniser heard, Claude&rsquo;s reading, and what the
          pipeline decided.
        </p>
        <p className="dataset-licence">
          TORGO (University of Toronto and Holland Bloorview, Rudzicz, Namasivayam and Wolff, 2012) is free for academic, non-profit
          use. The audio is played from your own disk and is never uploaded or published.
        </p>
      </div>

      {load.status === "loading" && <p className="muted">Loading the list of recordings…</p>}
      {load.status === "failed" && <p role="alert">The list of recordings couldn&rsquo;t be loaded. Is the server running?</p>}
      {load.status === "missing" && (
        <div className="dataset-missing" role="status">
          <p>{load.reason}</p>
        </div>
      )}
      {load.status === "ready" && <Browser index={load.index} filter={filter} onFilter={update} shown={shown} onMore={() => setShown((n) => n + PAGE_SIZE)} />}
    </section>
  );
}

function Browser(props: { index: DatasetIndex; filter: DatasetFilter; onFilter: (c: Partial<DatasetFilter>) => void; shown: number; onMore: () => void }) {
  const { index, filter, onFilter, shown } = props;
  const speakers = useMemo(() => orderSpeakers(index.speakers), [index.speakers]);
  const byId = useMemo(() => new Map(index.speakers.map((s) => [s.id, s])), [index.speakers]);
  const clips = useMemo(() => filterClips(index, filter), [index, filter]);
  const evaluated = Object.keys(index.results).length;
  const countText =
    clips.length === 0 ? "No clips match." : `Showing ${Math.min(shown, clips.length).toLocaleString()} of ${clips.length.toLocaleString()} clips.`;

  // Screen readers hear the count once typing pauses, not on every key.
  const [announced, setAnnounced] = useState("");
  useEffect(() => {
    const timer = setTimeout(() => setAnnounced(countText), 700);
    return () => clearTimeout(timer);
  }, [countText]);

  return (
    <>
      <div className="dataset-speakers" role="group" aria-label="Choose a speaker">
        <button className="speaker-chip" aria-pressed={filter.speaker === "all"} onClick={() => onFilter({ speaker: "all" })}>
          <strong>Everyone</strong>
          <span>{index.clips.length.toLocaleString()} clips</span>
        </button>
        {speakers.map((s) => (
          <button
            key={s.id}
            className={`speaker-chip${s.group === "dysarthric" ? "" : " control"}`}
            aria-pressed={filter.speaker === s.id}
            onClick={() => onFilter({ speaker: s.id })}
          >
            <strong>{s.id}</strong>
            <span>{s.group === "dysarthric" ? s.severity : "comparison"}</span>
            <span>{s.clipCount.toLocaleString()} clips</span>
          </button>
        ))}
      </div>

      <div className="dataset-filters">
        <label>
          <span>Search</span>
          <input type="search" value={filter.query} placeholder="A word or sentence" onChange={(e) => onFilter({ query: e.target.value })} />
        </label>
        <label>
          <span>Kind</span>
          <select value={filter.kind} onChange={(e) => onFilter({ kind: e.target.value as DatasetFilter["kind"] })}>
            <option value="all">Words and sentences</option>
            <option value="word">Single words</option>
            <option value="sentence">Sentences</option>
          </select>
        </label>
        <label>
          <span>Used for</span>
          <select value={filter.split} onChange={(e) => onFilter({ split: e.target.value as DatasetFilter["split"] })}>
            <option value="all">Set-up and test</option>
            <option value="enrolment">Setting the speaker up</option>
            <option value="test">Testing</option>
          </select>
        </label>
        <label className="check">
          <input type="checkbox" checked={filter.evaluatedOnly} onChange={(e) => onFilter({ evaluatedOnly: e.target.checked })} />
          <span>Only the {evaluated} clips the evaluation tested</span>
        </label>
      </div>

      <p className="dataset-count">{countText}</p>
      <p className="visually-hidden" aria-live="polite">
        {announced}
      </p>

      <ul className="clip-list">
        {clips.slice(0, shown).map((clip) => (
          <ClipRow key={clip.id} clip={clip} speaker={speakerDescription(byId.get(clip.speaker))} results={index.results[clip.id]} />
        ))}
      </ul>

      {shown < clips.length && (
        <button className="button quiet" onClick={props.onMore}>
          Show {Math.min(PAGE_SIZE, clips.length - shown)} more
        </button>
      )}
    </>
  );
}

/** Only one clip plays at a time. */
function pauseOthers(event: SyntheticEvent<HTMLAudioElement>) {
  document.querySelectorAll("audio").forEach((audio) => {
    if (audio !== event.currentTarget) audio.pause();
  });
}

function ClipRow({ clip, speaker, results }: { clip: DatasetClip; speaker: string; results?: DatasetResult[] }) {
  const full = results?.find((r) => r.setup === "phrasebook");
  const alone = results?.find((r) => r.setup === "scribe");
  return (
    <li className="clip">
      <div className="clip-main">
        <p className={`clip-prompt${clip.kind === "sentence" ? " sentence" : ""}`}>&ldquo;{clip.prompt}&rdquo;</p>
        <p className="clip-meta">
          <span>{clip.speaker}</span>
          <span>{speaker}</span>
          <span>{clip.kind === "sentence" ? "sentence" : "word"}</span>
          <span>{secondsLabel(clip.seconds)}</span>
          <span>{clip.split === "test" ? "test" : "set-up"}</span>
          {full && <span className="clip-tested">tested</span>}
        </p>
      </div>
      <audio
        className="clip-audio"
        controls
        preload="none"
        src={clipAudioUrl(clip.id)}
        onPlay={pauseOthers}
        aria-label={`${clip.speaker} saying “${clip.prompt}”`}
      />
      <a className="button small quiet clip-hear" href={`#hear=${encodeURIComponent(clip.id)}`}>
        Hear it in the pipeline<span className="visually-hidden">: {clip.speaker} saying &ldquo;{clip.prompt}&rdquo;</span>
      </a>
      {full && (
        <details className="clip-result">
          <summary>
            What the pipeline heard: <strong>{decisionWords(full.decision)}</strong>
            {full.finalText && (
              <>
                {" "}
                &ldquo;{full.finalText}&rdquo; {matchesPrompt(full, clip.prompt) ? <span className="ok">matches the prompt</span> : <span className="off">differs from the prompt</span>}
              </>
            )}
          </summary>
          <ResultDetail result={full} />
          {alone && (
            <p className="clip-alone">
              {setupName("scribe")}: {alone.heard[0]?.text ? <>heard &ldquo;{alone.heard[0].text}&rdquo;</> : "heard nothing"}, and{" "}
              {decisionWords(alone.decision).toLowerCase()}.
            </p>
          )}
          {full.promptSeen && <p className="muted">This prompt was among the speaker&rsquo;s set-up clips.</p>}
        </details>
      )}
    </li>
  );
}

function ResultDetail({ result }: { result: DatasetResult }) {
  return (
    <dl className="clip-detail">
      {result.heard.map((h) => (
        <div key={h.hearer}>
          <dt>{hearerName(h.hearer)}</dt>
          <dd>
            {h.failure ? <span className="muted">{h.failure}</span> : <>&ldquo;{h.text}&rdquo;</>} <span className="muted">{secondsLabel(h.seconds)}</span>
          </dd>
        </div>
      ))}
      {result.phrasebook && (
        <div>
          <dt>Phrasebook</dt>
          <dd>
            heard &ldquo;{result.phrasebook.heard}&rdquo; before, meant &ldquo;{result.phrasebook.meant}&rdquo; (confirmed {result.phrasebook.timesConfirmed}{" "}
            {result.phrasebook.timesConfirmed === 1 ? "time" : "times"})
          </dd>
        </div>
      )}
      {result.reading && (
        <div>
          <dt>Claude</dt>
          <dd>
            &ldquo;{result.reading.text}&rdquo;, {result.reading.confidence} confidence. <span className="muted">{result.reading.reason}</span>
          </dd>
        </div>
      )}
      <div>
        <dt>Decision</dt>
        <dd>
          {decisionWords(result.decision)} <span className="muted">after {secondsLabel(result.seconds)}</span>
        </dd>
      </div>
    </dl>
  );
}
