// "Set up your voice", hands-free. A phrase is shown large; the person reads it; when the turn
// ends the page moves on by itself. "Again", "skip" and "finish" work by voice as well as by
// button. Each clip is heard by the recognisers and kept, with the phrase, in this browser.

import { useEffect, useRef } from "react";
import type { HearerName } from "../../shared/pipeline";
import { SETUP_PHRASES, type EnrolResult } from "../model/enrolment";
import { HEARER_LABEL, HEARERS } from "../model/turn";
import { MicHelp } from "./MicHelp";

export interface EnrolmentState {
  open: boolean;
  index: number;
  /**
   * "idle": waiting for Record. "listening": recording this phrase (a turn now counts).
   * "hearing": the recognisers are on it. "heard" / "error": waiting for Re-record or Next.
   */
  status: "idle" | "listening" | "hearing" | "heard" | "error";
  result?: EnrolResult;
  error?: string;
  done: boolean[];
}

export const ENROLMENT_START: EnrolmentState = { open: false, index: 0, status: "idle", done: SETUP_PHRASES.map(() => false) };

/** What the phrase steps need: the setup state, the microphone, and the buttons. */
export interface EnrolmentBodyProps {
  state: EnrolmentState;
  liveText: string;
  listening: boolean;
  /** The listener's own state: "starting" while the browser is still opening the microphone. */
  micStatus: string;
  /** The page's latest notice, such as the browser refusing the microphone. Shown here because a dialog covers the page. */
  notice: string | null;
  micBlocked: boolean;
  /** The browser or the computer refused the microphone on the last try. */
  micRefused: boolean;
  micPermission: PermissionState | "unknown";
  /** Record (or Re-record) this phrase; opens the microphone if it is off. */
  onRecord: () => void;
  /** Stop: end the phrase now, or stop waiting for it. */
  onStop: () => void;
  /** Next phrase (also Skip). */
  onNext: () => void;
}

/** "Set up your voice" from the pipeline page, for the profile in use. */
export function Enrolment(props: EnrolmentBodyProps & { profileName: string; onClose: () => void; onCancel: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const { state } = props;

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (state.open && !element.open) element.showModal();
    if (!state.open && element.open) element.close();
  }, [state.open]);

  const finished = state.index >= SETUP_PHRASES.length;

  return (
    <dialog ref={dialog} className="enrol" aria-labelledby="enrol-title" onClose={props.onClose} onCancel={props.onClose}>
      <div className="enrol-head">
        <h2 id="enrol-title">
          Set up your voice <span className="enrol-profile">for &ldquo;{props.profileName}&rdquo;</span>
        </h2>
        <div className="enrol-head-actions">
          {!finished && (
            <button className="button small quiet" onClick={props.onCancel} disabled={state.status === "hearing"}>
              Cancel
            </button>
          )}
          <button className="button small" onClick={props.onClose}>
            {finished ? "Close" : "Keep and finish"}
          </button>
        </div>
      </div>
      <EnrolmentBody {...props} />
      {finished && (
        <p>
          Clips of your voice are kept in this browser under &ldquo;{props.profileName}&rdquo;. Gemini is shown a few of them with each turn, and
          every phrase a recogniser misheard is now in this profile&rsquo;s phrasebook.
        </p>
      )}
    </dialog>
  );
}

/** The phrase steps: progress, the phrase to read, the microphone, what was heard, again and skip. */
export function EnrolmentBody(props: EnrolmentBodyProps) {
  const { state } = props;
  const finished = state.index >= SETUP_PHRASES.length;
  const phrase = SETUP_PHRASES[Math.min(state.index, SETUP_PHRASES.length - 1)];
  const count = state.done.filter(Boolean).length;
  const recording = state.status === "listening" && props.listening;

  return (
    <>
      <ol className="enrol-progress" aria-label={`${count} of ${SETUP_PHRASES.length} phrases recorded`}>
        {SETUP_PHRASES.map((p, i) => (
          <li key={p} className={state.done[i] ? "done" : i === state.index ? "current" : ""} title={p} />
        ))}
      </ol>

      {finished ? (
        <div className="enrol-body" role="status">
          <p className="enrol-phrase">All set.</p>
          <p>
            {count} of {SETUP_PHRASES.length} phrases recorded.
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
            {recording
              ? props.liveText || "Listening… say the phrase."
              : props.micStatus === "starting"
                ? "Opening the microphone…"
                : state.status === "idle"
                  ? "Press Record, then say the phrase."
                  : ""}
          </p>
          {!props.listening && props.micRefused && <MicHelp permission={props.micPermission} onRetry={props.onRecord} />}
          {props.notice && (
            <p className="enrol-notice failure" role="alert">
              {props.notice}
            </p>
          )}
          <div className="enrol-status" role="status">
            {state.status === "hearing" && <p>Hearing it three ways…</p>}
            {state.status === "error" && <p className="failure">{state.error}</p>}
            {state.status === "heard" && state.result && <Heard result={state.result} />}
          </div>
          <div className="enrol-actions">
            {state.status === "hearing" ? (
              <button className="record-button" disabled>
                Hearing it…
              </button>
            ) : recording ? (
              <button className="record-button on" onClick={props.onStop}>
                <span className="record-dot" aria-hidden="true" /> Stop
              </button>
            ) : state.status === "heard" || state.status === "error" ? (
              <>
                <button className="button" onClick={props.onRecord}>
                  ↻ Re-record
                </button>
                <button className="button primary" onClick={props.onNext}>
                  Next →
                </button>
              </>
            ) : (
              <button className="record-button" onClick={props.onRecord} disabled={props.micBlocked || props.micStatus === "starting"}>
                <span className="record-dot" aria-hidden="true" /> Record
              </button>
            )}
            {state.status !== "heard" && state.status !== "error" && (
              <button className="button quiet" onClick={props.onNext}>
                Skip
              </button>
            )}
          </div>
          <p className="muted enrol-tip">Hands-free: say &ldquo;again&rdquo;, &ldquo;next&rdquo; or &ldquo;finish&rdquo;.</p>
        </div>
      )}
    </>
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
