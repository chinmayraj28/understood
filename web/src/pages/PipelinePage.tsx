// The pipeline workspace. Input on the left (a TORGO recording, your own file, or the
// microphone) with the stage switches under it; the transcript and the pipeline line in the
// middle; on the right the phrasebook, and under "Advanced" (closed at first) the optional part
// that acts on what was heard: the conversation and the pretend phone.

import { useState } from "react";
import { Compare, Settings, StageSwitchPanel } from "../components/Compare";
import { Enrolment, ENROLMENT_START } from "../components/Enrolment";
import { HearRecording } from "../components/HearRecording";
import { Phone } from "../components/Phone";
import { Pipeline } from "../components/Pipeline";
import { ConversationLog, PhrasebookPanel } from "../components/SidePanels";
import { TranscriptResult } from "../components/TranscriptResult";
import { PHONE_HOME } from "../model/phone";
import { ALL_ON, pageAnnouncement } from "../model/turn";
import type { useSession } from "../useSession";

type Session = ReturnType<typeof useSession>;
type Advanced = "conversation" | "phone";

export function PipelinePage({ session }: { session: Session }) {
  const { state, ownState, live } = session;
  const [advanced, setAdvanced] = useState<Advanced>("phone");
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const logShown = advancedOpen && advanced === "conversation";
  const turn = state?.turns[state.turns.length - 1];

  // Setup works on your own voice: open the microphone if it is off.
  const openSetup = () => {
    session.stopHearing();
    session.setEnrol({ ...ENROLMENT_START, open: true });
    if (!session.listening) void session.startListening();
  };

  // Screen readers hear each turn once, through the conversation log or the transcript; this adds only failures.
  const announcement = pageAnnouncement(turn);
  const entryCount = session.voiceInUse?.phrasebook.length ?? state?.entries.length ?? 0;
  const step = session.hearing.step;
  const pendingLabel = step === "loading" || step === "setup" || step === "playing" ? session.hearing.label : undefined;

  const micPanel = (
    <div className="mic-panel">
      <p className="muted">
        {session.settings.actOnSpeech ? (
          <>
            Speak a sentence to the pretend phone, such as &ldquo;Message Mum, I&rsquo;m running late&rdquo;. It acts, or asks one short question
            first.
          </>
        ) : (
          <>Say anything. Every listener hears it and the transcript appears on the right.</>
        )}{" "}
        End a turn by pausing, by saying &ldquo;done&rdquo;, or with the space bar.
      </p>
      <div className="mic-actions">
        <button
          className={`button${session.listening ? "" : " primary"}`}
          onClick={session.listening ? session.stopListening : session.startListening}
          disabled={!session.listening && session.recordingBusy}
        >
          {session.listening ? "Stop listening" : "Start listening"}
        </button>
        <button className="button quiet" onClick={openSetup}>
          Set up your voice
        </button>
      </div>
      <Settings
        endSilence={session.settings.endSilence}
        onEndSilence={session.settings.setEndSilence}
        speakReplies={session.settings.speakReplies}
        onSpeakReplies={session.settings.setSpeakReplies}
        autoListen={session.settings.autoListen}
        onAutoListen={session.settings.setAutoListen}
      />
    </div>
  );

  return (
    <main id="main" className="workspace">
      <div className="ws-head">
        <div>
          <h1 id="pipeline-title" className="ws-title" tabIndex={-1}>
            Pipeline
          </h1>
          <p className="muted">Hear a recording, or speak, and watch it go through every stage.</p>
        </div>
        <StatusPill session={session} />
      </div>

      <div className="ws-grid">
        <section className="ws-input" aria-label="Input and stages">
          <HearRecording
            hearing={session.hearing}
            busy={state?.busy ?? false}
            micPanel={micPanel}
            listening={session.listening}
            onHear={(choice) => {
              // On a narrow screen the result is below the input: go to it.
              const result = document.getElementById("result-area");
              if (result && result.getBoundingClientRect().top > window.innerHeight * 0.6) {
                const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
                result.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
              }
              void session.hearRecording(choice);
            }}
            onStop={session.stopHearing}
            onDismiss={session.dismissHearing}
          />
          <details className="ws-card stages-card">
            <summary>
              <span>Stages</span>
              <span className="muted">Switch one off to see what it adds</span>
            </summary>
            <StageSwitchPanel switches={ownState?.switches ?? ALL_ON} onChange={(s) => session.own?.setSwitches(s)} />
          </details>
        </section>

        <div className="ws-main" id="result-area">
          {session.notice && (
            <div className="notice" role="alert">
              <p>{session.notice}</p>
              <button className="button small quiet" onClick={session.dismissNotice}>
                Dismiss
              </button>
            </div>
          )}
          <TranscriptResult turn={turn} pending={pendingLabel} />
          {!turn && !pendingLabel && <EmptyResult />}
          <div id="pipeline">
            <Pipeline
              turn={turn}
              live={live}
              listening={session.listening}
              entryCount={entryCount}
              onStart={session.startListening}
              micBlocked={session.recordingBusy}
              onEndTurn={session.endTurn}
              acting={session.settings.actOnSpeech}
            />
          </div>
          <section className="ws-section" aria-labelledby="compare-title">
            <h2 id="compare-title">Side by side</h2>
            <p className="muted">The last two results. Hear the same recording again with a stage switched off to see what it adds.</p>
            <Compare turns={ownState?.turns ?? []} />
          </section>
        </div>

        <section className="ws-inspector" aria-label="Inspector">
          <div className="inspector-body">
            <PhrasebookPanel
              entries={session.voiceInUse?.phrasebook ?? state?.entries ?? []}
              justLearned={session.voiceInUse ? [] : (state?.justLearned ?? [])}
              clipCount={state?.clipCount ?? 0}
              scope={session.voiceInUse ? "voice" : state?.persistent === false ? "memory" : "yours"}
              voiceLabel={session.voiceInUse?.label}
              onForget={(id) => void session.own?.forget(id)}
              onClear={() => void session.own?.clearEverything()}
              onSetup={openSetup}
            />
            {/* Closed, a <details> hides its content from screen readers too. The conversation log must still be heard turn by turn, so it stays outside, visually hidden, until it is shown inside. */}
            {!logShown && (
              <div className="visually-hidden">
                <ConversationLog chat={state?.chat ?? []} />
              </div>
            )}
            <details className="ws-card stages-card advanced-card" open={advancedOpen} onToggle={(e) => setAdvancedOpen(e.currentTarget.open)}>
              <summary>
                <span>Advanced</span>
                <span className="muted">Optional: acting on what was heard, on a pretend phone</span>
              </summary>
              <label className="advanced-switch">
                <input type="checkbox" checked={session.settings.actOnSpeech} onChange={(e) => session.settings.setActOnSpeech(e.target.checked)} />
                <span>
                  <strong>Act on what I say</strong>
                  <span className="muted">Off: speech is only written down. On: it goes to the pretend phone, which acts or asks first.</span>
                </span>
              </label>
              <div className="segmented full" role="group" aria-label="Show">
                {(["phone", "conversation"] as Advanced[]).map((tab) => (
                  <button key={tab} aria-pressed={advanced === tab} className={advanced === tab ? "on" : ""} onClick={() => setAdvanced(tab)}>
                    {tab === "phone" ? "Phone" : "Conversation"}
                  </button>
                ))}
              </div>
              {logShown && <ConversationLog chat={state?.chat ?? []} />}
              {advanced === "phone" && <Phone phone={state?.phone ?? PHONE_HOME} />}
            </details>
          </div>
        </section>
      </div>

      <Enrolment
        state={session.enrol}
        liveText={live.text}
        listening={session.listening}
        onAgain={() => session.setEnrol((e) => ({ ...e, status: "listening", result: undefined, error: undefined }))}
        onSkip={() => session.setEnrol((e) => ({ ...e, index: e.index + 1, status: "listening", result: undefined }))}
        onClose={() => session.setEnrol((e) => ({ ...e, open: false }))}
      />
      <div className="visually-hidden" aria-live="polite">
        {announcement}
      </div>
      <MobileDock session={session} />
    </main>
  );
}

function StatusPill({ session }: { session: Session }) {
  const step = session.hearing.step;
  const [tone, words] =
    step === "loading" || step === "setup"
      ? ["busy", "Preparing the recording"]
      : step === "playing"
        ? ["live", "Playing the recording"]
        : step === "hearing" || session.state?.busy
          ? ["busy", "Hearing"]
          : session.listening
            ? ["live", "Microphone on"]
            : ["idle", "Ready"];
  return (
    <span className={`status-pill ${tone}`} role="status">
      <span className="dot" aria-hidden="true" />
      {words}
    </span>
  );
}

/**
 * On a phone the input panel scrolls away, so while a recording is being prepared, played or
 * heard, a bar along the bottom of the screen says so and offers Stop. Hidden on wide screens,
 * where the input column stays in view.
 */
function MobileDock({ session }: { session: Session }) {
  const { hearing } = session;
  if (hearing.step === "idle" || hearing.step === "error") return null;
  const words =
    hearing.step === "loading"
      ? "Loading the recording"
      : hearing.step === "setup"
        ? `Setting up the voice: ${hearing.done} of ${hearing.total}`
        : hearing.step === "playing"
          ? "Playing the recording"
          : "Hearing it";
  return (
    <div className="mobile-dock" aria-hidden="true">
      <span className="dot" />
      <span className="mobile-dock-words">
        <strong>{words}</strong>
        <span>{hearing.label}</span>
      </span>
      {hearing.step !== "hearing" && (
        <button className="button small" tabIndex={-1} onClick={session.stopHearing}>
          Stop
        </button>
      )}
    </div>
  );
}

function EmptyResult() {
  return (
    <div className="empty-result">
      <h2>Nothing heard yet</h2>
      <p>Pick a recording on the left, upload your own, or switch to the microphone and speak. The transcript appears here, scored word by word.</p>
    </div>
  );
}
