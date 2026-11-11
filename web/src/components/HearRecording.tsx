// Where a turn starts when it is not spoken live: pick a TORGO recording, or choose an audio
// file. Either one plays aloud and goes through the whole pipeline, heard as the voice it
// belongs to, and the transcript is scored against what was really said.

import { useEffect, useId, useMemo, useState, type DragEvent, type ReactNode } from "react";
import type { DatasetClip, DatasetIndex } from "../../shared/dataset";
import { MAX_FILE_SECONDS } from "../audio/decode";
import { loadDataset, type DatasetLoad } from "../model/datasetLoader";
import { orderSpeakers, secondsLabel, speakerDescription } from "../model/dataset";
import type { HearingStatus, RecordingChoice, VoiceId } from "../useSession";
import { SETUP_CLIP_LIMIT } from "../model/voices";

type Source = "torgo" | "file" | "mic";
type Which = "test" | "all" | "enrolment";
const SHOWN = 12;
/** Larger files are refused before decoding; a minute of WAV at 48 kHz stereo is about 11 MB. */
const MAX_FILE_BYTES = 40 * 1024 * 1024;

export function HearRecording(props: {
  hearing: HearingStatus;
  busy: boolean;
  /** What the "Microphone" source shows: start listening, set up your voice, settings. */
  micPanel: ReactNode;
  listening: boolean;
  onHear: (choice: RecordingChoice) => void;
  onStop: () => void;
  onDismiss: () => void;
}) {
  const [load, setLoad] = useState<DatasetLoad | null>(null);
  const [source, setSource] = useState<Source>("torgo");
  useEffect(() => {
    let gone = false;
    void loadDataset().then((result) => {
      if (gone) return;
      setLoad(result);
      if (result.status !== "ready") setSource("file");
    });
    return () => {
      gone = true;
    };
  }, []);
  const index = load?.status === "ready" ? load.index : undefined;
  // A visitor who is speaking sees the microphone controls.
  useEffect(() => {
    if (props.listening) setSource("mic");
  }, [props.listening]);
  const working = props.hearing.step !== "idle" && props.hearing.step !== "error";

  return (
    <section className="hear" aria-labelledby="hear-title">
      <div className="hear-head">
        <h2 id="hear-title" tabIndex={-1}>
          Input
        </h2>
        <div className="segmented" role="group" aria-label="Where the recording comes from">
          <button aria-pressed={source === "torgo"} className={source === "torgo" ? "on" : ""} onClick={() => setSource("torgo")}>
            TORGO
          </button>
          <button aria-pressed={source === "file"} className={source === "file" ? "on" : ""} onClick={() => setSource("file")}>
            Your file
          </button>
          <button aria-pressed={source === "mic"} className={source === "mic" ? "on" : ""} onClick={() => setSource("mic")}>
            Microphone
          </button>
        </div>
      </div>

      {source === "mic" ? (
        props.micPanel
      ) : source === "torgo" ? (
        index ? (
          <TorgoPicker index={index} disabled={working || props.busy} onHear={props.onHear} />
        ) : (
          <p className="muted">{load === null ? "Loading the recordings…" : load.status === "missing" ? load.reason : "The recordings couldn’t be loaded. Is the server running?"}</p>
        )
      ) : (
        <FilePicker index={index} disabled={working || props.busy} onHear={props.onHear} />
      )}

      <HearingLine hearing={props.hearing} onStop={props.onStop} onDismiss={props.onDismiss} />
    </section>
  );
}

function TorgoPicker({ index, disabled, onHear }: { index: DatasetIndex; disabled: boolean; onHear: (choice: RecordingChoice) => void }) {
  const speakers = useMemo(() => orderSpeakers(index.speakers), [index.speakers]);
  const [speaker, setSpeaker] = useState(() => speakers[0]?.id ?? "");
  const [which, setWhich] = useState<Which>("test");
  const [query, setQuery] = useState("");
  const [shown, setShown] = useState(SHOWN);
  const ids = { speaker: useId(), which: useId(), query: useId() };

  const clips = useMemo(() => {
    const q = query.trim().toLowerCase();
    return index.clips.filter((c) => c.speaker === speaker && (which === "all" || c.split === which) && (!q || c.prompt.toLowerCase().includes(q)));
  }, [index.clips, speaker, which, query]);
  const choose = (clip: DatasetClip) => onHear({ kind: "torgo", clip, index });
  const description = speakerDescription(index.speakers.find((s) => s.id === speaker));

  return (
    <div className="torgo-picker">
      <div className="hear-fields">
        <label htmlFor={ids.speaker}>
          <span>Speaker</span>
          <select
            id={ids.speaker}
            value={speaker}
            onChange={(e) => {
              setSpeaker(e.target.value);
              setShown(SHOWN);
            }}
          >
            {speakers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.id}: {speakerDescription(s)}
              </option>
            ))}
          </select>
        </label>
        <label htmlFor={ids.which}>
          <span>Clips</span>
          <select id={ids.which} value={which} onChange={(e) => setWhich(e.target.value as Which)}>
            <option value="test">Test clips (a fair test)</option>
            <option value="enrolment">Set-up clips</option>
            <option value="all">All clips</option>
          </select>
        </label>
        <label htmlFor={ids.query} className="grow">
          <span>Search</span>
          <input id={ids.query} type="search" value={query} placeholder="A word or sentence" onChange={(e) => setQuery(e.target.value)} />
        </label>
        <button className="button quiet" disabled={disabled || clips.length === 0} onClick={() => choose(clips[Math.floor(Math.random() * clips.length)])}>
          Pick one at random
        </button>
      </div>
      <p className="muted hear-note">
        {speaker}: {description || "no description"}. Their first clip sets up their voice from {SETUP_CLIP_LIMIT} of their set-up clips, as in
        the evaluation; test clips are never used for that.
      </p>
      {clips.length === 0 ? (
        <p className="muted">No clips match.</p>
      ) : (
        <ul className="pick-list">
          {clips.slice(0, shown).map((clip) => (
            <li key={clip.id}>
              <button className="pick" disabled={disabled} onClick={() => choose(clip)}>
                <span className={`pick-prompt${clip.kind === "sentence" ? " sentence" : ""}`}>&ldquo;{clip.prompt}&rdquo;</span>
                <span className="pick-meta">
                  {clip.kind === "sentence" ? "sentence" : "word"} · {secondsLabel(clip.seconds)} · {clip.split === "test" ? "test" : "set-up"}
                  {index.results[clip.id] && " · in the evaluation"}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {shown < clips.length && (
        <button className="button quiet small" onClick={() => setShown((n) => n + SHOWN)}>
          Show more ({clips.length - shown} left)
        </button>
      )}
    </div>
  );
}

function FilePicker({ index, disabled, onHear }: { index?: DatasetIndex; disabled: boolean; onHear: (choice: RecordingChoice) => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [reference, setReference] = useState("");
  const [voiceId, setVoiceId] = useState<VoiceId>("nobody");
  const [over, setOver] = useState(false);
  const ids = { file: useId(), reference: useId(), voice: useId() };
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
        <label htmlFor={ids.voice}>
          <span>Hear it as</span>
          <select id={ids.voice} value={voiceId} onChange={(e) => setVoiceId(e.target.value)}>
            <option value="nobody">Nobody in particular</option>
            <option value="own">Your voice (set up in this browser)</option>
            {speakers.map((s) => (
              <option key={s.id} value={`torgo:${s.id}`}>
                TORGO {s.id}: {speakerDescription(s)}
              </option>
            ))}
          </select>
        </label>
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
