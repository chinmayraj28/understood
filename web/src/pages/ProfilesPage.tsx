// Profiles: whose voice the pipeline hears. A plain list of your profiles, each with its own
// phrasebook and voice clips kept only in this browser, and a "New profile" form in a dialog:
// a name, then at least three phrases read aloud. A profile is only kept once those are recorded.
// The TORGO speakers are listed at the bottom: built-in profiles, set up automatically.

import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import type { DatasetSpeaker } from "../../shared/dataset";
import { EnrolmentBody } from "../components/Enrolment";
import { orderSpeakers, speakerDescription } from "../model/dataset";
import { loadDataset } from "../model/datasetLoader";
import { SETUP_PHRASES } from "../model/enrolment";
import { SETUP_CLIP_LIMIT } from "../model/voices";
import { MAX_NAME_LENGTH, MIN_SETUP_PHRASES, type Profile } from "../storage/profiles";
import type { ProfileSummary, useSession } from "../useSession";

type Session = ReturnType<typeof useSession>;
/** What the dialog is doing: making a new profile, or recording more phrases for one. */
type DialogMode = { kind: "create" } | { kind: "record"; profile: Profile };

export function ProfilesPage({ session, create }: { session: Session; create?: boolean }) {
  const { profiles, activeProfile, summariseProfile } = session;
  const [summaries, setSummaries] = useState<Record<string, ProfileSummary>>({});
  const [speakers, setSpeakers] = useState<DatasetSpeaker[] | null>(null);
  const [dialog, setDialog] = useState<DialogMode | null>(null);
  // Re-counted whenever the profile in use learns something.
  const learnedNow = `${session.state?.entries.length ?? 0}/${session.state?.clipCount ?? 0}`;

  // "#/profiles?new" (the pipeline's profile list links here) opens the form once.
  useEffect(() => {
    if (!create) return;
    history.replaceState(null, "", "#/profiles");
    setDialog({ kind: "create" });
  }, [create]);

  useEffect(() => {
    let gone = false;
    void Promise.all(profiles.map(async (p) => [p.id, await summariseProfile(p.id).catch(() => undefined)] as const)).then((pairs) => {
      if (gone) return;
      setSummaries(Object.fromEntries(pairs.filter((pair): pair is readonly [string, ProfileSummary] => pair[1] !== undefined)));
    });
    return () => {
      gone = true;
    };
  }, [profiles, activeProfile.id, summariseProfile, learnedNow]);

  useEffect(() => {
    let gone = false;
    void loadDataset().then((load) => {
      if (!gone) setSpeakers(load.status === "ready" ? orderSpeakers(load.index.speakers) : []);
    });
    return () => {
      gone = true;
    };
  }, []);

  return (
    <main id="main" className="profiles-page">
      <header className="profiles-head">
        <div>
          <h1 id="profiles-title" tabIndex={-1}>
            Profiles
          </h1>
          <p className="muted">Each profile is one voice the pipeline knows. Kept only in this browser.</p>
        </div>
        <button className="button primary" onClick={() => setDialog({ kind: "create" })} disabled={session.own === null}>
          ＋ New profile
        </button>
      </header>

      <ul className="profile-list" aria-label="Your profiles">
        {profiles.map((profile) => (
          <ProfileRow
            key={profile.id}
            profile={profile}
            active={profile.id === activeProfile.id}
            summary={summaries[profile.id]}
            ready={session.own !== null}
            onUse={() => void session.selectProfile(profile.id)}
            onRecord={() => setDialog({ kind: "record", profile })}
            onRename={(name) => session.renameProfile(profile.id, name)}
            onDelete={() => void session.deleteProfile(profile.id)}
          />
        ))}
      </ul>

      <details className="torgo-voices">
        <summary>
          Built-in TORGO speakers <span className="muted">{speakers ? `(${speakers.length})` : ""}</span>
        </summary>
        <p className="muted">
          Read only. Each is set up automatically the first time one of their clips is heard, from {SETUP_CLIP_LIMIT} of their set-up clips.
        </p>
        {speakers === null ? (
          <p className="muted">Loading…</p>
        ) : speakers.length === 0 ? (
          <p className="muted">The TORGO recordings aren&rsquo;t on this computer.</p>
        ) : (
          <ul className="torgo-voice-list">
            {speakers.map((s) => (
              <li key={s.id}>
                <span className="num">{s.id}</span> {speakerDescription(s) || "no description"}
              </li>
            ))}
          </ul>
        )}
      </details>

      {dialog && <ProfileDialog key={dialog.kind === "create" ? "create" : dialog.profile.id} mode={dialog} session={session} onDone={() => setDialog(null)} />}
    </main>
  );
}

function ProfileRow(props: {
  profile: Profile;
  active: boolean;
  summary?: ProfileSummary;
  ready: boolean;
  onUse: () => void;
  onRecord: () => void;
  onRename: (name: string) => void;
  onDelete: () => void;
}) {
  const { profile, summary } = props;
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(profile.name);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const field = useId();

  const saveName = (event: FormEvent) => {
    event.preventDefault();
    if (draft.trim()) props.onRename(draft);
    setRenaming(false);
  };

  return (
    <li className={`profile-item${props.active ? " active" : ""}`} aria-current={props.active ? "true" : undefined}>
      <span className="profile-avatar" aria-hidden="true">
        {initials(profile.name)}
      </span>
      <div className="profile-main">
        {renaming ? (
          <form className="profile-rename" onSubmit={saveName}>
            <label htmlFor={field} className="visually-hidden">
              Name
            </label>
            <input
              id={field}
              type="text"
              value={draft}
              maxLength={MAX_NAME_LENGTH}
              autoFocus
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  setDraft(profile.name);
                  setRenaming(false);
                }
              }}
            />
            <button type="submit" className="button small">
              Save
            </button>
          </form>
        ) : (
          <p className="profile-name">
            {profile.name} {props.active && <span className="badge live">In use</span>}
          </p>
        )}
        <p className="profile-meta muted">
          {summary
            ? `${summary.clips} ${summary.clips === 1 ? "phrase" : "phrases"} recorded · ${summary.entries} in the phrasebook`
            : "…"}
        </p>
      </div>
      <div className="profile-actions">
        {!props.active && (
          <button className="button small" disabled={!props.ready} onClick={props.onUse}>
            Use
          </button>
        )}
        <button className="button small quiet" disabled={!props.ready} onClick={props.onRecord}>
          Record phrases
        </button>
        <button
          className="button small quiet"
          onClick={() => {
            setDraft(profile.name);
            setRenaming(true);
          }}
        >
          Rename
        </button>
        <button
          className={`button small quiet${confirmDelete ? " danger" : ""}`}
          onClick={() => (confirmDelete ? props.onDelete() : setConfirmDelete(true))}
          onBlur={() => setConfirmDelete(false)}
          aria-label={confirmDelete ? `Press again to delete ${profile.name} and everything it learned` : `Delete ${profile.name}`}
        >
          {confirmDelete ? "Press again to delete" : "Delete"}
        </button>
      </div>
    </li>
  );
}

/**
 * The dialog. Making a profile: a name, then phrases read aloud; "Save profile" is only offered
 * once three are recorded, and cancelling deletes the half-made profile and what it recorded.
 * Recording for an existing profile: the same phrases, finished at any point.
 */
function ProfileDialog({ mode, session, onDone }: { mode: DialogMode; session: Session; onDone: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [step, setStep] = useState<"name" | "record">(mode.kind === "create" ? "name" : "record");
  const [name, setName] = useState("");
  const [draftId, setDraftId] = useState<string | null>(null);
  const previous = useRef(session.activeProfile.id);
  const closing = useRef(false);
  const field = useId();
  const { enrol } = session;
  const count = enrol.done.filter(Boolean).length;
  const enough = count >= MIN_SETUP_PHRASES;
  // While a phrase is being heard it is about to be saved: cancelling waits for it.
  const hearing = step === "record" && enrol.status === "hearing";
  const title = mode.kind === "create" ? "New profile" : `Record phrases for “${mode.profile.name}”`;

  useEffect(() => {
    dialog.current?.showModal();
  }, []);

  // Recording more for an existing profile: use it, and start at once (this runs from the click).
  const started = useRef(false);
  useEffect(() => {
    if (mode.kind !== "record" || started.current) return;
    started.current = true;
    // Use it first, so Cancel can put back exactly what this profile knew.
    void session.selectProfile(mode.profile.id).then(() => session.openSetup());
    // Once, when the dialog opens.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Every phrase passed with too few recorded: go back to the first one not yet recorded.
  useEffect(() => {
    if (step !== "record" || enrol.index < SETUP_PHRASES.length || enough) return;
    const next = enrol.done.findIndex((d) => !d);
    session.setEnrol((e) => ({ ...e, index: Math.max(0, next), status: session.listening ? "listening" : "idle", result: undefined }));
  }, [step, enrol.index, enrol.done, enough, session]);

  const finish = () => {
    closing.current = true;
    if (draftId) session.finishProfile(draftId);
    session.closeSetup(true);
    dialog.current?.close();
    onDone();
  };

  const cancel = async () => {
    closing.current = true;
    dialog.current?.close();
    onDone();
    if (mode.kind === "record") {
      // Undo this session: what it recorded and learned goes, re-recorded phrases get their old take back.
      await session.cancelSetup(true);
      return;
    }
    session.closeSetup(true);
    if (draftId) {
      // Back to the profile used before, then the half-made one goes, with everything it recorded.
      await session.selectProfile(previous.current);
      await session.deleteProfile(draftId);
    }
  };

  // Saying "finish" closes setup by voice: save if enough is recorded, otherwise keep going.
  // Only once setup has really been open: on the first render it has not started yet.
  const setupWasOpen = useRef(false);
  if (enrol.open) setupWasOpen.current = true;
  useEffect(() => {
    if (step !== "record" || enrol.open || closing.current || !setupWasOpen.current) return;
    if (enough || mode.kind === "record") finish();
    else session.setEnrol((e) => ({ ...e, open: true }));
    // Only when setup closes by itself.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enrol.open]);

  const start = (event: FormEvent) => {
    event.preventDefault();
    if (!name.trim()) return;
    // The microphone is asked for inside this click, so the browser shows its question.
    session.openSetup();
    const id = session.createProfile(name, { draft: true });
    setDraftId(id);
    void session.selectProfile(id);
    setStep("record");
  };

  return (
    <dialog
      ref={dialog}
      className="enrol profile-dialog"
      aria-labelledby="profile-dialog-title"
      onCancel={(e) => {
        e.preventDefault();
        if (!hearing) void cancel();
      }}
    >
      <div className="enrol-head">
        <h2 id="profile-dialog-title">
          {title}
          {step === "record" && mode.kind === "create" && <span className="enrol-profile">{name.trim()}</span>}
        </h2>
        <button className="dialog-close" onClick={() => void cancel()} disabled={hearing} aria-label="Cancel and close">
          ×
        </button>
      </div>

      {step === "name" ? (
        <form className="profile-form" onSubmit={start}>
          <label htmlFor={field}>
            <span>Name</span>
            <input
              id={field}
              type="text"
              value={name}
              maxLength={MAX_NAME_LENGTH}
              placeholder="e.g. Sam"
              autoFocus
              required
              onChange={(e) => setName(e.target.value)}
            />
          </label>
          <p className="muted">
            Next, you read a few short phrases aloud, so the pipeline learns how this voice sounds. At least {MIN_SETUP_PHRASES} are needed;
            all {SETUP_PHRASES.length} is best.
          </p>
          <div className="profile-form-actions">
            <button type="button" className="button quiet" onClick={() => void cancel()}>
              Cancel
            </button>
            <button type="submit" className="button primary" disabled={!name.trim()}>
              Continue
            </button>
          </div>
        </form>
      ) : (
        <>
          <EnrolmentBody
            state={enrol}
            liveText={session.live.text}
            listening={session.listening}
            micStatus={session.live.status}
            notice={session.notice}
            micBlocked={session.recordingBusy}
            micRefused={session.micRefused}
            micPermission={session.micPermission}
            onRecord={session.enrolRecord}
            onStop={session.enrolStop}
            onNext={session.enrolNext}
          />
          <div className="profile-form-actions">
            {mode.kind === "create" ? (
              <>
                <p className="muted profile-count" role="status">
                  {enough
                    ? `${count} recorded. Save now, or keep going for a better result.`
                    : `${count} of ${MIN_SETUP_PHRASES} recorded. ${MIN_SETUP_PHRASES} are needed to save.`}
                </p>
                <button className="button quiet" onClick={() => void cancel()} disabled={hearing}>
                  Cancel
                </button>
                <button className="button primary" disabled={!enough} onClick={finish}>
                  Save profile
                </button>
              </>
            ) : (
              <>
                <p className="muted profile-count" role="status">
                  {count} recorded this time. Cancel undoes them.
                </p>
                <button className="button quiet" onClick={() => void cancel()} disabled={hearing}>
                  Cancel
                </button>
                <button className="button primary" onClick={finish}>
                  Done
                </button>
              </>
            )}
          </div>
        </>
      )}
    </dialog>
  );
}

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "?") + (parts[1]?.[0] ?? "")).toUpperCase();
}
