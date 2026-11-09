// Beside the phone: what was said back and forth, and the phrasebook growing as you confirm.

import { useState } from "react";
import type { PhrasebookEntry } from "../../shared/pipeline";
import type { ChatLine } from "../model/conversation";
import { HEARER_LABEL } from "../model/turn";

export function ConversationLog({ chat }: { chat: ChatLine[] }) {
  const lines = chat.slice(-8);
  return (
    <section className="panel log" aria-labelledby="log-title">
      <h2 id="log-title" className="panel-title">
        Conversation
      </h2>
      {lines.length === 0 ? (
        <p className="muted">What you say and what the assistant answers appears here.</p>
      ) : (
        <ol className="log-lines" aria-live="polite" aria-relevant="additions">
          {lines.map((line) => (
            <li key={line.id} className={`log-line who-${line.who}${line.tone ? ` tone-${line.tone}` : ""}`}>
              <span className="visually-hidden">{line.who === "you" ? "You said" : line.who === "assistant" ? "Assistant said" : "Note"}: </span>
              {line.text}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

export function PhrasebookPanel(props: {
  entries: PhrasebookEntry[];
  justLearned: string[];
  clipCount: number;
  scope: "yours" | "example" | "memory";
  onForget: (id: string) => void;
  onClear: () => void;
  onSetup: () => void;
}) {
  const [confirmClear, setConfirmClear] = useState(false);
  const sorted = [...props.entries].sort((a, b) => b.lastConfirmedAt - a.lastConfirmedAt);
  return (
    <section className="panel phrasebook" aria-labelledby="pb-title" id="phrasebook">
      <div className="panel-head">
        <h2 id="pb-title" className="panel-title">
          Phrasebook <span className="num count">{props.entries.length}</span>
        </h2>
        <p className="panel-note">
          {props.scope === "example"
            ? "The example's own phrasebook. Yours is untouched."
            : props.scope === "memory"
              ? "Kept for this visit only: this browser blocks local storage."
              : `Kept only in this browser, with ${props.clipCount} ${props.clipCount === 1 ? "clip" : "clips"} of your voice.`}
        </p>
      </div>
      {sorted.length === 0 ? (
        <div className="pb-empty">
          <p>Empty. It fills when you confirm or correct what was heard, or when you set up your voice.</p>
          {props.scope !== "example" && (
            <button className="button small" onClick={props.onSetup}>
              Set up your voice
            </button>
          )}
        </div>
      ) : (
        <ul className="pb-list">
          {sorted.map((entry) => (
            <li key={entry.id} className={`pb-entry${props.justLearned.includes(entry.id) ? " arrived" : ""}`}>
              <p className="pb-pair">
                <span className="pb-heard">{entry.heard}</span>
                <span className="pb-arrow" aria-label="means">
                  {" "}
                  →{" "}
                </span>
                <span className="pb-meant">{entry.meant}</span>
              </p>
              <p className="pb-meta">
                <span className={`hearer-dot dot-${entry.hearer}`} aria-hidden="true" />
                {HEARER_LABEL[entry.hearer]} heard it. {sourceWords(entry)}
              </p>
              {props.scope !== "example" && (
                <button className="pb-forget" onClick={() => props.onForget(entry.id)} aria-label={`Forget "${entry.heard}" means "${entry.meant}"`}>
                  Forget
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {sorted.length > 0 && props.scope !== "example" && (
        <button
          className="button small quiet clear"
          onClick={() => {
            if (confirmClear) {
              props.onClear();
              setConfirmClear(false);
            } else setConfirmClear(true);
          }}
          onBlur={() => setConfirmClear(false)}
        >
          {confirmClear ? "Press again to clear everything" : "Clear everything"}
        </button>
      )}
    </section>
  );
}

function sourceWords(entry: PhrasebookEntry) {
  const times = entry.timesConfirmed === 1 ? "once" : `${entry.timesConfirmed} times`;
  if (entry.source === "enrolment") return entry.timesConfirmed > 1 ? `From setup, then confirmed ${times}.` : "From setup.";
  if (entry.source === "correction") return `You corrected it, ${times}.`;
  return `Confirmed ${times}.`;
}
