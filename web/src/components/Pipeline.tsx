// The pipeline, drawn as one transit line. Each stage of a turn is a station; the rail fills in
// as the turn passes. Before anything is said, the empty line still shows every station and what
// happens there, like a line map on a platform.

import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { ListenerStatus } from "../audio/listener";
import { stageIndex, type Stage, type TurnModel } from "../model/turn";
import { DecisionStation } from "./DecisionStation";
import { HearStation } from "./HearStation";
import { PhrasebookStation, ReadingStation } from "./MiddleStations";
import { SpeakStation } from "./SpeakStation";

export interface LiveInput {
  text: string;
  level: number;
  quietSeconds: number;
  status: ListenerStatus;
  endSilenceSeconds: number;
  /** True while a chosen recording plays; level and text then come from the recording. */
  playing: boolean;
}

type StationState = "passed" | "current" | "ahead";

function stateOf(turn: TurnModel | undefined, stage: Stage): StationState {
  if (!turn) return "ahead";
  const at = stageIndex(turn.stage);
  const mine = stageIndex(stage);
  if (turn.stage === "done") return "passed";
  return at > mine ? "passed" : at === mine ? "current" : "ahead";
}

export function Station(props: {
  state: StationState;
  title: string;
  /** Short line under the title: what happens here. */
  note?: string;
  aside?: ReactNode;
  variant?: string;
  children: ReactNode;
}) {
  return (
    <li className={`station is-${props.state}${props.variant ? ` station-${props.variant}` : ""}`} aria-current={props.state === "current" ? "step" : undefined}>
      <div className="rail" aria-hidden="true">
        <span className="marker" />
      </div>
      <div className="stop">
        <header className="stop-head">
          <div>
            <h3>{props.title}</h3>
            {props.note && <p className="stop-note">{props.note}</p>}
          </div>
          {props.aside && <div className="stop-aside">{props.aside}</div>}
        </header>
        <div className="stop-body">{props.children}</div>
      </div>
    </li>
  );
}

export function Pipeline(props: {
  turn?: TurnModel;
  live: LiveInput;
  listening: boolean;
  entryCount: number;
  onStart: () => void;
  onEndTurn: () => void;
  /** True while a recording is loading or playing: the microphone cannot be opened. */
  micBlocked?: boolean;
}) {
  const { turn, live } = props;
  // While a new turn is being spoken, the previous turn's stations fade back.
  const speakingNow = live.status === "speaking" || live.playing;
  const stale = speakingNow && turn?.stage === "done";
  const speakState: StationState = speakingNow || (!turn && props.listening) ? "current" : turn ? "passed" : "ahead";
  const line = useRef<HTMLOListElement>(null);
  // Where the train stands: at "You speak" while someone talks, else at the turn's station.
  const stationIndex = speakingNow || (!turn && props.listening) ? 0 : turn ? TRAIN_STOP[turn.stage] : -1;
  return (
    <section aria-labelledby="pipeline-title" className="pipeline">
      <h2 id="pipeline-title" className="visually-hidden">
        One turn, through the pipeline
      </h2>
      <div className="line-wrap">
        <ol ref={line} className={`line${stale ? " stale" : ""}${turn ? "" : " empty"}`}>
          <SpeakStation
            state={speakState}
            turn={turn}
            live={live}
            listening={props.listening}
            onStart={props.onStart}
            onEndTurn={props.onEndTurn}
            micBlocked={props.micBlocked}
          />
          <HearStation state={stateOf(turn, "hear")} turn={turn} />
          <PhrasebookStation state={stateOf(turn, "phrasebook")} turn={turn} entryCount={props.entryCount} />
          <ReadingStation state={stateOf(turn, "repair")} turn={turn} />
          <DecisionStation state={stateOf(turn, "decide")} turn={turn} />
        </ol>
        <Train line={line} station={stationIndex} turnKey={turn?.turnId ?? ""} />
      </div>
    </section>
  );
}

/** Which station (0 = You speak ... 4 = Decide) the train stands at for each stage. */
const TRAIN_STOP: Record<Stage, number> = { speak: 0, hear: 1, agree: 1, phrasebook: 2, repair: 3, decide: 4, done: 4 };

/**
 * The train: it rides the rail to the station the turn has reached, speeding up and braking
 * like a real one. Its position is measured from the station markers, so it stays right when
 * a station grows (words landing, the card turning over) or the window changes size.
 */
function Train({ line, station, turnKey }: { line: React.RefObject<HTMLOListElement | null>; station: number; turnKey: string }) {
  const [y, setY] = useState<number | null>(null);
  useLayoutEffect(() => {
    const element = line.current;
    if (!element || station < 0) return setY(null);
    const measure = () => {
      const marker = element.querySelectorAll<HTMLElement>(".marker")[station];
      if (!marker) return;
      const top = marker.getBoundingClientRect().top - element.getBoundingClientRect().top + marker.offsetHeight / 2;
      setY(top);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [line, station, turnKey]);
  if (y === null) return null;
  return (
    <span className={`train at-${station}`} style={{ transform: `translateY(${y}px)` }} aria-hidden="true">
      <span className="train-window" />
    </span>
  );
}

export type { StationState };
