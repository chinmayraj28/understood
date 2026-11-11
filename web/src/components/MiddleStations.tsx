// The phrasebook check and Claude's repair.
//
// The phrasebook card turns over when something you confirmed before matches what was heard.
// Claude's reading comes with a confidence and one plain sentence on why. It is shown, never
// spoken, and it does not decide anything: the decision is made in code at the next station.

import type { TurnModel } from "../model/turn";
import { ConfidenceMeter, Stopwatch } from "./bits";
import { Station, type StationState } from "./Pipeline";

export function PhrasebookStation({ state, turn, entryCount }: { state: StationState; turn?: TurnModel; entryCount: number }) {
  const off = turn && !turn.switches.phrasebook;
  const match = turn?.match;
  const flipped = Boolean(match);
  return (
    <Station
      state={state}
      variant="phrasebook"
      title={turn?.origin === "file" ? "The phrasebook" : "Your phrasebook"}
      note={
        turn?.origin === "file"
          ? "Mishearings learned from this voice's set-up clips (or yours, kept only in this browser)."
          : "Mishearings you confirmed before, kept only in this browser."
      }
      aside={<span className="chip">{entryCount === 1 ? "1 entry" : `${entryCount} entries`}</span>}
    >
      <div className={`flip${flipped ? " flipped" : ""}`}>
        <div className="flip-inner">
          <div className="flip-face flip-front" aria-hidden={flipped}>
            {off ? (
              <p>Switched off for this turn.</p>
            ) : !turn?.phrasebookChecked ? (
              <p className="muted">{turn ? "Checking…" : "When a recogniser mishears you the same way twice, this is where it gets caught."}</p>
            ) : (
              <p>Nothing you confirmed before sounds like this.</p>
            )}
          </div>
          <div className="flip-face flip-back" aria-hidden={!flipped}>
            {match && (
              <>
                <p className="pb-line">
                  <span className="pb-label">heard</span> <q className="pb-heard">{match.heard}</q>
                </p>
                <p className="pb-line">
                  <span className="pb-label">you meant</span> <q className="pb-meant">{match.meant}</q>
                </p>
                <p className="pb-facts">
                  Confirmed {match.timesConfirmed === 1 ? "once" : `${match.timesConfirmed} times`}. Similarity{" "}
                  <span className="num">{Math.round(match.similarity * 100)}%</span>.{" "}
                  {match.strong ? "Strong enough to act on its own." : "A hint for Claude, not enough to act on its own."}
                </p>
              </>
            )}
          </div>
        </div>
      </div>
    </Station>
  );
}

export function ReadingStation({ state, turn }: { state: StationState; turn?: TurnModel }) {
  const repair = turn?.repair;
  const reading = repair?.reading;
  return (
    <Station
      state={state}
      variant="reading"
      title="Claude's reading"
      note={turn?.origin === "file" ? "Claude weighs the three texts and the phrasebook into one reading." : "Claude weighs the three texts, your phrasebook and what was just said."}
      aside={
        repair && (repair.status === "running" || repair.status === "done") ? (
          <Stopwatch label="Repair time" runningSince={repair.status === "running" ? repair.localStartedAt : undefined} final={repair.seconds} />
        ) : undefined
      }
    >
      {!turn || repair?.status === "waiting" ? (
        <p className="muted">{turn ? "Waiting for the recognisers." : "A recogniser does not know what you could want right now. Claude does."}</p>
      ) : repair?.status === "running" ? (
        <p className="muted">Thinking…</p>
      ) : repair?.status === "skipped" ? (
        <p className="skipped">
          Skipped. {repair.why}
        </p>
      ) : reading ? (
        <div className="reading">
          <p className="reading-text">
            <q>{reading.text}</q>
          </p>
          <div className="reading-row">
            <ConfidenceMeter level={reading.confidence} />
            <p className="reading-reason">{reading.reason}</p>
          </div>
          {reading.alternatives.length > 0 && (
            <p className="reading-alts">
              Also possible:{" "}
              {reading.alternatives.map((alt) => (
                <q key={alt} className="alt">
                  {alt}
                </q>
              ))}
            </p>
          )}
          {turn.answering && <p className="reading-context">Read as an answer to &ldquo;{turn.answering}&rdquo;.</p>}
        </div>
      ) : null}
    </Station>
  );
}
