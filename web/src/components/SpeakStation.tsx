// The first station: the person speaking. The live transcript writes itself in large type, a
// waveform breathes with the voice, and a meter shows how long the page has been waiting
// through a pause. It waits patiently on purpose: long pauses inside a sentence are normal here.

import { useEffect, useRef } from "react";
import type { TurnModel } from "../model/turn";
import { LandingWords, seconds } from "./bits";
import { Station, type LiveInput, type StationState } from "./Pipeline";

const STATUS_WORDS: Record<string, string> = {
  off: "Not listening",
  starting: "Opening the microphone",
  calibrating: "Measuring the room",
  waiting: "Listening",
  speaking: "Hearing you",
  finishing: "Finishing the turn",
};

export function SpeakStation(props: {
  state: StationState;
  turn?: TurnModel;
  live: LiveInput;
  listening: boolean;
  onStart: () => void;
  onEndTurn: () => void;
  micBlocked?: boolean;
}) {
  const { live, turn } = props;
  const speaking = live.status === "speaking";
  const text = speaking || live.playing ? live.text : turn?.liveText || live.text;
  const recording = live.playing ? undefined : turn?.recording;
  const patience = speaking ? Math.min(1, live.quietSeconds / live.endSilenceSeconds) : 0;

  return (
    <Station
      state={props.state}
      variant="speak"
      title={live.playing || turn?.origin === "file" ? "The recording plays" : "You speak"}
      note={
        live.playing || turn?.origin === "file"
          ? "It plays out loud at its own pace while the live recogniser writes down what it hears. That text is the third vote."
          : `It waits through pauses. A turn ends after ${seconds(live.endSilenceSeconds, 1)} of quiet, or when you say "done".`
      }
      aside={
        <span className={`listen-status status-${live.playing ? "speaking" : live.status}`}>
          <span className="dot" aria-hidden="true" />
          {live.playing ? "Playing the recording" : STATUS_WORDS[live.status]}
        </span>
      }
    >
      <p className={`transcript${text ? "" : " placeholder"}`} aria-live="off">
        {text ? (
          <>
            <LandingWords text={text} />
            {(speaking || live.playing) && <span className="caret" aria-hidden="true" />}
          </>
        ) : props.listening ? (
          <>Say something like &ldquo;Message Mum, I&rsquo;m running late&rdquo;.</>
        ) : live.playing ? (
          <>Listening to the recording…</>
        ) : turn?.origin === "file" ? (
          <>The live recogniser heard nothing it could write down.</>
        ) : (
          <>Hear a recording above, or start listening and speak.</>
        )}
      </p>
      {recording && <p className="example-label">{recording.label}, heard as {recording.voiceLabel}.</p>}

      <Waveform level={live.level} active={speaking || live.playing} />

      <div className="speak-controls">
        {!props.listening ? (
          <button className="button primary" onClick={props.onStart} disabled={props.micBlocked}>
            <MicIcon /> Start listening
          </button>
        ) : (
          <button className="button" onClick={props.onEndTurn} disabled={!speaking}>
            End turn <kbd>Space</kbd>
          </button>
        )}
        <div className={`patience${speaking ? " on" : ""}`} aria-hidden={!speaking}>
          <div className="patience-bar">
            <span style={{ transform: `scaleX(${patience})` }} />
          </div>
          <span className="patience-words">
            {speaking ? (
              <>
                Quiet for <span className="num">{live.quietSeconds.toFixed(1)}</span> of <span className="num">{live.endSilenceSeconds.toFixed(1)}</span> s
              </>
            ) : (
              "Pause meter"
            )}
          </span>
        </div>
      </div>
    </Station>
  );
}

/** A scrolling picture of how loud the voice has been over the last few seconds. */
function Waveform({ level, active }: { level: number; active: boolean }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const history = useRef<number[]>(Array(96).fill(0));
  const latest = useRef(0);
  latest.current = active ? level : 0;

  useEffect(() => {
    const element = canvas.current;
    if (!element) return;
    const context = element.getContext("2d");
    if (!context) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let frame = 0;
    let last = 0;
    const draw = (time: number) => {
      frame = requestAnimationFrame(draw);
      if (time - last < (reduce ? 200 : 45)) return;
      last = time;
      history.current.push(latest.current);
      history.current.shift();
      const ratio = window.devicePixelRatio || 1;
      const width = element.clientWidth;
      const height = element.clientHeight;
      if (element.width !== Math.round(width * ratio)) {
        element.width = Math.round(width * ratio);
        element.height = Math.round(height * ratio);
      }
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      context.clearRect(0, 0, width, height);
      const bars = history.current.length;
      const step = width / bars;
      const ink = getComputedStyle(element).color;
      context.fillStyle = ink;
      for (let i = 0; i < bars; i++) {
        const value = history.current[i];
        const h = Math.max(2, value * (height - 4));
        context.globalAlpha = 0.25 + 0.75 * (i / bars);
        context.fillRect(i * step + step * 0.2, (height - h) / 2, Math.max(1.5, step * 0.6), h);
      }
    };
    frame = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(frame);
  }, []);

  return <canvas ref={canvas} className={`waveform${active ? " active" : ""}`} aria-hidden="true" />;
}

function MicIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">
      <rect x="8" y="2" width="8" height="13" rx="4" fill="currentColor" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v4" stroke="currentColor" strokeWidth="2" fill="none" strokeLinecap="round" />
    </svg>
  );
}
