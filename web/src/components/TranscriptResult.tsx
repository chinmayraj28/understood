// The answer for a recording: the pipeline's transcript in large type and, when what was really
// said is known, every word marked right or wrong, with the share of words wrong for each
// recogniser on its own and for the whole pipeline. Scored as the evaluation scored it.

import type { HearerName } from "../../shared/pipeline";
import { alignWords, countErrors, errorRate, type AlignedWord } from "../../shared/wordErrors";
import { bestText, HEARER_LABEL, hearersOf, type TurnModel } from "../model/turn";
import { seconds } from "./bits";

const pct = (value: number) => `${Math.round(value * 100)}%`;

export function TranscriptResult({ turn, pending }: { turn?: TurnModel; pending?: string }) {
  // A new recording has been chosen but has not reached the pipeline yet: show that, not the last result.
  if (pending) {
    return (
      <section className="transcript-result" aria-labelledby="result-title" aria-busy="true">
        <header className="result-head">
          <h2 id="result-title">What it heard</h2>
          <p className="muted">{pending}</p>
        </header>
        <p className="result-text placeholder">Listening…</p>
      </section>
    );
  }
  if (!turn || turn.origin !== "file" || !turn.recording) return null;
  const { recording } = turn;
  const done = turn.stage === "done";
  const text = done ? bestText(turn) : "";
  const reference = recording.reference;
  // Told to screen readers once the transcript is in. The region is on the page from the start
  // ("Hearing…"), so its text changing is announced. A failure is announced by the page's own
  // region (pageAnnouncement), so it is not repeated here.
  const count = done && !turn.failed && reference ? countErrors(reference, text) : null;
  const announcement =
    done && !turn.failed
      ? `Heard: ${text.replace(/[.!?…]+$/, "") || "nothing"}.${count ? (count.errors === 0 ? " Every word right." : ` ${count.errors} of ${count.referenceWords} words wrong.`) : ""}`
      : "";

  return (
    <section className="transcript-result" aria-labelledby="result-title" aria-busy={!done}>
      <header className="result-head">
        <h2 id="result-title">What it heard</h2>
        <p className="muted">
          {recording.label}, heard as {recording.voiceLabel}
          {recording.seen !== undefined && !recording.caveat && (recording.seen ? ". This phrase was among the voice’s set-up clips." : ". A phrase the voice was not set up with.")}
        </p>
      </header>

      <p className="visually-hidden" aria-live="polite">
        {announcement}
      </p>
      {!done ? (
        <p className="result-text placeholder">Hearing…</p>
      ) : turn.failed ? (
        <p className="result-text failed">{turn.failed}</p>
      ) : (
        <>
          <p className="result-text">
            {text ? <>&ldquo;{text}&rdquo;</> : <span className="muted">Nothing it could write down.</span>}
          </p>
          {reference && <Scored reference={reference} text={text} />}
          {recording.caveat && <p className="result-caveat">{recording.caveat}</p>}
          <HearerTable turn={turn} reference={reference} final={text} />
        </>
      )}
    </section>
  );
}

function Scored({ reference, text }: { reference: string; text: string }) {
  const count = countErrors(reference, text);
  const rate = errorRate(count);
  const aligned = alignWords(reference, text);
  return (
    <div className="scored">
      <p className="scored-line">
        <span className={`score-badge${count.errors === 0 ? " perfect" : rate > 0.5 ? " poor" : ""}`}>
          {count.errors === 0 ? "Every word right" : `${count.errors} of ${count.referenceWords} ${count.referenceWords === 1 ? "word" : "words"} wrong (${pct(rate)})`}
        </span>
        <span className="muted"> What was said: &ldquo;{reference}&rdquo;</span>
      </p>
      {count.errors > 0 && (
        <p className="aligned">
          <span className="visually-hidden">Word by word: </span>
          {aligned.map((w, i) => (
            <Word key={i} word={w} />
          ))}
        </p>
      )}
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
          <ins>{word.heard}</ins>{" "}
        </span>
      );
    case "del":
      return (
        <span className="w del">
          <del>{word.word}</del>{" "}
          <span className="visually-hidden">(missed)</span>
        </span>
      );
    case "ins":
      return (
        <span className="w ins">
          <ins>{word.heard}</ins>{" "}
          <span className="visually-hidden">(added)</span>
        </span>
      );
  }
}

function HearerTable({ turn, reference, final }: { turn: TurnModel; reference?: string; final: string }) {
  // A recogniser that heard nothing or ran out of time scores as if it wrote nothing, as in the
  // evaluation; one that was not used for this turn is not scored.
  const rows: { name: string; text?: string; scored?: string; failure?: string; time?: number; hearer?: HearerName }[] = hearersOf(turn).map((h) => {
    const lane = turn.lanes[h];
    const used = lane.status === "done" || lane.status === "failed";
    return {
      name: HEARER_LABEL[h] === "Live" ? "Live (realtime)" : HEARER_LABEL[h],
      hearer: h,
      text: lane.status === "done" ? lane.text : undefined,
      scored: used ? (lane.status === "done" ? (lane.text ?? "") : "") : undefined,
      failure: lane.failure ?? (used ? undefined : "not used"),
      time: lane.seconds,
    };
  });
  return (
    <div className="table-wrap" role="region" aria-label="Each recogniser on its own" tabIndex={0}>
      <table className="result-table">
        <thead>
          <tr>
            <th scope="col">Heard by</th>
            <th scope="col">Text</th>
            {reference && <th scope="col">Words wrong</th>}
            <th scope="col">Time</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.name}>
              <th scope="row">
                {r.hearer && <span className={`hearer-dot dot-${r.hearer}`} aria-hidden="true" />} {r.name}
              </th>
              <td className="cell-text">{r.text ? <>&ldquo;{r.text}&rdquo;</> : <span className="muted">{r.failure ?? "nothing"}</span>}</td>
              {reference && (
                <td className="num cell-wer">
                  {r.scored !== undefined ? pct(errorRate(countErrors(reference, r.scored))) : "–"}
                  <span className="cell-unit"> wrong</span>
                </td>
              )}
              <td className="num cell-time">{r.hearer === "realtime" ? "while playing" : seconds(r.time)}</td>
            </tr>
          ))}
          <tr className="final-row">
            <th scope="row">The pipeline</th>
            <td className="cell-text">{final ? <>&ldquo;{final}&rdquo;</> : <span className="muted">nothing</span>}</td>
            {reference && (
              <td className="num cell-wer">
                {pct(errorRate(countErrors(reference, final)))}
                <span className="cell-unit"> wrong</span>
              </td>
            )}
            <td className="num cell-time">{seconds(turn.totalSeconds)}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}
