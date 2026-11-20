// The recordings page: a card for each TORGO speaker, and a page per speaker with every recording
// of theirs on this computer, playable, with what the evaluation's pipeline heard for the clips it tested. The audio is read from the person's own disk by the
// local server; it is never part of the page or the repo (TORGO may not be redistributed).

import { useEffect, useMemo, useRef, useState, type SyntheticEvent } from "react";
import type { DatasetClip, DatasetIndex, DatasetResult, DatasetSpeaker } from "../../shared/dataset";
import { clipAudioUrl } from "../../shared/dataset";
import { loadDataset, type DatasetLoad } from "../model/datasetLoader";
import { href } from "../router";
import {
  decisionWords,
  filterClips,
  hearerName,
  matchesPrompt,
  NO_FILTER,
  orderSpeakers,
  PAGE_SIZE,
  pickRandomClip,
  secondsLabel,
  setupName,
  speakerDescription,
  type DatasetFilter,
} from "../model/dataset";

type Load = { status: "loading" } | DatasetLoad;

/**
 * The recordings page. Without a speaker: a card for each TORGO speaker. With one
 * (#/recordings/F01): every recording of that person, playable, with what the evaluation's
 * pipeline heard for the clips it tested.
 */
export function Dataset({ speaker }: { speaker?: string }) {
  const [load, setLoad] = useState<Load>({ status: "loading" });
  const heading = useRef<HTMLHeadingElement>(null);

  // Opening the page, or another speaker, moves focus to its heading, so a screen reader starts there.
  useEffect(() => {
    window.scrollTo({ top: 0 });
    heading.current?.focus({ preventScroll: true });
  }, [speaker]);

  useEffect(() => {
    let gone = false;
    void loadDataset().then((result) => {
      if (!gone) setLoad(result);
    });
    return () => {
      gone = true;
    };
  }, []);

  const person = load.status === "ready" && speaker ? load.index.speakers.find((s) => s.id === speaker) : undefined;

  return (
    <section className="dataset" aria-labelledby="dataset-title">
      {speaker ? (
        <div className="dataset-head">
          <a className="back-link" href={href.recordings}>
            ← All speakers
          </a>
          <h1 id="dataset-title" tabIndex={-1} ref={heading}>
            {speaker}
          </h1>
          {person && (
            <p className="speaker-line">
              <span className={`group-badge${person.group === "dysarthric" ? "" : " control"}`}>{person.group === "dysarthric" ? "Dysarthria" : "Comparison"}</span>
              {speakerDescription(person)}
            </p>
          )}
        </div>
      ) : (
        <div className="dataset-head">
          <h1 id="dataset-title" tabIndex={-1} ref={heading}>
            Recordings
          </h1>
          <p>
            The people in TORGO: speakers with dysarthria from cerebral palsy, and speakers without it for comparison. Open a person to
            play their recordings and hear any of them in the pipeline.
          </p>
          <p className="dataset-licence">
            TORGO (University of Toronto and Holland Bloorview, Rudzicz, Namasivayam and Wolff, 2012) is free for academic, non-profit
            use. The audio is played from your own disk and is never uploaded or published.
          </p>
        </div>
      )}

      {load.status === "loading" && <p className="muted">Loading the recordings…</p>}
      {load.status === "failed" && <p role="alert">The recordings couldn&rsquo;t be loaded. Is the server running?</p>}
      {load.status === "missing" && (
        <div className="dataset-missing" role="status">
          <p>{load.reason}</p>
        </div>
      )}
      {load.status === "ready" &&
        (!speaker ? (
          <SpeakerCards index={load.index} />
        ) : person ? (
          <SpeakerRecordings key={speaker} index={load.index} speaker={person} />
        ) : (
          <p role="alert">
            There is no speaker {speaker} in this copy of TORGO. <a href={href.recordings}>See all speakers</a>.
          </p>
        ))}
    </section>
  );
}

/** A card per speaker, most severe dysarthria first, then the comparison speakers. */
function SpeakerCards({ index }: { index: DatasetIndex }) {
  const speakers = useMemo(() => orderSpeakers(index.speakers), [index.speakers]);
  const kinds = useMemo(() => {
    const counts = new Map<string, { words: number; sentences: number }>();
    for (const c of index.clips) {
      const n = counts.get(c.speaker) ?? { words: 0, sentences: 0 };
      if (c.kind === "sentence") n.sentences += 1;
      else n.words += 1;
      counts.set(c.speaker, n);
    }
    return counts;
  }, [index.clips]);

  return (
    <ul className="speaker-cards">
      {speakers.map((s) => {
        const n = kinds.get(s.id) ?? { words: 0, sentences: 0 };
        return (
          <li key={s.id}>
            <a className={`speaker-card${s.group === "dysarthric" ? "" : " control"}`} href={href.speaker(s.id)}>
              <span className="speaker-card-top">
                <span className="speaker-card-id">{s.id}</span>
                <span className={`group-badge${s.group === "dysarthric" ? "" : " control"}`}>{s.group === "dysarthric" ? "Dysarthria" : "Comparison"}</span>
              </span>
              <span className="speaker-card-what">{s.group === "dysarthric" ? speakerDescription(s) : "No dysarthria"}</span>
              <span className="speaker-card-count num">
                {(n.words + n.sentences).toLocaleString()} recordings · {n.words.toLocaleString()} words · {n.sentences.toLocaleString()} sentences
              </span>
            </a>
          </li>
        );
      })}
    </ul>
  );
}

/** One person's recordings: search, words or sentences, and the list. */
function SpeakerRecordings({ index, speaker }: { index: DatasetIndex; speaker: DatasetSpeaker }) {
  const [filter, setFilter] = useState<DatasetFilter>({ ...NO_FILTER, speaker: speaker.id });
  const [shown, setShown] = useState(PAGE_SIZE);
  const clips = useMemo(() => filterClips(index, filter), [index, filter]);
  const evaluated = useMemo(() => index.clips.filter((c) => c.speaker === speaker.id && index.results[c.id]?.length).length, [index, speaker.id]);
  const description = speakerDescription(speaker);
  const update = (change: Partial<DatasetFilter>) => {
    setFilter((f) => ({ ...f, ...change }));
    setShown(PAGE_SIZE);
  };
  const hearRandom = () => {
    const clip = pickRandomClip(clips);
    if (clip) window.location.hash = href.hear(clip.id);
  };
  const countText =
    clips.length === 0 ? "No recordings match." : `Showing ${Math.min(shown, clips.length).toLocaleString()} of ${clips.length.toLocaleString()} recordings.`;

  // Screen readers hear the count once typing pauses, not on every key.
  const [announced, setAnnounced] = useState("");
  useEffect(() => {
    const timer = setTimeout(() => setAnnounced(countText), 700);
    return () => clearTimeout(timer);
  }, [countText]);

  return (
    <>
      <div className="dataset-filters">
        <label>
          <span>Search</span>
          <input type="search" value={filter.query} placeholder="A word or sentence" onChange={(e) => update({ query: e.target.value })} />
        </label>
        <label>
          <span>Kind</span>
          <select value={filter.kind} onChange={(e) => update({ kind: e.target.value as DatasetFilter["kind"] })}>
            <option value="all">Words and sentences</option>
            <option value="word">Single words</option>
            <option value="sentence">Sentences</option>
          </select>
        </label>
        {evaluated > 0 && (
          <label className="check">
            <input type="checkbox" checked={filter.evaluatedOnly} onChange={(e) => update({ evaluatedOnly: e.target.checked })} />
            <span>Only the {evaluated} with evaluation results</span>
          </label>
        )}
        <button className="button" onClick={hearRandom} disabled={clips.length === 0}>
          Hear a random one in the pipeline
        </button>
      </div>

      <p className="dataset-count">{countText}</p>
      <p className="visually-hidden" aria-live="polite">
        {announced}
      </p>

      <ul className="clip-list">
        {clips.slice(0, shown).map((clip) => (
          <ClipRow key={clip.id} clip={clip} speaker={description} results={index.results[clip.id]} />
        ))}
      </ul>

      {shown < clips.length && (
        <button className="button quiet" onClick={() => setShown((n) => n + PAGE_SIZE)}>
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

function ClipRow({ clip, results }: { clip: DatasetClip; speaker: string; results?: DatasetResult[] }) {
  const full = results?.find((r) => r.setup === "phrasebook");
  const alone = results?.find((r) => r.setup === "scribe");
  return (
    <li className="clip">
      <div className="clip-main">
        <p className={`clip-prompt${clip.kind === "sentence" ? " sentence" : ""}`}>&ldquo;{clip.prompt}&rdquo;</p>
        <p className="clip-meta">
          <span>{clip.kind === "sentence" ? "sentence" : "word"}</span>
          <span>{secondsLabel(clip.seconds)}</span>
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
      <a className="button small quiet clip-hear" href={href.hear(clip.id)}>
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
