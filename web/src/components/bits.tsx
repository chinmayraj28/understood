// Small pieces used across the pipeline view.

import { useEffect, useState, type CSSProperties } from "react";
import { normalise } from "../model/learning";

export function seconds(value: number | undefined, digits = 2): string {
  return value === undefined ? "–" : `${value.toFixed(digits)} s`;
}

/**
 * A stopwatch. While `runningSince` is set it counts up from that performance.now() time;
 * once `final` arrives it shows the time the server measured, which is the honest one.
 */
export function Stopwatch({ runningSince, final, label }: { runningSince?: number; final?: number; label: string }) {
  const [now, setNow] = useState(() => performance.now());
  const running = final === undefined && runningSince !== undefined;
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
  const value = final ?? (runningSince !== undefined ? (now - runningSince) / 1000 : undefined);
  return (
    <span className={`num stopwatch${running ? " running" : ""}`} aria-label={`${label}: ${seconds(value)}`}>
      {seconds(value)}
    </span>
  );
}

/**
 * Text with the words the recognisers disagreed on marked like a highlighter. Words land one
 * after another when the text arrives, then the marks sweep across them.
 */
export function MarkedWords({ text, disputed }: { text: string; disputed: string[] }) {
  if (!text) return null;
  const marked = new Set(disputed.map(normalise));
  let index = 0;
  return (
    <>
      {text.split(/(\s+)/).map((part, i) => {
        if (!part.trim()) return <span key={i}>{part}</span>;
        const style = { "--i": index++ } as CSSProperties;
        const word = normalise(part);
        return word && marked.has(word) ? (
          <mark key={i} className="word disputed" style={style}>
            {part}
          </mark>
        ) : (
          <span key={i} className="word" style={style}>
            {part}
          </span>
        );
      })}
    </>
  );
}

/**
 * The live transcript, one span per word, keyed by position: a new word lands with a small
 * rise, while a word the recogniser revises ("so" becoming "some") just changes in place.
 */
export function LandingWords({ text }: { text: string }) {
  return (
    <>
      {text.split(/\s+/).filter(Boolean).map((word, i) => (
        <span key={i} className="land">
          {word}{" "}
        </span>
      ))}
    </>
  );
}

/** Three filled bars for low, medium and high. */
export function ConfidenceMeter({ level }: { level: "low" | "medium" | "high" }) {
  const filled = level === "high" ? 3 : level === "medium" ? 2 : 1;
  return (
    <span className={`confidence confidence-${level}`} role="img" aria-label={`Confidence: ${level}`}>
      {[1, 2, 3].map((i) => (
        <span key={i} className={i <= filled ? "bar on" : "bar"} style={{ "--n": i } as CSSProperties} />
      ))}
      <span className="confidence-word" aria-hidden="true">
        {level}
      </span>
    </span>
  );
}
