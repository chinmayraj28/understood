// Stage switches and a side-by-side comparison. Turn a stage off, hear the same recording (or
// say the same thing) again, and see what that stage was adding.

import type { StageSwitches } from "../../shared/pipeline";
import { bestText, decisionSpeech, HEARER_LABEL, HEARERS, routeOf, type TurnModel } from "../model/turn";
import { countErrors, errorRate } from "../../shared/wordErrors";
import { ConfidenceMeter, MarkedWords, seconds } from "./bits";

const SWITCHES: { key: keyof StageSwitches; name: string; what: string }[] = [
  { key: "keyterms", name: "Keyterms", what: "Tell Scribe the words this person tends to say." },
  { key: "gemini", name: "Gemini", what: "A second recogniser, running alongside Scribe." },
  { key: "examples", name: "Their clips", what: "Show Gemini a few recordings of the same voice." },
  { key: "phrasebook", name: "Phrasebook", what: "Catch a mishearing you confirmed before." },
  { key: "repair", name: "Claude's repair", what: "Weigh the three texts and the phrasebook into one reading." },
];

export function StageSwitchPanel(props: {
  switches: StageSwitches;
  onChange: (switches: StageSwitches) => void;
}) {
  return (
    <fieldset className="switches">
      <legend className="visually-hidden">Stage switches</legend>
      {SWITCHES.map((s) => {
        const on = props.switches[s.key];
        return (
          <button
            key={s.key}
            role="switch"
            aria-checked={on}
            className={`switch${on ? " on" : ""}`}
            onClick={() => props.onChange({ ...props.switches, [s.key]: !on })}
          >
            <span className="switch-knob" aria-hidden="true" />
            <span className="switch-words">
              <span className="switch-name">{s.name}</span>
              <span className="switch-what">{s.what}</span>
            </span>
          </button>
        );
      })}
    </fieldset>
  );
}

export function Settings(props: {
  endSilence: number;
  onEndSilence: (seconds: number) => void;
  speakReplies: boolean;
  onSpeakReplies: (on: boolean) => void;
  autoListen: boolean;
  onAutoListen: (on: boolean) => void;
}) {
  return (
    <div className="settings">
      <label className="slider">
        <span>
          Wait for <span className="num">{props.endSilence.toFixed(1)} s</span> of quiet before ending a turn
        </span>
        <input type="range" min={1} max={5} step={0.5} value={props.endSilence} onChange={(e) => props.onEndSilence(Number(e.target.value))} />
      </label>
      <label className="check">
        <input type="checkbox" checked={props.speakReplies} onChange={(e) => props.onSpeakReplies(e.target.checked)} />
        Speak replies aloud
      </label>
      <label className="check">
        <input type="checkbox" checked={props.autoListen} onChange={(e) => props.onAutoListen(e.target.checked)} />
        Start listening as soon as the page opens
      </label>
      <p className="settings-note">
        Browsers need one click or key press per visit before a page may use sound, so after opening the page, press any key or
        click once (switch access and voice-control software count).
      </p>
    </div>
  );
}

/** The two latest finished turns, side by side. */
export function Compare({ turns }: { turns: TurnModel[] }) {
  const finished = turns.filter((t) => t.stage === "done" && (t.origin === "live" || t.origin === "file"));
  if (finished.length < 2) {
    return <p className="muted compare-empty">Hear two recordings and they appear here side by side. Try the same one again with a stage switched off.</p>;
  }
  const [before, now] = finished.slice(-2);
  return (
    <div className="compare">
      <TurnSummary turn={before} title="The turn before" />
      <TurnSummary turn={now} title="This turn" />
    </div>
  );
}

function TurnSummary({ turn, title }: { turn: TurnModel; title: string }) {
  const off = SWITCHES.filter((s) => !turn.switches[s.key]).map((s) => s.name);
  const route = turn.decision ? routeOf(turn.decision.decision) : "stop";
  const disputed = turn.agreement?.disputedWords ?? [];
  const reference = turn.recording?.reference;
  return (
    <article className="summary">
      <h3>{title}</h3>
      {turn.recording && <p className="summary-off">{turn.recording.label}</p>}
      <p className="summary-off">{off.length ? `Switched off: ${off.join(", ")}` : "Every stage on"}</p>
      <dl>
        {HEARERS.map((h) => (
          <div key={h} className="summary-row">
            <dt>
              <span className={`hearer-dot dot-${h}`} aria-hidden="true" /> {HEARER_LABEL[h]}
            </dt>
            <dd>{turn.lanes[h].text ? <MarkedWords text={turn.lanes[h].text!} disputed={disputed} /> : <span className="muted">{turn.lanes[h].failure ?? "nothing"}</span>}</dd>
          </div>
        ))}
        <div className="summary-row">
          <dt>Understood</dt>
          <dd>
            <strong>{bestText(turn)}</strong> {turn.repair.reading && <ConfidenceMeter level={turn.repair.reading.confidence} />}
          </dd>
        </div>
        {reference && (
          <div className="summary-row">
            <dt>Words wrong</dt>
            <dd className="num">{Math.round(errorRate(countErrors(reference, bestText(turn))) * 100)}%</dd>
          </div>
        )}
        <div className="summary-row">
          <dt>{turn.origin === "file" ? "Would have" : "Decision"}</dt>
          <dd className={`route-word route-${route}`}>{turn.failed ?? (turn.decision ? decisionSpeech(turn.decision.decision) : "none")}</dd>
        </div>
        <div className="summary-row">
          <dt>Time</dt>
          <dd className="num">{seconds(turn.totalSeconds)}</dd>
        </div>
      </dl>
    </article>
  );
}
