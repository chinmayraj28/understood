// The evaluation: what each stage adds to the transcript, measured on real recordings of people
// with dysarthria (TORGO). Read from /eval/results.json, written by scripts/exportEval.ts from
// the evaluation run. Numbers only: no audio and no transcripts are published. Shown on the
// landing page as a chart, with the full table a click away.

import { useEffect, useState } from "react";

export interface EvalSetup {
  id: string;
  name: string;
  n: number;
  wordErrorRate: number;
  seenWordErrorRate: number | null;
  unseenWordErrorRate: number | null;
  dysarthricWordErrorRate: number | null;
  exactMatchRate: number;
  correctActionRate: number;
  wrongActionRate: number;
  askRate: number;
  meanSeconds: number;
}

export interface EvalResults {
  title: string;
  dataset: string;
  note: string;
  date: string;
  speakers: number;
  utterances: number;
  setups: EvalSetup[];
}

const pct = (v: number | null) => (v === null ? "–" : `${Math.round(v * 100)}%`);

/** Loads /eval/results.json once. */
export function useEvalResults(): { data: EvalResults | null; failed: boolean } {
  const [data, setData] = useState<EvalResults | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    fetch("/eval/results.json")
      .then((r) => (r.ok ? (r.json() as Promise<EvalResults>) : Promise.reject(new Error(String(r.status)))))
      .then(setData)
      .catch(() => setFailed(true));
  }, []);
  return { data, failed };
}

/** Words wrong per setup, as bars: each stage added to the one above. */
export function WordsWrongChart({ setups }: { setups: EvalSetup[] }) {
  const most = Math.max(...setups.map((s) => s.wordErrorRate), 0.01);
  const best = Math.min(...setups.map((s) => s.wordErrorRate));
  return (
    <figure className="ww-chart">
      <figcaption className="ww-caption">Share of words wrong, each stage added to the one above (lower is better)</figcaption>
      <ul>
        {setups.map((s) => (
          <li key={s.id} className={s.wordErrorRate === best ? "best" : ""}>
            <span className="ww-name">{s.name}</span>
            <span className="ww-bar" aria-hidden="true">
              <span style={{ width: `${(s.wordErrorRate / most) * 100}%` }} />
            </span>
            <span className="ww-value num">{pct(s.wordErrorRate)}</span>
          </li>
        ))}
      </ul>
    </figure>
  );
}

export function EvaluationTable({ results }: { results: EvalResults }) {
  const best = Math.min(...results.setups.map((s) => s.wordErrorRate));
  return (
    <div className="eval">
      <p className="eval-dataset">{results.dataset}</p>
      <div className="table-wrap" role="region" aria-label="Results per setup" tabIndex={0}>
        <table className="eval-table">
          <thead>
            <tr>
              <th scope="col">Setup, each adding to the one above</th>
              <th scope="col">Words wrong</th>
              <th scope="col">On phrases said before</th>
              <th scope="col">On new phrases</th>
              <th scope="col">Exactly right</th>
              <th scope="col">Acted wrongly</th>
              <th scope="col">Mean time</th>
            </tr>
          </thead>
          <tbody>
            {results.setups.map((s) => (
              <tr key={s.id} className={s.wordErrorRate === best ? "best" : ""}>
                <th scope="row">{s.name}</th>
                <td className="num">{pct(s.wordErrorRate)}</td>
                <td className="num">{pct(s.seenWordErrorRate)}</td>
                <td className="num">{pct(s.unseenWordErrorRate)}</td>
                <td className="num">{pct(s.exactMatchRate)}</td>
                <td className={`num${s.wrongActionRate > 0.05 ? " warn" : ""}`}>{pct(s.wrongActionRate)}</td>
                <td className="num">{s.meanSeconds.toFixed(1)} s</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="eval-key muted">
        Words wrong: the share of the words said that the transcript missed, swapped or added. Phrases said before: the speaker had also
        said that phrase in their set-up clips. Exactly right: every word matches. Acted wrongly: the decider went ahead without asking and
        was wrong, the number that must stay near zero. {results.note}
      </p>
    </div>
  );
}
