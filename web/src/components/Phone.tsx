// A small pretend phone beside the pipeline. It does what the assistant decided (a message, a
// call, a timer, music, a reminder) so the result of a turn is something you can see.
// Anything that reaches another person first waits on a confirm sheet for a spoken yes.

import { useEffect, useState } from "react";
import { phoneDescription, type PhoneState } from "../model/phone";

function useClock(intervalMs: number) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

function mmss(totalSeconds: number) {
  const s = Math.max(0, Math.round(totalSeconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export function Phone({ phone }: { phone: PhoneState }) {
  const now = useClock(1000);
  const time = new Date(now).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return (
    <figure className="phone-wrap">
      {/* Not a live region: the screen ticks every second during a timer or call. What the phone
          did is announced once, in the conversation log; this sentence is for anyone reading the phone. */}
      <div className={`phone screen-${phone.screen}`} role="region" aria-label="Pretend phone">
        <p className="visually-hidden">{phoneDescription(phone)}</p>
        <div className="phone-bar" aria-hidden="true">
          <span className="num">{time}</span>
          <span className="phone-notch" />
          <span className="phone-battery" />
        </div>
        <div className="phone-screen" aria-hidden="true">
          <Screen phone={phone} now={now} />
        </div>
      </div>
      <figcaption>A pretend phone. Nothing is really sent or called.</figcaption>
    </figure>
  );
}

function Screen({ phone, now }: { phone: PhoneState; now: number }) {
  const action = phone.action;
  const elapsed = (now - phone.since) / 1000;
  if (phone.screen === "confirm" && action) {
    return (
      <div className="ph-confirm">
        <p className="ph-kicker">Waiting for your yes</p>
        {action.kind === "message" ? (
          <div className="ph-draft">
            <p className="ph-to">To {action.to}</p>
            <p className="bubble draft">{action.text}</p>
          </div>
        ) : action.kind === "call" ? (
          <div className="ph-person">
            <span className="avatar">{action.to.slice(0, 1)}</span>
            <p>{action.to}</p>
          </div>
        ) : null}
        <p className="ph-question">{phone.question}</p>
        <p className="ph-hint">Say yes or no</p>
      </div>
    );
  }
  if (phone.screen === "message" && action?.kind === "message") {
    const thread = phone.messages.filter((m) => m.to === action.to).slice(-4);
    return (
      <div className="ph-thread">
        <p className="ph-to">{action.to}</p>
        {thread.map((m) => (
          <p key={m.at} className="bubble sent">
            {m.text}
          </p>
        ))}
        <p className="ph-status">Sent (pretend)</p>
      </div>
    );
  }
  if (phone.screen === "call" && action?.kind === "call") {
    return (
      <div className="ph-call">
        <span className="avatar big">{action.to.slice(0, 1)}</span>
        <p className="ph-name">{action.to}</p>
        <p className="num">{elapsed < 3 ? "Calling…" : mmss(elapsed - 3)}</p>
        <span className="hangup" aria-hidden="true" />
      </div>
    );
  }
  if (phone.screen === "timer" && action?.kind === "timer") {
    const left = action.minutes * 60 - elapsed;
    const share = Math.max(0, left / (action.minutes * 60));
    return (
      <div className="ph-timer">
        <svg viewBox="0 0 120 120" aria-hidden="true">
          <circle cx="60" cy="60" r="50" className="ring-back" />
          <circle cx="60" cy="60" r="50" className="ring" style={{ strokeDashoffset: 314 * (1 - share) }} />
        </svg>
        <p className="num ph-count">{left > 0 ? mmss(left) : "Done"}</p>
        <p>Timer, {action.minutes} {action.minutes === 1 ? "minute" : "minutes"}</p>
      </div>
    );
  }
  if (phone.screen === "music" && action?.kind === "music") {
    return (
      <div className="ph-music">
        <div className="album" aria-hidden="true">
          {[0, 1, 2, 3, 4].map((i) => (
            <span key={i} style={{ animationDelay: `${i * 120}ms` }} />
          ))}
        </div>
        <p className="ph-name">{action.query}</p>
        <p className="num">{mmss(elapsed)}</p>
      </div>
    );
  }
  if (phone.screen === "reminder" && action?.kind === "reminder") {
    return (
      <div className="ph-reminder">
        <p className="ph-kicker">Reminder set</p>
        <p className="ph-name">{action.text}</p>
        <p>{action.when}</p>
      </div>
    );
  }
  return (
    <div className="ph-home">
      {[
        ["Messages", "msg"],
        ["Phone", "call"],
        ["Timer", "timer"],
        ["Music", "music"],
        ["Reminders", "rem"],
      ].map(([name, tone]) => (
        <span key={name} className="app">
          <span className={`app-icon app-${tone}`} aria-hidden="true" />
          {name}
        </span>
      ))}
      {phone.messages.length > 0 && <p className="ph-status">{phone.messages.length} sent this visit</p>}
    </div>
  );
}
