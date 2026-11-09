// Wires the page together: the microphone, your own conversation, example replays and setup.
// Your own conversation (live server, phrasebook in this browser) lives for the whole visit.
// An example gets a fresh conversation with a replayed "server" and its own phrasebook, so
// watching examples never changes yours.

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Listener, type FinishedTurn } from "./audio/listener";
import type { EnrolmentState } from "./components/Enrolment";
import { ENROLMENT_START } from "./components/Enrolment";
import type { EvalReplay } from "./components/Evaluation";
import type { LiveInput } from "./components/Pipeline";
import { partialsFor } from "./fixtures/build";
import { REPLAYS, type Replay } from "./fixtures";
import { Conversation, type ConversationState } from "./model/conversation";
import { enrolPhrase, setupCommand, SETUP_PHRASES } from "./model/enrolment";
import { normalise } from "./model/learning";
import { runReplay } from "./model/replayRunner";
import { LiveTransport, ReplayTransport } from "./model/transport";
import { readSetting, writeSetting } from "./storage/settings";
import { BrowserStore, MemoryStore } from "./storage/store";

export type Mode = { kind: "live" } | { kind: "replay"; id: string; title: string; running: boolean; evaluation: boolean };

/** Spoken commands for the page itself, so it can be used by voice alone. */
function pageCommand(text: string | undefined): "setup" | "stop" | "example" | null {
  const said = normalise(text ?? "");
  if (/^(set up|setup) (my|your) voice$/.test(said)) return "setup";
  if (said === "stop listening") return "stop";
  if (/^(play|show) (an|me an) example$/.test(said)) return "example";
  return null;
}

function evaluationReplay(r: EvalReplay): Replay {
  const first = r.events[0]?.at ?? 0;
  const events = r.events.map((e) => ({ ...e, at: e.at - first }));
  const live = events.find((e) => e.type === "hear.done" && e.hearer === "realtime");
  const text = live && live.type === "hear.done" ? live.text : "";
  return {
    id: r.id,
    title: r.intended,
    summary: `${r.speaker}. Text and timings only.`,
    phrasebook: [],
    turns: [{ partials: text ? partialsFor(text, r.speechSeconds) : [], speechSeconds: r.speechSeconds, events }],
    acts: {},
  };
}

const EMPTY: ConversationState | null = null;

export function useSession() {
  const listener = useMemo(() => new Listener(), []);
  const transport = useMemo(() => new LiveTransport(), []);
  const [own, setOwn] = useState<Conversation | null>(null);
  const [active, setActive] = useState<Conversation | null>(null);
  const [mode, setMode] = useState<Mode>({ kind: "live" });
  const [listening, setListening] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [enrol, setEnrol] = useState<EnrolmentState>(ENROLMENT_START);
  const [endSilence, setEndSilence] = useState(() => readSetting("endSilence", 2.5));
  const [speakReplies, setSpeakReplies] = useState(() => readSetting("speakReplies", true));
  const [autoListen, setAutoListen] = useState(() => readSetting("autoListen", false));
  const [live, setLive] = useState<LiveInput>({ text: "", level: 0, quietSeconds: 0, status: "off", endSilenceSeconds: endSilence, replaying: false });

  const replaying = useRef(false);
  const replayAbort = useRef<AbortController | null>(null);
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
      setActive((current) => current ?? conversation);
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

  const stopReplay = useCallback(() => {
    replayAbort.current?.abort();
    replayAbort.current = null;
    replaying.current = false;
  }, []);

  const backToOwn = useCallback(() => {
    stopReplay();
    setMode({ kind: "live" });
    setActive(own);
    setLive((l) => ({ ...l, text: "", level: 0, replaying: false }));
  }, [own, stopReplay]);

  const playReplay = useCallback(
    async (replay: Replay, evaluation = false) => {
      stopReplay();
      active?.transport.kind === "replay" && active.dispose();
      const conversation = await Conversation.create(new ReplayTransport(replay), new MemoryStore(replay.phrasebook));
      const abort = new AbortController();
      replayAbort.current = abort;
      replaying.current = true;
      setActive(conversation);
      setMode({ kind: "replay", id: replay.id, title: replay.title, running: true, evaluation });
      const onLive = (text: string, level: number, isReplaying: boolean) => setLive((l) => ({ ...l, text, level, replaying: isReplaying }));
      await runReplay(replay, conversation, { onLive }, abort.signal, evaluation ? "evaluation" : "replay").catch(() => {});
      if (replayAbort.current === abort) replaying.current = false;
      setMode((m) => (m.kind === "replay" && m.id === replay.id ? { ...m, running: false } : m));
    },
    [active, stopReplay],
  );

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
    try {
      await listener.start({ liveTranscript: true });
      setListening(true);
      if (listener.needsGesture) setNotice("Press any key, or click anywhere, so the browser lets the page hear you.");
    } catch (error) {
      setNotice((error as Error).message);
    }
  }, [listener]);

  const stopListening = useCallback(() => {
    listener.stop();
    setListening(false);
  }, [listener]);

  const handleTurn = useCallback(
    (turn: FinishedTurn) => {
      if (enrolRef.current.open) return void handleEnrolTurn(turn);
      if (!own) return;
      const command = own.getState().pending ? null : pageCommand(turn.realtimeText);
      if (command === "setup") {
        if (replaying.current || mode.kind === "replay") backToOwn();
        return setEnrol({ ...ENROLMENT_START, open: true });
      }
      if (command === "stop") return stopListening();
      if (command === "example") return void playReplay(REPLAYS[0]);
      if (replaying.current || mode.kind === "replay") backToOwn();
      void own.submitTurn({ wavBase64: turn.wavBase64, realtimeText: turn.realtimeText, liveText: turn.realtimeText ?? "", speechSeconds: turn.speechSeconds, origin: "live", speechStartedAt: turn.speechStartedAt });
    },
    [own, handleEnrolTurn, stopListening, playReplay, backToOwn, mode.kind],
  );

  // The listener's callbacks always see the latest handlers.
  useEffect(() => {
    listener.onTick = (tick) => {
      if (tick.status !== "speaking" && replaying.current) return setLive((l) => ({ ...l, status: tick.status }));
      setLive((l) => ({ ...l, level: tick.level, quietSeconds: tick.quietSeconds, status: tick.status, replaying: false }));
    };
    listener.onLiveText = (text) => setLive((l) => ({ ...l, text }));
    listener.onSpeechStarted = () => {
      // Speaking interrupts: the reply stops mid-word, and an example stops playing.
      own?.interrupt();
      active?.interrupt();
      if (replaying.current) stopReplay();
    };
    listener.onTurn = handleTurn;
    listener.onNotice = setNotice;
  }, [listener, own, active, handleTurn, stopReplay]);

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

  const subscribe = useCallback((fn: () => void) => (active ? active.subscribe(fn) : () => {}), [active]);
  const state = useSyncExternalStore(subscribe, () => active?.getState() ?? EMPTY);
  const ownSubscribe = useCallback((fn: () => void) => (own ? own.subscribe(fn) : () => {}), [own]);
  const ownState = useSyncExternalStore(ownSubscribe, () => own?.getState() ?? EMPTY);

  return {
    state,
    ownState,
    own,
    mode,
    live,
    listening,
    notice,
    dismissNotice: () => setNotice(null),
    enrol,
    setEnrol,
    startListening,
    stopListening,
    endTurn: () => listener.endTurn(),
    playReplay,
    playEvaluation: (r: EvalReplay) => playReplay(evaluationReplay(r), true),
    backToOwn,
    settings: { endSilence, setEndSilence, speakReplies, setSpeakReplies, autoListen, setAutoListen },
  };
}
