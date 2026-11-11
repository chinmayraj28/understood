// The page: a short story, a recording to hear (TORGO or your own file), its transcript scored
// against what was said, the pipeline line with the phone beside it, the stage switches, and the
// evaluation. Speaking live still works too.

import { useEffect, useRef, useState } from "react";
import { Compare, Settings, StageSwitchPanel } from "./components/Compare";
import { Dataset } from "./components/Dataset";
import { Enrolment, ENROLMENT_START } from "./components/Enrolment";
import { Evaluation } from "./components/Evaluation";
import { HearRecording } from "./components/HearRecording";
import { TranscriptResult } from "./components/TranscriptResult";
import { Phone } from "./components/Phone";
import { Pipeline } from "./components/Pipeline";
import { ConversationLog, PhrasebookPanel } from "./components/SidePanels";
import { loadDataset } from "./model/datasetLoader";
import { PHONE_HOME } from "./model/phone";
import { ALL_ON, pageAnnouncement } from "./model/turn";
import { useSession } from "./useSession";

/** Which view the address shows: "#dataset…" is the recordings; anything else is the pipeline. */
const viewFromHash = () => (window.location.hash.startsWith("#dataset") ? "dataset" : "pipeline");
/** "#hear=F03-S3-0012" asks the pipeline to hear that TORGO clip (the recordings view links here). */
const clipFromHash = () => (window.location.hash.startsWith("#hear=") ? decodeURIComponent(window.location.hash.slice(6)) : null);

export function App() {
  const session = useSession();
  const { state, ownState, live } = session;
  const [view, setView] = useState<"pipeline" | "dataset">(viewFromHash);

  useEffect(() => {
    const onHash = () => setView(viewFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  // A recording playing out of the speakers would be heard as the person's own turn, so the
  // microphone stops when the recordings open. If it was on, it comes back on with the pipeline,
  // so a hands-free visitor does not lose their voice control.
  const { listening, stopListening, startListening, hearRecording, stopHearing } = session;
  const resumeListening = useRef(false);
  useEffect(() => {
    if (view === "dataset") {
      stopHearing();
      if (listening) {
        resumeListening.current = true;
        stopListening();
      }
    } else if (resumeListening.current) {
      resumeListening.current = false;
      void startListening();
    }
  }, [view, listening, stopListening, startListening, stopHearing]);

  // A clip chosen in the recordings view is heard here, once the page is ready for it.
  const ready = session.own !== null;
  useEffect(() => {
    if (!ready) return;
    const hearFromHash = () => {
      const id = clipFromHash();
      if (!id) return;
      history.replaceState(null, "", "#top");
      setView("pipeline");
      // Take the visitor to the recording panel, where its progress is shown.
      requestAnimationFrame(() => {
        const title = document.getElementById("hear-title");
        const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        title?.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
        title?.focus({ preventScroll: true });
      });
      void loadDataset().then((load) => {
        if (load.status !== "ready") return;
        const clip = load.index.clips.find((c) => c.id === id);
        if (clip) void hearRecording({ kind: "torgo", clip, index: load.index });
      });
    };
    hearFromHash();
    window.addEventListener("hashchange", hearFromHash);
    return () => window.removeEventListener("hashchange", hearFromHash);
  }, [ready, hearRecording]);

  useEffect(() => {
    document.title = view === "dataset" ? "Recordings · Understood" : "Understood";
  }, [view]);
  const turn = state?.turns[state.turns.length - 1];
  // Setup works on your own voice: open the microphone if it is off.
  const openSetup = () => {
    session.stopHearing();
    session.setEnrol({ ...ENROLMENT_START, open: true });
    if (!session.listening) void session.startListening();
  };

  // Screen readers hear each turn once, through the conversation log; this adds only failures.
  const announcement = pageAnnouncement(turn);

  return (
    <>
      {view === "dataset" ? (
        <a className="skip-link" href="#dataset-title">
          Skip to the recordings
        </a>
      ) : (
        <a className="skip-link" href="#pipeline">
          Skip to the pipeline
        </a>
      )}
      <header className="masthead">
        <a className="wordmark" href="#top" aria-label="Understood, home">
          <ForkMark />
          Understood
        </a>
        <nav className="views" aria-label="Views">
          <a className="view-tab" href="#top" aria-current={view === "pipeline" ? "page" : undefined}>
            Pipeline
          </a>
          <a className="view-tab" href="#dataset" aria-current={view === "dataset" ? "page" : undefined}>
            Recordings
          </a>
        </nav>
        {view === "pipeline" && (
          <div className="masthead-actions">
            <button className="button quiet small" onClick={openSetup}>
              Set up your voice
            </button>
            <button
              className={`button small${session.listening ? "" : " primary"}`}
              onClick={session.listening ? session.stopListening : session.startListening}
              disabled={!session.listening && session.recordingBusy}
              title={!session.listening && session.recordingBusy ? "The microphone opens when the recording has finished playing" : undefined}
            >
              {session.listening ? "Stop listening" : "Start listening"}
            </button>
          </div>
        )}
      </header>

      {view === "dataset" ? (
        <main className="page" id="top">
          <Dataset />
        </main>
      ) : (
      <main className="page" id="top">
        <section className="intro" aria-labelledby="intro-title">
          <h1 id="intro-title">A voice assistant that understands speech other assistants get wrong.</h1>
          <p className="intro-text">
            Voice assistants fail people with dysarthria: slow, slurred or quiet speech, common with ALS, cerebral palsy, Parkinson&rsquo;s
            and stroke. Often they cannot use their hands either, so voice is their only way in. On severe dysarthria, recognisers get over
            49% of words wrong, yet the meaning often survives. Here each recording is heard by three recognisers, checked against the
            speaker&rsquo;s phrasebook and repaired by Claude into one transcript. Hear a real recording of a person with dysarthria, or your
            own file, and every step is shown below with its real timings and the words it got right and wrong.
          </p>
        </section>

        <HearRecording
          hearing={session.hearing}
          busy={state?.busy ?? false}
          onHear={(choice) => {
            // Go down to the result, where the recording is about to play.
            const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
            document.getElementById("pipeline")?.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
            void session.hearRecording(choice);
          }}
          onStop={session.stopHearing}
          onDismiss={session.dismissHearing}
        />

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
            <TranscriptResult turn={turn} />
            <Pipeline
              turn={turn}
              live={live}
              listening={session.listening}
              entryCount={session.voiceInUse?.phrasebook.length ?? state?.entries.length ?? 0}
              onStart={session.startListening}
              micBlocked={session.recordingBusy}
              onEndTurn={session.endTurn}
            />
          </div>
          <aside className="side" aria-label="The assistant's side">
            <Phone phone={state?.phone ?? PHONE_HOME} />
            <ConversationLog chat={state?.chat ?? []} />
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
          </aside>
        </div>

        <section className="section" id="try" aria-labelledby="try-title">
          <h2 id="try-title">Switch a stage off</h2>
          <p>
            Hear a recording, switch one stage off, and hear the same recording again. The two results appear side by side, so you can see
            what that stage adds.
          </p>
          <div className="try-grid">
            <StageSwitchPanel switches={ownState?.switches ?? ALL_ON} onChange={(s) => session.own?.setSwitches(s)} />
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
          <p>Measured on real recordings of people with dysarthria, each stage added to the one before. Words wrong is the share of the words said that the transcript got wrong.</p>
          <Evaluation />
        </section>

        <footer className="footer">
          <p>
            Your phrasebook and voice clips stay in this browser. Each turn&rsquo;s audio is sent to the server only to be heard, and the
            server keeps nothing. The phone is pretend: nothing is really sent or called.
          </p>
          <p className="muted">
            Voice commands for this page: &ldquo;set up my voice&rdquo;, &ldquo;stop listening&rdquo;. End a spoken turn by pausing, by
            saying &ldquo;done&rdquo;, or with the space bar.
          </p>
        </footer>
      </main>
      )}

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
