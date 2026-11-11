// The turn is heard three ways at once. Each recogniser runs on its own track against one shared
// clock, so you can see who finished first and who was left out at the time limit. Words the
// tracks disagree on are marked; that disagreement is the confidence signal no single
// recogniser gives.

import { useEffect, useState } from "react";
import type { HearerName } from "../../shared/pipeline";
import { HEARER_LABEL, HEARER_NOTE, HEARERS, type Lane, type TurnModel } from "../model/turn";
import { MarkedWords, Stopwatch } from "./bits";
import { Station, type StationState } from "./Pipeline";

/** The server leaves a recogniser out after this long (SPEECH_PLAN, failure modes). A recording
 * being transcribed gets longer (server/understand.ts, TRANSCRIBE_LIMITS). */
const LIMIT_SECONDS = 4;
const RECORDING_LIMIT_SECONDS = 15;
const limitFor = (turn?: TurnModel) => (turn?.origin === "file" ? RECORDING_LIMIT_SECONDS : LIMIT_SECONDS);

function useRunningNow(running: boolean) {
  const [now, setNow] = useState(() => performance.now());
  useEffect(() => {
    if (!running) return;
    let frame = 0;
    const tick = () => {
      setNow(performance.now());
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [running]);
  return now;
}

/** Second marks along the scale: every second on a short one, every five on a long one; always the limit. */
function ticks(scale: number, limit: number): number[] {
  const step = scale > 8 ? 5 : 1;
  const marks = Array.from({ length: Math.floor(scale / step) + 1 }, (_, i) => i * step);
  return limit <= scale && !marks.includes(limit) ? [...marks.filter((m) => limit - m >= step * 0.6), limit] : marks;
}

function switchedOff(turn: TurnModel | undefined, hearer: HearerName): boolean {
  return hearer === "gemini" && turn !== undefined && !turn.switches.gemini;
}

export function HearStation({ state, turn }: { state: StationState; turn?: TurnModel }) {
  const lanes = turn ? HEARERS.map((h) => turn.lanes[h]) : [];
  const anyRunning = lanes.some((l) => l.status === "running");
  const now = useRunningNow(anyRunning);
  const longest = Math.max(0, ...lanes.map((l) => l.seconds ?? 0));
  const limit = limitFor(turn);
  // A recording's scale grows with the slowest recogniser, up to its longer limit.
  const scale = turn?.origin === "file" ? Math.max(LIMIT_SECONDS, Math.min(limit, Math.ceil(longest))) : Math.max(limit, longest);
  const disputed = turn?.agreement?.disputedWords ?? [];

  return (
    <Station
      state={state}
      variant="hear"
      title="Heard three ways"
      note="Three recognisers listen at once, each with a stopwatch."
      aside={
        turn?.exampleCount ? (
          <span className="chip">
            {turn.exampleCount} {turn.origin === "file" ? "clips of the same voice" : "of your clips"} shown to Gemini
          </span>
        ) : undefined
      }
    >
      <div className="race" role="list">
        <div className="race-scale" aria-hidden="true">
          {ticks(scale, limit).map((i) => (
            <span key={i} style={{ left: `${(i / scale) * 100}%` }}>
              {i === limit ? `${i} s limit` : `${i}`}
            </span>
          ))}
        </div>
        {HEARERS.map((hearer) => (
          <Track
            key={hearer}
            lane={turn?.lanes[hearer] ?? { hearer, status: "waiting" }}
            scale={scale}
            limit={limit}
            now={now}
            disputed={disputed}
            off={switchedOff(turn, hearer)}
          />
        ))}
      </div>
      {turn?.agreement && <Agreement turn={turn} />}
    </Station>
  );
}

function Track({ lane, scale, limit, now, disputed, off }: { lane: Lane; scale: number; limit: number; now: number; disputed: string[]; off: boolean }) {
  const elapsed =
    lane.seconds ?? (lane.status === "running" && lane.localStartedAt !== undefined ? (now - lane.localStartedAt) / 1000 : 0);
  const width = Math.min(1, elapsed / scale);
  const label = HEARER_LABEL[lane.hearer];
  return (
    <div className={`track track-${lane.hearer} is-${off ? "off" : lane.status}`} role="listitem">
      <div className="track-head">
        <span className="track-name">
          <span className="swatch" aria-hidden="true" />
          {label}
        </span>
        <span className="track-note">{HEARER_NOTE[lane.hearer]}</span>
        {off ? (
          <span className="track-time">Switched off</span>
        ) : (
          lane.hearer === "realtime" ? (
            // The live transcript is written while the sentence is said, so it has no time of its own.
            <span className="track-time">as it was said</span>
          ) : (
            <Stopwatch label={`${label} time`} runningSince={lane.status === "running" ? lane.localStartedAt : undefined} final={lane.seconds} />
          )
        )}
      </div>
      <div className="track-rail" aria-hidden="true">
        <span className="track-fill" style={{ width: `${width * 100}%` }} />
        {(lane.status === "done" || lane.status === "failed") && <span className="track-end" style={{ left: `${width * 100}%` }} />}
        {limit <= scale && <span className="track-limit" style={{ left: `${(limit / scale) * 100}%` }} />}
      </div>
      <p className="track-text">
        {lane.status === "done" && lane.text ? (
          <q>
            <MarkedWords text={lane.text} disputed={disputed} />
          </q>
        ) : lane.status === "failed" ? (
          <span className="failure">{lane.failure ?? "No words came back."}</span>
        ) : lane.status === "done" ? (
          <span className="muted">Heard nothing.</span>
        ) : lane.status === "running" ? (
          <span className="muted">Working…</span>
        ) : (
          <span className="muted">{off ? "Not used for this turn." : "Waiting for a turn."}</span>
        )}
      </p>
    </div>
  );
}

function Agreement({ turn }: { turn: TurnModel }) {
  const agreement = turn.agreement!;
  const heard = HEARERS.filter((h) => turn.lanes[h].status === "done" && turn.lanes[h].text);
  const names = agreement.agreeing.map((h) => HEARER_LABEL[h]);
  let sentence: string;
  if (heard.length === 0) sentence = "No recogniser returned any words.";
  else if (agreement.agreeing.length >= 2 && agreement.agreeing.length === heard.length)
    sentence = heard.length === 3 ? "All three heard the same words." : "Both recognisers that answered heard the same words.";
  else if (agreement.agreeing.length >= 2) sentence = `${names.join(" and ")} heard the same words; the other did not.`;
  else if (heard.length === 1) sentence = `Only ${HEARER_LABEL[heard[0]]} returned words, so there is nothing to compare.`;
  else sentence = "No two recognisers heard the same words.";
  return (
    <div className="agreement">
      <span className={`agree-count agree-${Math.min(agreement.agreeing.length, 3)}`} title="Recognisers that agreed, out of those that answered">
        {agreement.agreeing.length}/{heard.length || 3}
      </span>
      <div>
        <p className="agree-sentence">{sentence}</p>
        {agreement.disputedWords.length > 0 && (
          <p className="agree-disputed">
            Disputed words:{" "}
            {agreement.disputedWords.map((w) => (
              <mark key={w} className="disputed">
                {w}
              </mark>
            ))}
          </p>
        )}
      </div>
    </div>
  );
}
