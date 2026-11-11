// The last station: a switch-track. The turn is sent down one of three routes (act, ask first,
// or say it cannot hear), and the rule that threw the switch is written out in plain words.
// The rules are code on the server, not a prompt, so they hold even when a model is wrong.

import type { CSSProperties } from "react";
import { decisionSpeech, HEARER_LABEL, hearersOf, offsetSeconds, routeOf, type TurnModel } from "../model/turn";
import { seconds } from "./bits";
import { Station, type StationState } from "./Pipeline";

const BLADE_ANGLE = { act: -24, ask: 24, stop: 0, none: 0 } as const;

const ROUTES = {
  act: "M150 75 C190 75 200 28 250 28 H430",
  ask: "M150 75 C190 75 200 122 250 122 H430",
  stop: "M150 75 H296",
} as const;

export function DecisionStation({ state, turn }: { state: StationState; turn?: TurnModel }) {
  const decision = turn?.decision;
  const route = turn?.failed ? "stop" : decision ? routeOf(decision.decision) : "none";
  return (
    <Station state={state} variant="decide" title="Decide" note="Act, or ask one short question first. Decided in code, never by the model alone.">
      <svg className={`fork route-${route}`} viewBox="0 0 440 150" role="img" aria-label={routeLabel(route)}>
        <path className="fork-in" d="M0 75 H150" />
        {/* The three rails, always there in grey. */}
        <path className="fork-base" d={ROUTES.act} />
        <path className="fork-base" d={ROUTES.ask} />
        <path className="fork-base" d={ROUTES.stop} />
        <rect className={`buffer${route === "stop" ? " chosen" : ""}`} x="298" y="60" width="8" height="30" rx="2" />
        {/* The chosen route is drawn in its colour after the blade swings over. Keyed by turn so it draws again each turn. */}
        {route !== "none" && <path key={`${turn?.turnId}-${route}`} className={`fork-route route-line-${route}`} d={ROUTES[route]} pathLength={1} />}
        <line className="blade" x1="150" y1="75" x2="196" y2="75" style={{ transform: `rotate(${BLADE_ANGLE[route]}deg)` }} />
        <circle className="switch-point" cx="150" cy="75" r="9" />
        <text x="262" y="16" className={route === "act" ? "chosen" : ""}>Act</text>
        <text x="262" y="146" className={route === "ask" ? "chosen" : ""}>Ask first</text>
        <text x="318" y="81" className={route === "stop" ? "chosen" : ""}>Can&rsquo;t hear</text>
      </svg>

      {turn?.failed ? (
        <div className="verdict verdict-stop">
          <p className="verdict-head">The turn failed</p>
          <p className="verdict-text">{turn.failed}</p>
        </div>
      ) : decision ? (
        <div className={`verdict verdict-${route}`}>
          <p className="verdict-head">
            {turn.answering && decision.decision.kind === "act" ? `Taken as your answer to: ${turn.answering}` : headFor(decision.decision.kind)}
          </p>
          <p className="verdict-text">
            <q>{decisionSpeech(decision.decision)}</q>
          </p>
          {decision.decision.kind === "choose" && (
            <p className="verdict-options">
              {decision.decision.options.map((o) => (
                <span key={o} className="chip">
                  {o}
                </span>
              ))}
            </p>
          )}
          <p className="rule">
            <span className="rule-label">Rule</span> {decision.rule}
          </p>
          {turn.origin === "file" && <p className="rule">A recording is only transcribed: this is what it would have done, and nothing was acted on or asked.</p>}
        </div>
      ) : (
        <p className="muted">
          {turn ? "Waiting for the reading." : "Wrong actions cost most here: the person cannot undo one by hand. So when unsure, it asks."}
        </p>
      )}

      {turn && turn.stage === "done" && !turn.failed && <Timing turn={turn} />}
    </Station>
  );
}

function headFor(kind: string) {
  switch (kind) {
    case "act":
      return "Goes ahead";
    case "confirm":
      return "Asks one yes/no question";
    case "choose":
      return "Offers a choice";
    case "askAgain":
      return "Asks for just the unclear part";
    default:
      return "Says it cannot hear";
  }
}

function routeLabel(route: string) {
  if (route === "act") return "The switch is set to act.";
  if (route === "ask") return "The switch is set to ask first.";
  if (route === "stop") return "The switch is set to say it cannot hear.";
  return "The switch is waiting for a decision.";
}

/** When each step ran, on one axis, from the server's own timestamps. */
function Timing({ turn }: { turn: TurnModel }) {
  const total = turn.totalSeconds ?? offsetSeconds(turn, turn.decision?.at) ?? 0;
  const rows: { label: string; from: number; to: number; tone: string; failed?: boolean }[] = [];
  for (const hearer of hearersOf(turn)) {
    const lane = turn.lanes[hearer];
    const from = offsetSeconds(turn, lane.startedAt);
    const to = offsetSeconds(turn, lane.doneAt);
    if (from !== undefined && to !== undefined) rows.push({ label: HEARER_LABEL[hearer], from, to, tone: hearer, failed: lane.status === "failed" });
  }
  const repairFrom = offsetSeconds(turn, turn.repair.startedAt);
  const repairDone = turn.events.find((e) => e.type === "repair.done");
  if (repairFrom !== undefined && repairDone) rows.push({ label: "Claude", from: repairFrom, to: offsetSeconds(turn, repairDone.at) ?? repairFrom, tone: "claude" });
  const decidedAt = offsetSeconds(turn, turn.decision?.at) ?? total;
  const scale = Math.max(total, 0.5);

  return (
    <figure className="timing">
      <figcaption>
        {turn.speechSeconds !== undefined && (
          <>
            You spoke for <span className="num">{seconds(turn.speechSeconds, 1)}</span>.{" "}
          </>
        )}
        Decided <span className="num timing-total">{seconds(total)}</span> after the turn ended.
      </figcaption>
      <div className="timing-rows">
        {rows.map((row, i) => (
          <div className="timing-row" key={row.label} style={{ "--i": i } as CSSProperties}>
            <span className="timing-label">{row.label}</span>
            <span className="timing-track">
              <span
                className={`timing-bar tone-${row.tone}${row.failed ? " failed" : ""}`}
                style={{ left: `${(row.from / scale) * 100}%`, width: `${Math.max(0.6, ((row.to - row.from) / scale) * 100)}%` }}
                title={`${row.label}: ${seconds(row.from)} to ${seconds(row.to)}`}
              />
            </span>
            <span className="num timing-value">{seconds(row.to - row.from)}</span>
          </div>
        ))}
        <div className="timing-row">
          <span className="timing-label">Decision</span>
          <span className="timing-track">
            <span className="timing-tick" style={{ left: `${(decidedAt / scale) * 100}%` }} />
          </span>
          <span className="num timing-value">at {seconds(decidedAt)}</span>
        </div>
      </div>
    </figure>
  );
}
