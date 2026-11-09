// The evaluation: what each stage adds, measured on real recordings of people with dysarthria.
// Results are read from /eval/results.json (written by the evaluation run). Evaluation turns
// can be replayed through the pipeline view: text and timings only, never the audio.

import { useEffect, useState } from "react";
import type { PipelineEvent } from "../../shared/pipeline";

export interface EvalSetup {
  id: string;
  name: string;
  wordErrorRate: number;
  meaningSuccess: number;
  wrongActionRate: number;
  askRate: number;
  medianSeconds: number;
  n: number;
}

export interface EvalReplay {
  id: string;
  speaker: string;
  setup: string;
  intended: string;
  speechSeconds: number;
  events: PipelineEvent[];
}

export interface EvalResults {
  placeholder?: boolean;
  title?: string;
  dataset: string;
  speakers: number;
  utterances: number;
  setups: EvalSetup[];
  replays: EvalReplay[];
}

const pct = (v: number) => `${Math.round(v * 100)}%`;

export function Evaluation({ onReplay }: { onReplay: (replay: EvalReplay) => void }) {
  const [results, setResults] = useState<EvalResults | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    fetch("/eval/results.json")
      .then((r) => (r.ok ? (r.json() as Promise<EvalResults>) : Promise.reject(new Error(String(r.status)))))
      .then(setResults)
      .catch(() => setFailed(true));
  }, []);

  if (failed) return <p className="muted">The evaluation results could not be loaded.</p>;
  if (!results) return <p className="muted">Loading the evaluation…</p>;

  const best = Math.max(...results.setups.map((s) => s.meaningSuccess));
  return (
    <div className="eval">
      {results.placeholder && (
        <p className="placeholder-banner" role="note">
          {results.title ?? "PLACEHOLDER numbers"}
        </p>
      )}
      <p className="eval-dataset">
        {results.dataset} {results.speakers > 0 && `${results.speakers} speakers, ${results.utterances} recordings.`}
      </p>
      <div className="table-wrap" role="region" aria-label="Results per setup" tabIndex={0}>
        <table className="eval-table">
          <thead>
            <tr>
              <th scope="col">Setup, each adding to the one above</th>
              <th scope="col">Meaning right</th>
              <th scope="col">Words wrong</th>
              <th scope="col">Acted wrongly</th>
              <th scope="col">Asked first</th>
              <th scope="col">Median time</th>
            </tr>
          </thead>
          <tbody>
            {results.setups.map((s) => (
              <tr key={s.id} className={s.meaningSuccess === best ? "best" : ""}>
                <th scope="row">{s.name}</th>
                <td>
                  <span className="cell-bar">
                    <span className="num">{pct(s.meaningSuccess)}</span>
                    <span className="bar" aria-hidden="true">
                      <span style={{ width: pct(s.meaningSuccess) }} />
                    </span>
                  </span>
                </td>
                <td className="num">{pct(s.wordErrorRate)}</td>
                <td className={`num${s.wrongActionRate > 0.05 ? " warn" : ""}`}>{pct(s.wrongActionRate)}</td>
                <td className="num">{pct(s.askRate)}</td>
                <td className="num">{s.medianSeconds.toFixed(1)} s</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="eval-key muted">
        Meaning right: the reading would have led to the action the speaker meant. Acted wrongly: it went ahead without asking and was
        wrong, the number that must stay near zero. Asked first: it asked one short question instead of acting.
      </p>

      {results.replays.length > 0 && (
        <>
          <h3 className="eval-replays-title">Replay an evaluation turn</h3>
          <ul className="eval-replays">
            {results.replays.map((r) => (
              <li key={r.id}>
                <button className="replay-card" onClick={() => onReplay(r)}>
                  <span className="replay-title">&ldquo;{r.intended}&rdquo;</span>
                  <span className="replay-summary">
                    {r.speaker}. Text and timings only, no audio.
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
