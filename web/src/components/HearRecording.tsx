// Where a turn starts: the microphone, an audio file, or a TORGO recording. A file or a TORGO
// clip plays aloud and goes through the whole pipeline, heard as the voice chosen under "Hear it
// as" (one of your profiles, or a TORGO speaker), and the transcript is scored against what was
// really said.

import { useEffect, useId, useMemo, useState, type DragEvent, type ReactNode } from "react";
import type { DatasetClip, DatasetIndex } from "../../shared/dataset";
import { MAX_FILE_SECONDS } from "../audio/decode";
import { loadDataset, type DatasetLoad } from "../model/datasetLoader";
import { orderSpeakers, secondsLabel, speakerDescription } from "../model/dataset";
import type { HearingStatus, RecordingChoice, VoiceId } from "../useSession";
import { MAX_PROFILE_CLIPS, MIN_PROFILE_CLIPS, setupClipsFor } from "../model/voices";
import type { Profile } from "../storage/profiles";
import { VoiceSelect, voiceStillThere } from "./VoiceSelect";

type Source = "mic" | "file" | "torgo";
const SOURCES: { id: Source; label: string }[] = [
  { id: "mic", label: "Microphone" },
  { id: "file", label: "Your file" },
  { id: "torgo", label: "TORGO" },
];
const SHOWN = 12;
/** Larger files are refused before decoding; a minute of WAV at 48 kHz stereo is about 11 MB. */
const MAX_FILE_BYTES = 40 * 1024 * 1024;

export function HearRecording(props: {
  hearing: HearingStatus;
  busy: boolean;
  /** What the "Microphone" source shows: start listening, set up your voice, settings. */
  micPanel: ReactNode;
  listening: boolean;
  profiles: Profile[];
  activeProfileId: string;
  onHear: (choice: RecordingChoice) => void;
  onStop: () => void;
  onDismiss: () => void;
}) {
  const [load, setLoad] = useState<DatasetLoad | null>(null);
  // Opens on the microphone, the first source; after that only the visitor changes it, so the
  // microphone coming back on after a recording does not throw away their pick.
  const [source, setSource] = useState<Source>("mic");
  useEffect(() => {
    let gone = false;
    void loadDataset().then((result) => {
      if (gone) return;
      setLoad(result);
      if (result.status !== "ready") setSource((s) => (s === "torgo" ? "file" : s));
    });
    return () => {
      gone = true;
    };
  }, []);
  const index = load?.status === "ready" ? load.index : undefined;
  const working = props.hearing.step !== "idle" && props.hearing.step !== "error";

  return (
    <section className="hear" aria-labelledby="hear-title">
      <div className="hear-head">
        <h2 id="hear-title" tabIndex={-1}>
          Input
        </h2>
        <div className="segmented" role="group" aria-label="Where the recording comes from">
          {SOURCES.map((s) => (
            <button key={s.id} aria-pressed={source === s.id} className={source === s.id ? "on" : ""} onClick={() => setSource(s.id)}>
              {s.label}
            </button>
          ))}
        </div>
      </div>

      {/* All three stay mounted and only the chosen one shows, so switching back keeps the
          speaker, filter, search and chosen file as the visitor left them. */}
      <div hidden={source !== "mic"}>{props.micPanel}</div>
      <div hidden={source !== "file"}>
        <FilePicker index={index} disabled={working || props.busy} profiles={props.profiles} activeProfileId={props.activeProfileId} onHear={props.onHear} />
      </div>
      <div hidden={source !== "torgo"}>
        {index ? (
          <TorgoPicker index={index} disabled={working || props.busy} profiles={props.profiles} activeProfileId={props.activeProfileId} onHear={props.onHear} />
        ) : (
          <p className="muted">{load === null ? "Loading the recordings…" : load.status === "missing" ? load.reason : "The recordings couldn’t be loaded. Is the server running?"}</p>
        )}
      </div>

      <HearingLine hearing={props.hearing} onStop={props.onStop} onDismiss={props.onDismiss} />
    </section>
  );
}

interface PickerProps {
  disabled: boolean;
  profiles: Profile[];
  activeProfileId: string;
  onHear: (choice: RecordingChoice) => void;
}

/**
 * TORGO, in three steps: the speaker; the profile clips their voice is learned from (the
 * evaluation's set-up clips unless changed); then a clip to transcribe, which can never be one of
 * the profile clips, so the pipeline is not tested on a recording it learned from.
 */
function TorgoPicker({ index, disabled, onHear }: PickerProps & { index: DatasetIndex }) {
  const speakers = useMemo(() => orderSpeakers(index.speakers), [index.speakers]);
  const [speaker, setSpeaker] = useState(() => speakers[0]?.id ?? "");
  // The profile clips chosen per speaker. A speaker without an entry uses the evaluation's.
  const [chosenProfiles, setChosenProfiles] = useState<Record<string, string[]>>({});
  const [editing, setEditing] = useState(false);
  const ids = { speaker: useId(), which: useId() };

  const speakerClips = useMemo(() => index.clips.filter((c) => c.speaker === speaker), [index.clips, speaker]);
  const defaultProfile = useMemo(() => setupClipsFor(index, speaker).map((c) => c.id), [index, speaker]);
  const profileIds = chosenProfiles[speaker] ?? defaultProfile;
  const isDefault = !chosenProfiles[speaker];
  const inProfile = useMemo(() => new Set(profileIds), [profileIds]);

  // Every clip outside the profile, test clips (the fair ones) first.
  const clips = useMemo(() => speakerClips.filter((c) => !inProfile.has(c.id)), [speakerClips, inProfile]);
  const testClips = useMemo(() => clips.filter((c) => c.split === "test"), [clips]);
  const otherClips = useMemo(() => clips.filter((c) => c.split !== "test"), [clips]);
  const randomPool = testClips.length > 0 ? testClips : clips;
  const [pickedId, setPickedId] = useState("");
  const picked = clips.find((c) => c.id === pickedId) ?? testClips[0] ?? clips[0];
  const choose = (clip: DatasetClip) => onHear({ kind: "torgo", clip, index, profileClipIds: isDefault ? undefined : profileIds });
  const description = speakerDescription(index.speakers.find((s) => s.id === speaker));
  const setProfile = (next: string[]) => setChosenProfiles((all) => ({ ...all, [speaker]: next }));

  return (
    <div className="torgo-picker">
      <section className="torgo-step" aria-labelledby={`${ids.speaker}-step`}>
        <h3 id={`${ids.speaker}-step`} className="torgo-step-title">
          <span className="step-number" aria-hidden="true">1</span> Speaker
        </h3>
        <label htmlFor={ids.speaker} className="visually-hidden">
          Speaker
        </label>
        <select
          id={ids.speaker}
          value={speaker}
          onChange={(e) => {
            setSpeaker(e.target.value);
            setEditing(false);
          }}
        >
          {speakers.map((s) => (
            <option key={s.id} value={s.id}>
              {s.id}: {speakerDescription(s)}
            </option>
          ))}
        </select>
      </section>

      <section className="torgo-step" aria-labelledby={`${ids.speaker}-profile`}>
        <div className="torgo-step-head">
          <h3 id={`${ids.speaker}-profile`} className="torgo-step-title">
            <span className="step-number" aria-hidden="true">2</span> Profile clips
          </h3>
          <button className="button small quiet" aria-expanded={editing} onClick={() => setEditing((e) => !e)}>
            {editing ? "Done" : "Change"}
          </button>
        </div>
        <p className="muted hear-note">
          <strong className="num">{profileIds.length}</strong> of {speaker}&rsquo;s clips{" "}
          {isDefault ? <>(the evaluation&rsquo;s set-up clips)</> : <>(your choice)</>}. The pipeline learns {speaker}&rsquo;s voice from
          them: both Gemini models are shown 5, and the phrasebook and Claude&rsquo;s known phrases come from all of them.
        </p>
        {editing && (
          <ProfileClipEditor
            clips={speakerClips}
            selected={inProfile}
            onChange={setProfile}
            onReset={() => setChosenProfiles(({ [speaker]: _, ...rest }) => rest)}
            isDefault={isDefault}
          />
        )}
      </section>

      <section className="torgo-step" aria-labelledby={`${ids.speaker}-pick`}>
        <h3 id={`${ids.speaker}-pick`} className="torgo-step-title">
          <span className="step-number" aria-hidden="true">3</span> Clip to transcribe
        </h3>
        <label htmlFor={ids.which} className="visually-hidden">
          Phrase
        </label>
        <select id={ids.which} value={picked?.id ?? ""} onChange={(e) => setPickedId(e.target.value)} disabled={clips.length === 0}>
          {clips.length === 0 && <option value="">No clips left outside the profile</option>}
          {testClips.length > 0 && (
            <optgroup label="Test clips (a fair test)">
              {testClips.map((clip) => (
                <option key={clip.id} value={clip.id}>
                  {clipLabel(clip)}
                </option>
              ))}
            </optgroup>
          )}
          {otherClips.length > 0 && (
            <optgroup label="Other set-up clips">
              {otherClips.map((clip) => (
                <option key={clip.id} value={clip.id}>
                  {clipLabel(clip)}
                </option>
              ))}
            </optgroup>
          )}
        </select>
        <div className="torgo-pick-actions">
          <button className="button primary" disabled={disabled || !picked} onClick={() => picked && choose(picked)}>
            Transcribe
          </button>
          <button className="button" disabled={disabled || clips.length === 0} onClick={() => choose(randomPool[Math.floor(Math.random() * randomPool.length)])}>
            Pick one at random
          </button>
        </div>
        <p className="muted hear-note">
          {speaker}: {description || "no description"}. The profile clips are left out{testClips.length > 0 ? "; a random pick is always a test clip" : ""}.
        </p>
      </section>
    </div>
  );
}

/** A clip in the phrase list: "“Up” · word · 1.2 s". */
function clipLabel(clip: DatasetClip): string {
  return `“${clip.prompt}” · ${clip.kind === "sentence" ? "sentence" : "word"} · ${secondsLabel(clip.seconds)}`;
}

/** Ticks which of the speaker's clips make up their profile: at least 3, at most 40. */
function ProfileClipEditor(props: {
  clips: DatasetClip[];
  selected: Set<string>;
  onChange: (ids: string[]) => void;
  onReset: () => void;
  isDefault: boolean;
}) {
  const [query, setQuery] = useState("");
  const [shown, setShown] = useState(SHOWN);
  const field = useId();
  const count = props.selected.size;
  // The chosen clips first, then the rest; set-up clips before test clips.
  const ordered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const rank = (c: DatasetClip) => (props.selected.has(c.id) ? 0 : c.split === "enrolment" ? 1 : 2);
    return props.clips.filter((c) => !q || c.prompt.toLowerCase().includes(q)).sort((a, b) => rank(a) - rank(b));
    // Ordered when opened or searched, not on every tick, so a ticked clip does not jump away.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.clips, query]);
  const toggle = (id: string) => {
    const next = new Set(props.selected);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    props.onChange([...next]);
  };

  return (
    <div className="profile-clips">
      <div className="profile-clips-bar">
        <label htmlFor={field} className="grow">
          <span className="visually-hidden">Search the speaker&rsquo;s clips</span>
          <input id={field} type="search" value={query} placeholder="Search their clips" onChange={(e) => setQuery(e.target.value)} />
        </label>
        <button className="button small quiet" disabled={props.isDefault} onClick={props.onReset}>
          Reset
        </button>
      </div>
      <p className="muted hear-note" role="status">
        {count} chosen. At least {MIN_PROFILE_CLIPS}, at most {MAX_PROFILE_CLIPS}. Choosing a test clip here takes it out of the fair test.
      </p>
      <ul className="profile-clip-list">
        {ordered.slice(0, shown).map((clip) => {
          const on = props.selected.has(clip.id);
          const locked = (on && count <= MIN_PROFILE_CLIPS) || (!on && count >= MAX_PROFILE_CLIPS);
          return (
            <li key={clip.id}>
              <label className={`profile-clip${on ? " on" : ""}`}>
                <input type="checkbox" checked={on} disabled={locked} onChange={() => toggle(clip.id)} />
                <span className="pick-prompt">&ldquo;{clip.prompt}&rdquo;</span>
                <span className="pick-meta">{clip.split === "test" ? "test" : "set-up"}</span>
              </label>
            </li>
          );
        })}
      </ul>
      {shown < ordered.length && (
        <button className="button quiet small" onClick={() => setShown((n) => n + SHOWN)}>
          Show more ({ordered.length - shown} left)
        </button>
      )}
    </div>
  );
}

function FilePicker({ index, disabled, profiles, activeProfileId, onHear }: PickerProps & { index?: DatasetIndex }) {
  const [file, setFile] = useState<File | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [reference, setReference] = useState("");
  // Until the visitor picks one, the profile in use.
  const [chosenVoice, setVoiceId] = useState<VoiceId | null>(null);
  const voiceId = voiceStillThere(chosenVoice, profiles, `profile:${activeProfileId}`);
  const [over, setOver] = useState(false);
  const ids = { file: useId(), reference: useId() };
  const speakers = useMemo(() => (index ? orderSpeakers(index.speakers) : []), [index]);

  const pick = (chosen: File | undefined) => {
    setProblem(null);
    if (!chosen) return;
    if (chosen.size > MAX_FILE_BYTES) {
      setFile(null);
      return setProblem("This file is too large. Use a recording of a minute or less.");
    }
    setFile(chosen);
  };
  const onDrop = (event: DragEvent) => {
    event.preventDefault();
    setOver(false);
    pick(event.dataTransfer.files[0]);
  };
  const hear = async () => {
    if (!file) return;
    onHear({ kind: "file", name: file.name, data: await file.arrayBuffer(), reference, voiceId, index });
  };

  return (
    <div className="file-picker">
      <label
        htmlFor={ids.file}
        className={`drop${over ? " over" : ""}${file ? " chosen" : ""}`}
        onDragOver={(e) => {
          e.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <span className="drop-main">{file ? file.name : "Choose an audio file, or drop one here"}</span>
        <span className="muted">
          {file ? `${(file.size / 1024).toFixed(0)} KB. Choose another to replace it.` : `WAV, MP3, M4A, OGG or WebM, up to ${MAX_FILE_SECONDS} seconds. It is decoded in this browser.`}
        </span>
        <input id={ids.file} type="file" accept="audio/*,.wav,.mp3,.m4a,.ogg,.webm,.flac" className="visually-hidden" onChange={(e) => pick(e.target.files?.[0])} />
      </label>
      {problem && <p role="alert">{problem}</p>}
      <div className="hear-fields">
        <label htmlFor={ids.reference} className="grow">
          <span>What was said (optional, to score the transcript)</span>
          <input id={ids.reference} type="text" value={reference} placeholder="e.g. Message Sam I'm running late" onChange={(e) => setReference(e.target.value)} />
        </label>
        <VoiceSelect value={voiceId} onChange={setVoiceId} profiles={profiles} activeProfileId={activeProfileId} speakers={speakers} />
        <button className="button primary" disabled={!file || disabled} onClick={() => void hear()}>
          Hear it
        </button>
      </div>
    </div>
  );
}

function HearingLine({ hearing, onStop, onDismiss }: { hearing: HearingStatus; onStop: () => void; onDismiss: () => void }) {
  if (hearing.step === "idle") return null;
  if (hearing.step === "error") {
    return (
      <div className="hearing-line error" role="alert">
        <p>{hearing.message}</p>
        <button className="button small quiet" onClick={onDismiss}>
          Dismiss
        </button>
      </div>
    );
  }
  const words =
    hearing.step === "loading"
      ? `Loading ${hearing.label}…`
      : hearing.step === "setup"
        ? `Setting up the voice of ${hearing.voiceLabel} from their own set-up clips: ${hearing.done} of ${hearing.total} heard.`
        : hearing.step === "playing"
          ? `Playing ${hearing.label} while the live recogniser listens…`
          : `Hearing ${hearing.label} through the pipeline…`;
  return (
    <div className="hearing-line" role="status">
      <p>{words}</p>
      {hearing.step === "setup" && (
        <progress max={hearing.total} value={hearing.done} aria-label="Voice setup">
          {hearing.done} of {hearing.total}
        </progress>
      )}
      {hearing.step !== "hearing" && (
        <button className="button small quiet" onClick={onStop}>
          Stop
        </button>
      )}
    </div>
  );
}
