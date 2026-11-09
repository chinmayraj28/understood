// "Set up your voice", hands-free. A phrase is shown large; the person reads it; when the turn
// ends the page moves on by itself. "Again", "skip" and "finish" work by voice as well as by
// button. Each clip is heard by the recognisers and kept, with the phrase, in this browser.

import { useEffect, useRef } from "react";
import type { HearerName } from "../../shared/pipeline";
import { SETUP_PHRASES, type EnrolResult } from "../model/enrolment";
import { HEARER_LABEL, HEARERS } from "../model/turn";

export interface EnrolmentState {
  open: boolean;
  index: number;
  status: "listening" | "hearing" | "heard" | "error";
  result?: EnrolResult;
  error?: string;
  done: boolean[];
}

export const ENROLMENT_START: EnrolmentState = { open: false, index: 0, status: "listening", done: SETUP_PHRASES.map(() => false) };

export function Enrolment(props: {
  state: EnrolmentState;
  liveText: string;
  listening: boolean;
  onAgain: () => void;
  onSkip: () => void;
  onClose: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const { state } = props;

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (state.open && !element.open) element.showModal();
    if (!state.open && element.open) element.close();
  }, [state.open]);

  const finished = state.index >= SETUP_PHRASES.length;
  const phrase = SETUP_PHRASES[Math.min(state.index, SETUP_PHRASES.length - 1)];
  const count = state.done.filter(Boolean).length;

  return (
    <dialog ref={dialog} className="enrol" aria-labelledby="enrol-title" onClose={props.onClose} onCancel={props.onClose}>
      <div className="enrol-head">
        <h2 id="enrol-title">Set up your voice</h2>
        <button className="button small quiet" onClick={props.onClose}>
          {finished ? "Close" : "Finish for now"}
        </button>
      </div>
      <ol className="enrol-progress" aria-label={`${count} of ${SETUP_PHRASES.length} phrases recorded`}>
        {SETUP_PHRASES.map((p, i) => (
          <li key={p} className={state.done[i] ? "done" : i === state.index ? "current" : ""} title={p} />
        ))}
      </ol>

      {finished ? (
        <div className="enrol-body" role="status">
          <p className="enrol-phrase">All set.</p>
          <p>
            {count} clips of your voice are kept in this browser. Gemini is shown a few of them with each turn, and every phrase a
            recogniser misheard is now in your phrasebook.
          </p>
        </div>
      ) : (
        <div className="enrol-body">
          <p className="enrol-step">
            Phrase <span className="num">{state.index + 1}</span> of <span className="num">{SETUP_PHRASES.length}</span>. Say it in your
            own time.
          </p>
          <p className="enrol-phrase" aria-live="polite">
            {phrase}
          </p>
          <p className="enrol-live" aria-hidden="true">
            {props.liveText || (props.listening ? "Listening…" : "The microphone is off. Start listening to record.")}
          </p>
          <div className="enrol-status" role="status">
            {state.status === "hearing" && <p>Hearing it three ways…</p>}
            {state.status === "error" && <p className="failure">{state.error}</p>}
            {state.status === "heard" && state.result && <Heard result={state.result} />}
          </div>
          <div className="enrol-actions">
            <button className="button" onClick={props.onAgain}>
              Say it again
            </button>
            <button className="button quiet" onClick={props.onSkip}>
              Skip
            </button>
            <p className="muted enrol-tip">Or say &ldquo;again&rdquo;, &ldquo;skip&rdquo; or &ldquo;finish&rdquo;.</p>
          </div>
        </div>
      )}
    </dialog>
  );
}

function Heard({ result }: { result: EnrolResult }) {
  return (
    <div className="enrol-heard">
      <ul>
        {HEARERS.filter((h) => result.heard[h] !== undefined || result.failures[h]).map((h: HearerName) => (
          <li key={h}>
            <span className={`hearer-dot dot-${h}`} aria-hidden="true" /> {HEARER_LABEL[h]}:{" "}
            {result.failures[h] ? <span className="failure">{result.failures[h]}</span> : <q>{result.heard[h]}</q>}
          </li>
        ))}
      </ul>
      <p>{result.learned === 0 ? "Every recogniser got it right." : `${result.learned} new ${result.learned === 1 ? "entry" : "entries"} in your phrasebook.`}</p>
    </div>
  );
}
