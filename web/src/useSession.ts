// Wires the page together: the microphone, your own conversation, recordings and setup.
// Your own conversation (live server, phrasebook in this browser) lives for the whole visit.
// A recording (a TORGO clip or a file) is played aloud while the live recogniser hears it, then
// goes through the same pipeline as a spoken turn, heard as the voice it belongs to. Recordings
// are transcribed only: nothing is acted on, and nothing is learned from them.

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Listener, type FinishedTurn } from "./audio/listener";
import type { EnrolmentState } from "./components/Enrolment";
import { ENROLMENT_START } from "./components/Enrolment";
import type { LiveInput } from "./components/Pipeline";
import type { DatasetClip, DatasetIndex } from "../shared/dataset";
import { scoringWords } from "../shared/wordErrors";
import { decodeAudioFile, type DecodedAudio } from "./audio/decode";
import { playAndTranscribe } from "./audio/fileHearing";
import { encodeWav, toBase64 } from "./audio/wav";
import { Conversation, type ConversationState } from "./model/conversation";
import { loadClipAudio } from "./model/datasetLoader";
import { speakerDescription } from "./model/dataset";
import { enrolPhrase, setupCommand, SETUP_PHRASES } from "./model/enrolment";
import { normalise } from "./model/learning";
import { LiveTransport } from "./model/transport";
import type { TurnModel } from "./model/turn";
import { NOBODY, setUpSpeaker, type Voice } from "./model/voices";
import { readSetting, writeSetting } from "./storage/settings";
import { BrowserStore } from "./storage/store";

/** Spoken commands for the page itself, so it can be used by voice alone. */
function pageCommand(text: string | undefined): "setup" | "stop" | null {
  const said = normalise(text ?? "");
  if (/^(set up|setup) (my|your) voice$/.test(said)) return "setup";
  if (said === "stop listening") return "stop";
  return null;
}

/** A recording to hear: a TORGO clip, or a file the visitor chose. */
export type RecordingChoice =
  | { kind: "torgo"; clip: DatasetClip; index: DatasetIndex }
  | { kind: "file"; name: string; data: ArrayBuffer; reference?: string; voiceId: VoiceId; index?: DatasetIndex };

/** "own" (this browser's setup), "nobody", or "torgo:F03". */
export type VoiceId = string;

/** Where hearing a recording has got to. */
export type HearingStatus =
  | { step: "idle" }
  | { step: "loading"; label: string }
  | { step: "setup"; label: string; voiceLabel: string; done: number; total: number }
  | { step: "playing"; label: string }
  | { step: "hearing"; label: string }
  | { step: "error"; message: string };

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
  const [live, setLive] = useState<LiveInput>({ text: "", level: 0, quietSeconds: 0, status: "off", endSilenceSeconds: endSilence, playing: false });
  const [hearing, setHearing] = useState<HearingStatus>({ step: "idle" });
  /** The voice the latest recording was heard as, when it is not your own. */
  const [voiceInUse, setVoiceInUse] = useState<Voice | null>(null);

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

  // Your own conversation: the real server, and a phrasebook kept in this browser.
  useEffect(() => {
    let gone = false;
    void (async () => {
      const store = await BrowserStore.open();
      const conversation = await Conversation.create(transport, store);
      if (gone) return;
      setOwn(conversation);
    })();
    return () => {
      gone = true;
    };
  }, [transport]);

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

  const handleEnrolTurn = useCallback(
    async (turn: FinishedTurn) => {
      if (!own) return;
      const current = enrolRef.current;
      const command = setupCommand(turn.realtimeText);
      if (command === "finish") return setEnrol((e) => ({ ...e, open: false }));
      if (command === "again") return setEnrol((e) => ({ ...e, status: "listening", result: undefined, error: undefined }));
      if (command === "skip") return setEnrol((e) => ({ ...e, index: e.index + 1, status: "listening", result: undefined }));
      if (current.index >= SETUP_PHRASES.length) return;
      const index = current.index;
      const token = ++enrolToken.current;
      setEnrol((e) => ({ ...e, status: "hearing", error: undefined }));
      try {
        const result = await enrolPhrase(own, SETUP_PHRASES[index], turn.wavBase64, turn.realtimeText);
        setEnrol((e) => ({ ...e, status: "heard", result, done: e.done.map((d, i) => d || i === index) }));
        setTimeout(() => {
          if (enrolToken.current !== token) return;
          setEnrol((e) => (e.index === index ? { ...e, index: index + 1, status: "listening", result: undefined } : e));
        }, 1800);
      } catch (error) {
        setEnrol((e) => ({ ...e, status: "error", error: `${(error as Error).message} Say it again, or skip it.` }));
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
      setListening(true);
      if (listener.needsGesture) setNotice("Press any key, or click anywhere, so the browser lets the page hear you.");
    } catch (error) {
      setNotice((error as Error).message);
    }
  }, [listener]);

  const startListeningRef = useRef(startListening);
  startListeningRef.current = startListening;

  const stopListening = useCallback(() => {
    micAfterRecording.current = false; // a deliberate stop: do not reopen it after a recording
    listener.stop();
    setListening(false);
  }, [listener]);

  const handleTurn = useCallback(
    (turn: FinishedTurn) => {
      // While a recording plays, whatever the microphone caught is the speakers, not the person.
      if (recordingAloud.current) return;
      if (enrolRef.current.open) return void handleEnrolTurn(turn);
      if (!own) return;
      const command = own.getState().pending ? null : pageCommand(turn.realtimeText);
      if (command === "setup") return setEnrol({ ...ENROLMENT_START, open: true });
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
    listener.onTurn = handleTurn;
    listener.onNotice = setNotice;
  }, [listener, own, handleTurn]);

  /**
   * A TORGO speaker's voice, set up once per visit from their own enrolment clips. The setup is
   * shared by every hearing that wants the same voice and is not cancelled when one of them is
   * stopped; it finishes in the background and is kept for the next clip.
   */
  const voiceFor = useCallback(
    (index: DatasetIndex, speaker: string): Promise<Voice> => {
      if (!own) return Promise.reject(new Error("The page is still starting."));
      const key = `torgo:${speaker}`;
      let voice = voices.current.get(key);
      if (!voice) {
        voice = setUpSpeaker(index, speaker, torgoVoiceLabel(index, speaker), {
          understand: (request, s) => own.transport.understand(request, s),
          loadWav: async (clip) => wavOf((await loadClipAudio(clip.id)).audio),
          onProgress: (progress) => {
            setupProgress.current.set(key, progress);
            const waiting = waitingForVoice.current;
            if (waiting?.key === key) setHearing({ step: "setup", label: waiting.label, voiceLabel: waiting.voiceLabel, ...progress });
          },
        });
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

        // Whose voice it is heard as.
        let voice: Voice | undefined;
        let voiceLabel = "your voice (set up in this browser)";
        const speaker = choice.kind === "torgo" ? choice.clip.speaker : choice.voiceId.startsWith("torgo:") ? choice.voiceId.slice(6) : null;
        const index = choice.index;
        if (speaker && index) {
          const key = `torgo:${speaker}`;
          const waiting = { key, label, voiceLabel: torgoVoiceLabel(index, speaker) };
          waitingForVoice.current = waiting;
          const progress = setupProgress.current.get(key);
          if (!voices.current.has(key) || (progress && progress.done < progress.total)) {
            show({ step: "setup", label, voiceLabel: waiting.voiceLabel, done: progress?.done ?? 0, total: progress?.total ?? 0 });
          }
          voice = await untilStopped(voiceFor(index, speaker), signal);
          if (waitingForVoice.current === waiting) waitingForVoice.current = null;
          voiceLabel = voice.label;
        } else if (choice.kind === "file" && choice.voiceId === "nobody") {
          voice = NOBODY;
          voiceLabel = NOBODY.label.toLowerCase();
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
    [own, listener, stopHearing, voiceFor, endRecordingAloud],
  );

  // Hands-free start: if the visitor asked for it and the browser already allows the microphone.
  useEffect(() => {
    if (!autoListen || listening) return;
    void navigator.permissions
      ?.query({ name: "microphone" as PermissionName })
      .then((status) => {
        if (status.state === "granted") void startListening();
      })
      .catch(() => {});
    // Only on first load.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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
    enrol,
    setEnrol,
    startListening,
    stopListening,
    endTurn: () => listener.endTurn(),
    hearing,
    /** True while a recording is loading, being set up or playing: the microphone stays closed. */
    recordingBusy: hearing.step === "loading" || hearing.step === "setup" || hearing.step === "playing",
    voiceInUse,
    hearRecording,
    stopHearing,
    dismissHearing: () => setHearing({ step: "idle" }),
    settings: { endSilence, setEndSilence, speakReplies, setSpeakReplies, autoListen, setAutoListen },
  };
}
