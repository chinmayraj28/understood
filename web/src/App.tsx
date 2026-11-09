// The page: a short story, the examples, the pipeline line with the phone beside it, the stage
// switches, and the evaluation.

import { Compare, Settings, StageSwitchPanel } from "./components/Compare";
import { Enrolment, ENROLMENT_START } from "./components/Enrolment";
import { Evaluation } from "./components/Evaluation";
import { Phone } from "./components/Phone";
import { Pipeline } from "./components/Pipeline";
import { ConversationLog, PhrasebookPanel } from "./components/SidePanels";
import { REPLAYS } from "./fixtures";
import { PHONE_HOME } from "./model/phone";
import { ALL_ON, bestText, decisionSpeech } from "./model/turn";
import { useSession } from "./useSession";

export function App() {
  const session = useSession();
  const { state, ownState, mode, live } = session;
  const turn = state?.turns[state.turns.length - 1];
  const inExample = mode.kind === "replay";
  // Setup works on your own voice: leave any example, and open the microphone if it is off.
  const openSetup = () => {
    if (inExample) session.backToOwn();
    session.setEnrol({ ...ENROLMENT_START, open: true });
    if (!session.listening) void session.startListening();
  };

  // One sentence for screen readers when a turn is decided.
  const announcement =
    turn?.stage === "done"
      ? turn.failed
        ? `The turn failed. ${turn.failed}`
        : turn.decision
          ? `Understood: ${bestText(turn)}. ${decisionSpeech(turn.decision.decision)}`
          : ""
      : "";

  return (
    <>
      <a className="skip-link" href="#pipeline">
        Skip to the pipeline
      </a>
      <header className="masthead">
        <a className="wordmark" href="#top" aria-label="Understood, home">
          <ForkMark />
          Understood
        </a>
        <div className="masthead-actions">
          <button className="button quiet small" onClick={openSetup}>
            Set up your voice
          </button>
          <button className={`button small${session.listening ? "" : " primary"}`} onClick={session.listening ? session.stopListening : session.startListening}>
            {session.listening ? "Stop listening" : "Start listening"}
          </button>
        </div>
      </header>

      <main className="page" id="top">
        <section className="intro" aria-labelledby="intro-title">
          <h1 id="intro-title">A voice assistant that understands speech other assistants get wrong.</h1>
          <p className="intro-text">
            Voice assistants fail people with dysarthria: slow, slurred or quiet speech, common with ALS, cerebral palsy, Parkinson&rsquo;s
            and stroke. Often they cannot use their hands either, so voice is their only way in. On severe dysarthria, recognisers get over
            49% of words wrong, yet the meaning often survives. Here each turn is heard three ways, checked against your phrasebook,
            repaired by Claude, and a rule in code decides whether to act or to ask first, because a wrong action is one you cannot undo by
            hand. Every step is shown below, with its real timings.
          </p>
        </section>

        <section className="examples" aria-labelledby="examples-title">
          <h2 id="examples-title">Watch an example</h2>
          <ul className="example-list">
            {REPLAYS.map((r) => {
              const playing = mode.kind === "replay" && mode.id === r.id;
              return (
                <li key={r.id}>
                  <button className={`example-chip${playing ? " playing" : ""}`} onClick={() => void session.playReplay(r)} aria-pressed={playing}>
                    {r.title}
                    <span className="visually-hidden">. {r.summary}</span>
                  </button>
                </li>
              );
            })}
          </ul>
          {inExample && (
            <div className="mode-banner" role="status">
              <p>
                {!mode.evaluation && <span className="banner-summary">{REPLAYS.find((r) => r.id === mode.id)?.summary} </span>}
                {mode.running ? "Playing" : "Played"} {mode.evaluation ? "an evaluation turn" : "an example"}: <strong>{mode.title}</strong>.{" "}
                {mode.evaluation ? "Text and timings recorded in the evaluation run, without audio." : "Made-up text with scripted timings."} Your own
                phrasebook is untouched.
              </p>
              <button className="button small" onClick={session.backToOwn}>
                Back to your own voice
              </button>
            </div>
          )}
        </section>

        {session.notice && (
          <div className="notice" role="alert">
            <p>{session.notice}</p>
            <button className="button small quiet" onClick={session.dismissNotice}>
              Dismiss
            </button>
          </div>
        )}

        <div className="layout" id="pipeline">
          <div className="main-col">
            <Pipeline
              turn={turn}
              live={live}
              listening={session.listening}
              entryCount={state?.entries.length ?? 0}
              onStart={session.startListening}
              onEndTurn={session.endTurn}
            />
          </div>
          <aside className="side" aria-label="The assistant's side">
            <Phone phone={state?.phone ?? PHONE_HOME} />
            <ConversationLog chat={state?.chat ?? []} />
            <PhrasebookPanel
              entries={state?.entries ?? []}
              justLearned={state?.justLearned ?? []}
              clipCount={state?.clipCount ?? 0}
              scope={inExample ? "example" : state?.persistent === false ? "memory" : "yours"}
              onForget={(id) => void session.own?.forget(id)}
              onClear={() => void session.own?.clearEverything()}
              onSetup={openSetup}
            />
          </aside>
        </div>

        <section className="section" id="try" aria-labelledby="try-title">
          <h2 id="try-title">Switch a stage off</h2>
          <p>Say something, switch one stage off, and say the same thing again. The two turns appear side by side, so you can see what that stage adds.</p>
          <div className="try-grid">
            <StageSwitchPanel switches={ownState?.switches ?? ALL_ON} onChange={(s) => session.own?.setSwitches(s)} replaying={inExample} />
            <Settings
              endSilence={session.settings.endSilence}
              onEndSilence={session.settings.setEndSilence}
              speakReplies={session.settings.speakReplies}
              onSpeakReplies={session.settings.setSpeakReplies}
              autoListen={session.settings.autoListen}
              onAutoListen={session.settings.setAutoListen}
            />
          </div>
          <Compare turns={ownState?.turns ?? []} />
        </section>

        <section className="section" id="evaluation" aria-labelledby="eval-title">
          <h2 id="eval-title">How well it works</h2>
          <p>Measured on recordings of people with dysarthria. Success is judged by whether it did what the person meant, not only by how many words it got right.</p>
          <Evaluation
            onReplay={(r) => {
              document.getElementById("pipeline")?.scrollIntoView({ behavior: "smooth", block: "start" });
              void session.playEvaluation(r);
            }}
          />
        </section>

        <footer className="footer">
          <p>
            Your phrasebook and voice clips stay in this browser. Each turn&rsquo;s audio is sent to the server only to be heard, and the
            server keeps nothing. The phone is pretend: nothing is really sent or called.
          </p>
          <p className="muted">
            Voice commands for this page: &ldquo;set up my voice&rdquo;, &ldquo;play an example&rdquo;, &ldquo;stop listening&rdquo;. End a turn
            by pausing, by saying &ldquo;done&rdquo;, or with the space bar.
          </p>
        </footer>
      </main>

      <Enrolment
        state={session.enrol}
        liveText={live.text}
        listening={session.listening}
        onAgain={() => session.setEnrol((e) => ({ ...e, status: "listening", result: undefined, error: undefined }))}
        onSkip={() => session.setEnrol((e) => ({ ...e, index: e.index + 1, status: "listening", result: undefined }))}
        onClose={() => session.setEnrol((e) => ({ ...e, open: false }))}
      />
      <div className="visually-hidden" aria-live="assertive">
        {announcement}
      </div>
    </>
  );
}

/** The mark: a track meeting a switch, one branch lit. */
function ForkMark() {
  return (
    <svg width="34" height="34" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--ink)" />
      <path d="M5 21h8c3 0 4-2 6-6s3-6 7-6" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round" />
      <path d="M13 21h13" fill="none" stroke="var(--mark)" strokeWidth="3" strokeLinecap="round" />
      <circle cx="5" cy="21" r="3" fill="#fff" />
    </svg>
  );
}
