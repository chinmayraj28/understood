// Wires the page together: the microphone, your own conversation, recordings and setup.
// Your own conversation (live server, phrasebook in this browser) lives for the whole visit.
// A recording (a TORGO clip or a file) is played aloud while the live recogniser hears it, then
// goes through the same pipeline as a spoken turn, heard as the voice it belongs to. Recordings
// are transcribed only: nothing is acted on, and nothing is learned from them.

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Listener, MICROPHONE_REFUSED, type FinishedTurn } from "./audio/listener";
import type { EnrolmentState } from "./components/Enrolment";
import { ENROLMENT_START } from "./components/Enrolment";
import type { LiveInput } from "./components/Pipeline";
import type { DatasetClip, DatasetIndex } from "../shared/dataset";
import { scoringWords } from "../shared/wordErrors";
import { decodeAudioFile, type DecodedAudio } from "./audio/decode";
import { playAndTranscribe } from "./audio/fileHearing";
import { encodeWav, toBase64 } from "./audio/wav";
import { Conversation, type ConversationState, type VoiceSnapshot } from "./model/conversation";
import { loadClipAudio } from "./model/datasetLoader";
import { speakerDescription } from "./model/dataset";
import { enrolPhrase, setupCommand, SETUP_PHRASES } from "./model/enrolment";
import { normalise } from "./model/learning";
import { LiveTransport } from "./model/transport";
import type { TurnModel } from "./model/turn";
import { profileVoice, setUpSpeaker, setupClipsFor, type Voice } from "./model/voices";
import {
  abandonedDrafts,
  cleanProfileName,
  databaseName,
  FIRST_PROFILE,
  freeProfileName,
  loadActiveProfile,
  loadProfiles,
  newProfileId,
  saveActiveProfile,
  saveProfiles,
  type Profile,
} from "./storage/profiles";
import { readSetting, writeSetting } from "./storage/settings";
import { BrowserStore, deleteDatabase } from "./storage/store";

/** Spoken commands for the page itself, so it can be used by voice alone. */
function pageCommand(text: string | undefined): "setup" | "stop" | null {
  const said = normalise(text ?? "");
  if (/^(set up|setup) (my|your) voice$/.test(said)) return "setup";
  if (said === "stop listening") return "stop";
  return null;
}

/**
 * A recording to hear: a TORGO clip, or a file the visitor chose. `voiceId` says whose voice it
 * is heard as; a TORGO clip without one is heard as its own speaker.
 */
export type RecordingChoice =
  | {
      kind: "torgo";
      clip: DatasetClip;
      index: DatasetIndex;
      voiceId?: VoiceId;
      /** The speaker's clips their voice is set up from. Missing: the evaluation's set-up clips. */
      profileClipIds?: string[];
    }
  | { kind: "file"; name: string; data: ArrayBuffer; reference?: string; voiceId: VoiceId; index?: DatasetIndex };

/** "profile:<id>" (one of your profiles) or "torgo:F03" (a TORGO speaker). */
export type VoiceId = string;

/** What a profile knows, for the profiles page. */
export interface ProfileSummary {
  entries: number;
  clips: number;
  persistent: boolean;
}

/** Where hearing a recording has got to. */
export type HearingStatus =
  | { step: "idle" }
  | { step: "loading"; label: string }
  | { step: "setup"; label: string; voiceLabel: string; done: number; total: number }
  | { step: "playing"; label: string }
  | { step: "hearing"; label: string }
  | { step: "error"; message: string };

/** One cached voice per speaker and set of profile clips: the same choice is set up only once. */
function speakerVoiceKey(index: DatasetIndex, speaker: string, clipIds?: string[]): string {
  const ids = clipIds ?? setupClipsFor(index, speaker).map((c) => c.id);
  return `torgo:${speaker}:${[...ids].sort().join(",")}`;
}

/** A TORGO speaker's name on the page: "F03 (cerebral palsy, moderate)". */
export function torgoVoiceLabel(index: DatasetIndex, speaker: string): string {
  const description = speakerDescription(index.speakers.find((s) => s.id === speaker));
  return description ? `${speaker} (${description})` : speaker;
}

const wavOf = (audio: DecodedAudio) => toBase64(encodeWav(audio.pcm));

/** Waits for `promise`, or rejects as soon as `signal` fires; the promise itself goes on. */
function untilStopped<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(new DOMException("Stopped", "AbortError"));
  return new Promise<T>((resolve, reject) => {
    const stop = () => reject(new DOMException("Stopped", "AbortError"));
    signal.addEventListener("abort", stop, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", stop);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", stop);
        reject(error);
      },
    );
  });
}

/** True if the browser already lets the page use the microphone, so it can open without asking. */
export async function microphoneAllowed(): Promise<boolean> {
  try {
    const status = await navigator.permissions?.query({ name: "microphone" as PermissionName });
    return status?.state === "granted";
  } catch {
    return false;
  }
}

const EMPTY: ConversationState | null = null;

export function useSession() {
  const listener = useMemo(() => new Listener(), []);
  const transport = useMemo(() => new LiveTransport(), []);
  const [own, setOwn] = useState<Conversation | null>(null);
  const [listening, setListening] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [enrol, setEnrol] = useState<EnrolmentState>(ENROLMENT_START);
  const [endSilence, setEndSilence] = useState(() => readSetting("endSilence", 2.5));
  const [speakReplies, setSpeakReplies] = useState(() => readSetting("speakReplies", true));
  const [autoListen, setAutoListen] = useState(() => readSetting("autoListen", false));
  // Off (the default): what you say is written down, like any recording. On (under "Advanced"):
  // it is treated as a request to the pretend phone, which acts or asks first.
  const [actOnSpeech, setActOnSpeech] = useState(() => readSetting("actOnSpeech", false));
  const actOnSpeechRef = useRef(actOnSpeech);
  actOnSpeechRef.current = actOnSpeech;
  const [live, setLive] = useState<LiveInput>({ text: "", level: 0, quietSeconds: 0, status: "off", endSilenceSeconds: endSilence, playing: false });
  const [hearing, setHearing] = useState<HearingStatus>({ step: "idle" });
  /** The browser or the computer refused the microphone on the last try. */
  const [micRefused, setMicRefused] = useState(false);
  /** The browser's own answer for this site: "granted", "denied" or "prompt" ("unknown" if it will not say). */
  const [micPermission, setMicPermission] = useState<PermissionState | "unknown">("unknown");
  /** The voice the latest recording was heard as, when it is not the profile in use. */
  const [voiceInUse, setVoiceInUse] = useState<Voice | null>(null);
  // Your profiles, and the one in use: the microphone, setup and learning all go to it.
  const [profiles, setProfiles] = useState<Profile[]>(loadProfiles);
  const [activeProfileId, setActiveProfileId] = useState(() => loadActiveProfile(profiles));
  const profilesRef = useRef(profiles);
  profilesRef.current = profiles;
  const activeRef = useRef(activeProfileId);
  activeRef.current = activeProfileId;
  /** The open store of the profile in use. */
  const activeStore = useRef<BrowserStore | null>(null);
  /** The latest profile switch: each waits for the one before. */
  const switching = useRef<Promise<void>>(Promise.resolve());
  const activeProfile = profiles.find((p) => p.id === activeProfileId) ?? profiles[0];

  const playing = useRef(false);
  const hearingAbort = useRef<AbortController | null>(null);
  /** Counts hearings, so a stopped one never updates the page after a newer one started. */
  const hearingToken = useRef(0);
  /**
   * True from the moment a recording is chosen until it has finished playing. Meanwhile the
   * microphone stays closed (it would hear the speakers) and any spoken turn is dropped, so a
   * clip saying "yes" can never answer a question for the person.
   */
  const recordingAloud = useRef(false);
  /** The microphone was on (or asked for) while a recording played: open it again afterwards. */
  const micAfterRecording = useRef(false);
  const voices = useRef(new Map<string, Promise<Voice>>());
  /** Setup progress per voice, and which voice the current hearing is waiting for. */
  const setupProgress = useRef(new Map<string, { done: number; total: number }>());
  const waitingForVoice = useRef<{ key: string; label: string; voiceLabel: string } | null>(null);
  const enrolRef = useRef(enrol);
  enrolRef.current = enrol;
  const enrolToken = useRef(0);

  // Your own conversation: the real server, and the phrasebook of the profile in use, kept in this browser.
  useEffect(() => {
    let gone = false;
    void (async () => {
      const store = await BrowserStore.open(databaseName(activeRef.current));
      const conversation = await Conversation.create(transport, store);
      if (gone) return store.close();
      activeStore.current = store;
      setOwn(conversation);
    })();
    return () => {
      gone = true;
    };
  }, [transport]);

  // A profile whose creation was never finished (the tab was closed) is removed with what it
  // recorded. Read before the list below is saved again without it.
  const [leftDrafts] = useState(abandonedDrafts);
  useEffect(() => {
    for (const draft of leftDrafts) void deleteDatabase(databaseName(draft.id)).catch(() => {});
  }, [leftDrafts]);
  useEffect(() => saveProfiles(profiles), [profiles]);
  const finishedProfiles = useMemo(() => profiles.filter((p) => !p.draft), [profiles]);
  useEffect(() => saveActiveProfile(activeProfileId), [activeProfileId]);

  /** Uses another of your profiles: the conversation loads its phrasebook and clips and learns into it. */
  const selectProfile = useCallback(
    (id: string): Promise<void> => {
      if (!own || id === activeRef.current || !profilesRef.current.some((p) => p.id === id)) return switching.current;
      activeRef.current = id;
      setActiveProfileId(id);
      setVoiceInUse(null);
      // One switch at a time, in the order asked: two quick switches can never end on the first.
      switching.current = switching.current.then(async () => {
        const store = await BrowserStore.open(databaseName(id));
        await own.useStore(store);
        activeStore.current?.close();
        activeStore.current = store;
      });
      return switching.current;
    },
    [own],
  );

  /** Makes a new, empty profile. A draft is kept only once finishProfile is called. Returns its id. */
  const createProfile = useCallback((name: string, options: { draft?: boolean } = {}): string => {
    const id = newProfileId();
    const wanted = cleanProfileName(name) || "New profile";
    const list = profilesRef.current;
    const profile: Profile = { id, name: freeProfileName(list, wanted), createdAt: Date.now() };
    if (options.draft) profile.draft = true;
    const next = [...list, profile];
    // Known at once, so "Create and use" can switch to it in the same click.
    profilesRef.current = next;
    setProfiles(next);
    return id;
  }, []);

  /** Keeps a draft profile: its first phrases are recorded. */
  const finishProfile = useCallback((id: string) => {
    const next = profilesRef.current.map((p) => (p.id === id ? { id: p.id, name: p.name, createdAt: p.createdAt } : p));
    profilesRef.current = next;
    setProfiles(next);
  }, []);

  const renameProfile = useCallback((id: string, name: string) => {
    const wanted = cleanProfileName(name);
    if (!wanted) return;
    setProfiles((list) =>
      list.map((p) => (p.id === id ? { ...p, name: freeProfileName(list.filter((o) => o.id !== id), wanted) } : p)),
    );
  }, []);

  /**
   * Deletes a profile and everything it learned (its whole database). Deleting the one in use
   * switches to another first. There is always a profile for the microphone to learn into, so
   * deleting the last one leaves a fresh, empty "My voice".
   */
  const deleteProfile = useCallback(
    async (id: string) => {
      if (!profilesRef.current.some((p) => p.id === id)) return;
      // Out of the list first, so a replacement can take its name.
      profilesRef.current = profilesRef.current.filter((p) => p.id !== id);
      if (!profilesRef.current.some((p) => !p.draft)) createProfile(FIRST_PROFILE.name);
      const rest = profilesRef.current;
      setProfiles(rest);
      if (id === activeRef.current) await selectProfile(rest.find((p) => !p.draft)?.id ?? rest[0].id);
      await deleteDatabase(databaseName(id)).catch(() => {});
    },
    [selectProfile, createProfile],
  );

  /** How much a profile has learned. The one in use is read from the conversation, live. */
  const summariseProfile = useCallback(
    async (id: string): Promise<ProfileSummary> => {
      const state = own?.getState();
      if (id === activeRef.current && state) return { entries: state.entries.length, clips: state.clipCount, persistent: state.persistent };
      const store = await BrowserStore.open(databaseName(id));
      try {
        const [entries, clips] = await Promise.all([store.loadEntries(), store.loadClips()]);
        return { entries: entries.length, clips: clips.length, persistent: store.persistent };
      } finally {
        store.close();
      }
    },
    [own],
  );

  /** One of your profiles as a voice, for a recording heard as a profile that is not in use. */
  const voiceOfProfile = useCallback(async (id: string): Promise<Voice> => {
    const profile = profilesRef.current.find((p) => p.id === id);
    if (!profile) throw new Error("That profile no longer exists. Choose another.");
    const store = await BrowserStore.open(databaseName(id));
    try {
      const [entries, clips] = await Promise.all([store.loadEntries(), store.loadClips()]);
      return profileVoice(id, profile.name, entries, clips);
    } finally {
      store.close();
    }
  }, []);

  const activeName = () => profilesRef.current.find((p) => p.id === activeRef.current)?.name ?? "your profile";

  useEffect(() => {
    transport.speechMuted = !speakReplies;
    writeSetting("speakReplies", speakReplies);
  }, [transport, speakReplies]);

  useEffect(() => {
    listener.endSilenceSeconds = endSilence;
    setLive((l) => ({ ...l, endSilenceSeconds: endSilence }));
    writeSetting("endSilence", endSilence);
  }, [listener, endSilence]);

  useEffect(() => writeSetting("autoListen", autoListen), [autoListen]);
  useEffect(() => writeSetting("actOnSpeech", actOnSpeech), [actOnSpeech]);

  const handleEnrolTurn = useCallback(
    async (turn: FinishedTurn) => {
      if (!own) return;
      const current = enrolRef.current;
      const command = setupCommand(turn.realtimeText);
      if (command === "finish") return setEnrol((e) => ({ ...e, open: false }));
      if (command === "again") return setEnrol((e) => ({ ...e, status: "listening", result: undefined, error: undefined }));
      if (command === "skip") return setEnrol((e) => ({ ...e, index: e.index + 1, status: "listening", result: undefined, error: undefined }));
      // Only what is said while Record is on counts as the phrase. Nothing moves on by itself:
      // the person chooses Re-record or Next.
      if (current.status !== "listening" || current.index >= SETUP_PHRASES.length) return;
      const index = current.index;
      const token = ++enrolToken.current;
      setEnrol((e) => ({ ...e, status: "hearing", error: undefined }));
      try {
        const result = await enrolPhrase(own, SETUP_PHRASES[index], turn.wavBase64, turn.realtimeText);
        if (enrolToken.current !== token) return;
        // Skipped while it was being heard: it still counts as recorded, but the page stays on the new phrase.
        setEnrol((e) => ({ ...(e.index === index ? { ...e, status: "heard" as const, result } : e), done: e.done.map((d, i) => d || i === index) }));
      } catch (error) {
        if (enrolToken.current !== token) return;
        setEnrol((e) => (e.index === index ? { ...e, status: "error", error: `${(error as Error).message} Re-record it, or skip it.` } : e));
      }
    },
    [own],
  );

  const startListening = useCallback(async () => {
    setNotice(null);
    if (recordingAloud.current) {
      // Opened after the recording, never over it.
      micAfterRecording.current = true;
      setNotice("The microphone opens when the recording has finished playing.");
      return;
    }
    try {
      await listener.start({ liveTranscript: true });
      // A stop while it was starting (a recording began, or the visitor left the page) wins:
      // start() then returns quietly with the microphone closed, and the page must say so.
      if (!listener.isOn) return;
      setMicRefused(false);
      setListening(true);
      if (listener.needsGesture) setNotice("Press any key, or click anywhere, so the browser lets the page hear you.");
    } catch (error) {
      const message = (error as Error).message;
      if (message === MICROPHONE_REFUSED) {
        // The help panel explains what to do, so no second message.
        setMicRefused(true);
        return;
      }
      setNotice(message);
    }
  }, [listener]);

  const startListeningRef = useRef(startListening);
  startListeningRef.current = startListening;
  const micRefusedRef = useRef(micRefused);
  micRefusedRef.current = micRefused;

  // Follows the browser's microphone setting for this site. When the person switches it to
  // Allow after a refusal, listening starts by itself: no reload, no second click.
  useEffect(() => {
    let status: PermissionStatus | null = null;
    let gone = false;
    void navigator.permissions
      ?.query({ name: "microphone" as PermissionName })
      .then((result) => {
        if (gone) return;
        status = result;
        setMicPermission(result.state);
        result.onchange = () => {
          setMicPermission(result.state);
          if (result.state === "granted" && micRefusedRef.current) {
            setMicRefused(false);
            void startListeningRef.current();
          }
        };
      })
      .catch(() => {});
    return () => {
      gone = true;
      if (status) status.onchange = null;
    };
  }, []);

  const stopListening = useCallback(() => {
    micAfterRecording.current = false; // a deliberate stop: do not reopen it after a recording
    stopAfterTurn.current = false;
    listener.stop();
    setListening(false);
  }, [listener]);

  /** Set by "Stop" pressed mid-sentence: close the microphone once that sentence is handed on. */
  const stopAfterTurn = useRef(false);
  /**
   * The Record button's Stop. Mid-sentence, the sentence is ended and sent through the pipeline
   * first, and the microphone closes after; otherwise it closes at once. Never throws a sentence away.
   */
  const stopRecording = useCallback(() => {
    if (!listener.isInTurn) return stopListening();
    stopAfterTurn.current = true;
    listener.endTurn();
    // If the sentence never arrives (the live transcript hangs), close anyway after a while.
    setTimeout(() => {
      if (stopAfterTurn.current) stopListening();
    }, 8000);
  }, [listener, stopListening]);

  const handleTurn = useCallback(
    (turn: FinishedTurn) => {
      // While a recording plays, whatever the microphone caught is the speakers, not the person.
      if (recordingAloud.current) return;
      if (enrolRef.current.open) return void handleEnrolTurn(turn);
      if (!own) return;
      if (!actOnSpeechRef.current) {
        // Transcript only: heard by the same strong listeners as a recording. Nothing is acted on or asked.
        if (pageCommand(turn.realtimeText) === "stop") return stopListening();
        setVoiceInUse(null);
        return void own.transcribe({
          wavBase64: turn.wavBase64,
          realtimeText: turn.realtimeText,
          speechSeconds: turn.speechSeconds,
          recording: { label: "What you said", voiceLabel: `the profile “${activeName()}”` },
        });
      }
      const command = own.getState().pending ? null : pageCommand(turn.realtimeText);
      if (command === "setup") {
        setupSnapshot.current = own.snapshot();
        return setEnrol({ ...ENROLMENT_START, open: true, status: "listening" });
      }
      if (command === "stop") return stopListening();
      setVoiceInUse(null);
      void own.submitTurn({ wavBase64: turn.wavBase64, realtimeText: turn.realtimeText, liveText: turn.realtimeText ?? "", speechSeconds: turn.speechSeconds, origin: "live", speechStartedAt: turn.speechStartedAt });
    },
    [own, handleEnrolTurn, stopListening],
  );

  // The listener's callbacks always see the latest handlers.
  useEffect(() => {
    listener.onTick = (tick) => {
      if (playing.current) return setLive((l) => ({ ...l, status: tick.status }));
      setLive((l) => ({ ...l, level: tick.level, quietSeconds: tick.quietSeconds, status: tick.status }));
    };
    listener.onLiveText = (text) => {
      if (!playing.current) setLive((l) => ({ ...l, text }));
    };
    listener.onSpeechStarted = () => {
      // Speaking interrupts: the reply stops mid-word.
      own?.interrupt();
    };
    listener.onTurn = (turn) => {
      handleTurn(turn);
      if (stopAfterTurn.current) stopListening();
    };
    listener.onNotice = setNotice;
  }, [listener, own, handleTurn, stopListening]);

  /**
   * A TORGO speaker's voice, set up once per visit from their own enrolment clips. The setup is
   * shared by every hearing that wants the same voice and is not cancelled when one of them is
   * stopped; it finishes in the background and is kept for the next clip.
   */
  const voiceFor = useCallback(
    (index: DatasetIndex, speaker: string, clipIds?: string[]): Promise<Voice> => {
      if (!own) return Promise.reject(new Error("The page is still starting."));
      const key = speakerVoiceKey(index, speaker, clipIds);
      let voice = voices.current.get(key);
      if (!voice) {
        const chosen = clipIds ? index.clips.filter((c) => c.speaker === speaker && clipIds.includes(c.id)) : undefined;
        voice = setUpSpeaker(index, speaker, torgoVoiceLabel(index, speaker), {
          understand: (request, s) => own.transport.understand(request, s),
          loadWav: async (clip) => wavOf((await loadClipAudio(clip.id)).audio),
          onProgress: (progress) => {
            setupProgress.current.set(key, progress);
            const waiting = waitingForVoice.current;
            if (waiting?.key === key) setHearing({ step: "setup", label: waiting.label, voiceLabel: waiting.voiceLabel, ...progress });
          },
        }, chosen);
        voices.current.set(key, voice);
        voice.catch(() => voices.current.delete(key));
      }
      return voice;
    },
    [own],
  );

  /** Ends the time a recording is playing aloud, and opens the microphone again if it was on. */
  const endRecordingAloud = useCallback(() => {
    recordingAloud.current = false;
    playing.current = false;
    setLive((l) => ({ ...l, level: 0, playing: false }));
    if (micAfterRecording.current) {
      micAfterRecording.current = false;
      void startListeningRef.current();
    }
  }, []);

  const stopHearing = useCallback(() => {
    if (!hearingAbort.current) return;
    hearingAbort.current.abort();
    hearingAbort.current = null;
    waitingForVoice.current = null;
    setHearing({ step: "idle" });
  }, []);

  /** Opens "Set up your voice" for the profile in use, and the microphone with it. Call from a click. */
  /** What the profile knew when setup opened, so Cancel can put it back. */
  const setupSnapshot = useRef<VoiceSnapshot | null>(null);
  const openSetup = useCallback(() => {
    stopHearing();
    setupSnapshot.current = own?.snapshot() ?? null;
    // Waits for Record, unless the microphone is already on (then the first phrase is being recorded).
    setEnrol({ ...ENROLMENT_START, open: true, status: listener.isOn ? "listening" : "idle" });
  }, [listener, stopHearing, own]);

  /** Cancel: closes setup and undoes everything it recorded and learned. */
  const cancelSetup = useCallback(
    async (stopMicrophone = false) => {
      enrolToken.current += 1; // a phrase still being heard is not shown
      setEnrol((e) => ({ ...e, open: false }));
      if (stopMicrophone) stopListening();
      const snapshot = setupSnapshot.current;
      setupSnapshot.current = null;
      if (snapshot && own) await own.restore(snapshot);
    },
    [own, stopListening],
  );

  /** Record: opens the microphone if needed, and from now on what is said is this phrase. Call from a click. */
  const enrolRecord = useCallback(() => {
    enrolToken.current += 1; // a result still on its way belongs to the take being replaced
    setEnrol((e) => ({ ...e, status: "listening", result: undefined, error: undefined }));
    if (!listener.isOn) void startListeningRef.current();
  }, [listener]);

  /** Stop: ends the phrase now if it is being said, otherwise stops waiting for it. */
  const enrolStop = useCallback(() => {
    if (listener.isInTurn) listener.endTurn();
    else setEnrol((e) => (e.status === "listening" ? { ...e, status: "idle" } : e));
  }, [listener]);

  /** Next (or Skip): the following phrase, recording straight away if the microphone is on. */
  const enrolNext = useCallback(() => {
    enrolToken.current += 1;
    setEnrol((e) => ({ ...e, index: e.index + 1, status: listener.isOn ? "listening" : "idle", result: undefined, error: undefined }));
  }, [listener]);

  /** Closes setup. With `stopMicrophone`, the microphone too (setup opened it outside the pipeline). */
  const closeSetup = useCallback(
    (stopMicrophone = false) => {
      setEnrol((e) => ({ ...e, open: false }));
      if (stopMicrophone) stopListening();
    },
    [stopListening],
  );

  /**
   * Leaving the pipeline page: stops any recording and the microphone, closes the voice setup,
   * and returns whether the microphone was on (or was to reopen after a recording), so it can
   * come back on when the visitor returns. The booking is cleared before the hearing is stopped,
   * so the stopped hearing cannot reopen the microphone on the other page.
   */
  const leavePipeline = useCallback((): boolean => {
    const wasOn = listener.isOn || micAfterRecording.current;
    micAfterRecording.current = false;
    stopHearing();
    listener.stop();
    setListening(false);
    setEnrol((e) => (e.open ? { ...e, open: false } : e));
    return wasOn;
  }, [listener, stopHearing]);

  /**
   * Hears a recording: loads it, sets up the voice it is heard as (once), plays it aloud while
   * the live recogniser hears it, then sends it through the pipeline. The microphone is closed
   * until the recording has finished playing, then opens again if it was on.
   */
  const hearRecording = useCallback(
    async (choice: RecordingChoice) => {
      if (!own) return;
      stopHearing();
      // Made inside the click, so the browser lets it play sound later.
      const sound = new AudioContext();
      void sound.resume().catch(() => {});
      const token = ++hearingToken.current;
      const abort = new AbortController();
      hearingAbort.current = abort;
      const { signal } = abort;
      const current = () => hearingToken.current === token && !signal.aborted;
      const show = (status: HearingStatus) => {
        if (current()) setHearing(status);
      };
      const label = choice.kind === "torgo" ? `${choice.clip.speaker}: “${choice.clip.prompt}”` : choice.name;
      recordingAloud.current = true;
      if (listener.isOn) {
        micAfterRecording.current = true;
        listener.stop();
        setListening(false);
      }
      own.interrupt();
      setNotice(null);
      try {
        show({ step: "loading", label });
        const audio = choice.kind === "torgo" ? (await loadClipAudio(choice.clip.id, signal)).audio : await decodeAudioFile(choice.data);
        if (!current()) return;

        // Whose voice it is heard as: a TORGO speaker (set up from their clips), or one of your
        // profiles. The profile in use is the conversation's own, so it needs no voice.
        let voice: Voice | undefined;
        let voiceLabel = `the profile “${activeName()}”`;
        const voiceId = choice.voiceId ?? (choice.kind === "torgo" ? `torgo:${choice.clip.speaker}` : `profile:${activeRef.current}`);
        const speaker = voiceId.startsWith("torgo:") ? voiceId.slice(6) : null;
        const profileId = voiceId.startsWith("profile:") ? voiceId.slice(8) : null;
        const index = choice.index;
        if (speaker && !index) throw new Error("The TORGO recordings are not loaded, so a TORGO speaker’s voice cannot be set up.");
        if (speaker && index) {
          const clipIds = choice.kind === "torgo" && speaker === choice.clip.speaker ? choice.profileClipIds : undefined;
          const key = speakerVoiceKey(index, speaker, clipIds);
          const waiting = { key, label, voiceLabel: torgoVoiceLabel(index, speaker) };
          waitingForVoice.current = waiting;
          const progress = setupProgress.current.get(key);
          if (!voices.current.has(key) || (progress && progress.done < progress.total)) {
            show({ step: "setup", label, voiceLabel: waiting.voiceLabel, done: progress?.done ?? 0, total: progress?.total ?? 0 });
          }
          voice = await untilStopped(voiceFor(index, speaker, clipIds), signal);
          if (waitingForVoice.current === waiting) waitingForVoice.current = null;
          voiceLabel = voice.label;
        } else if (profileId && profileId !== activeRef.current) {
          voice = await voiceOfProfile(profileId);
          voiceLabel = `the profile “${voice.label}”`;
        }
        if (!current()) return;

        const reference = choice.kind === "torgo" ? choice.clip.prompt : choice.reference?.trim() || undefined;
        const recording: NonNullable<TurnModel["recording"]> = { label, reference, voiceLabel };
        if (choice.kind === "torgo") {
          recording.clipId = choice.clip.id;
          if (voice?.setupClipIds.includes(choice.clip.id)) {
            recording.caveat = `This clip is one of the ${voice.setupClipIds.length} that ${choice.clip.speaker}'s voice was set up from, so the pipeline has heard it before. Pick a test clip for a fair result.`;
          }
        }
        if (voice && voice.setupPrompts.length > 0 && reference) recording.seen = voice.setupPrompts.includes(scoringWords(reference).join(" "));

        setVoiceInUse(voice ?? null);
        show({ step: "playing", label });
        playing.current = true;
        setLive((l) => ({ ...l, text: "", level: 0, playing: true }));
        const played = await playAndTranscribe(audio.pcm, {
          onText: (text) => {
            if (current()) setLive((l) => ({ ...l, text }));
          },
          onLevel: (level) => {
            if (current()) setLive((l) => ({ ...l, level }));
          },
          signal,
          context: sound,
        });
        if (!current()) return;
        endRecordingAloud();
        if (played.realtimeFailure) setNotice(`${played.realtimeFailure} The other recognisers still hear the recording.`);

        show({ step: "hearing", label });
        await own.transcribe({ wavBase64: wavOf(audio), realtimeText: played.realtimeText, speechSeconds: audio.seconds, recording, voice });
        show({ step: "idle" });
      } catch (error) {
        if ((error as Error).name === "AbortError" || !current()) return;
        show({ step: "error", message: (error as Error).message || "The recording could not be heard." });
      } finally {
        void sound.close().catch(() => {});
        if (hearingToken.current === token) {
          if (hearingAbort.current === abort) hearingAbort.current = null;
          if (waitingForVoice.current?.label === label) waitingForVoice.current = null;
          // Stopped, failed or finished: the speakers are quiet now either way.
          if (recordingAloud.current) endRecordingAloud();
        }
      }
    },
    [own, listener, stopHearing, voiceFor, voiceOfProfile, endRecordingAloud],
  );

  // The space bar ends a turn; any key or click lets a held-back audio context start.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (listener.needsGesture) {
        listener.resume();
        setNotice(null);
      }
      const target = event.target as HTMLElement;
      const typing = ["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(target.tagName) || target.isContentEditable;
      if (event.code === "Space" && !typing && listener.isOn) {
        event.preventDefault();
        listener.endTurn();
      }
    };
    const onPointer = () => {
      if (listener.needsGesture) {
        listener.resume();
        setNotice(null);
      }
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("pointerdown", onPointer);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pointerdown", onPointer);
    };
  }, [listener]);

  // The microphone is deaf while the page speaks, so a reply is never heard as the person (no loop).
  const pageSpeaking = useSyncExternalStore(
    useCallback((fn: () => void) => (own ? own.subscribe(fn) : () => {}), [own]),
    () => own?.getState().speaking ?? false,
  );
  useEffect(() => {
    listener.deaf = pageSpeaking;
  }, [listener, pageSpeaking]);

  const ownSubscribe = useCallback((fn: () => void) => (own ? own.subscribe(fn) : () => {}), [own]);
  const ownState = useSyncExternalStore(ownSubscribe, () => own?.getState() ?? EMPTY);

  return {
    state: ownState,
    ownState,
    own,
    live,
    listening,
    notice,
    dismissNotice: () => setNotice(null),
    showNotice: setNotice,
    enrol,
    setEnrol,
    startListening,
    stopListening,
    stopRecording,
    endTurn: () => listener.endTurn(),
    hearing,
    /** True while a recording is loading, being set up or playing: the microphone stays closed. */
    recordingBusy: hearing.step === "loading" || hearing.step === "setup" || hearing.step === "playing",
    voiceInUse,
    micRefused,
    micPermission,
    /** Your finished profiles, for choosing one. */
    profiles: finishedProfiles,
    activeProfile,
    selectProfile,
    createProfile,
    finishProfile,
    openSetup,
    closeSetup,
    cancelSetup,
    enrolRecord,
    enrolStop,
    enrolNext,
    renameProfile,
    deleteProfile,
    summariseProfile,
    hearRecording,
    stopHearing,
    leavePipeline,
    dismissHearing: () => setHearing({ step: "idle" }),
    settings: { endSilence, setEndSilence, speakReplies, setSpeakReplies, autoListen, setAutoListen, actOnSpeech, setActOnSpeech },
  };
}
