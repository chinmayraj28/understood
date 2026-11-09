// What the pretend phone on the page is showing. Nothing real is ever sent or called.

import type { PhoneAction } from "../../shared/pipeline";

export type PhoneScreen = "home" | "confirm" | "message" | "call" | "timer" | "music" | "reminder";

export interface SentMessage {
  to: string;
  text: string;
  at: number;
}

export interface PhoneState {
  screen: PhoneScreen;
  /** The action on screen: waiting for a yes on the confirm screen, or done. */
  action?: PhoneAction;
  question?: string;
  /** When the screen changed, ms. Timers and calls count from here. */
  since: number;
  messages: SentMessage[];
  reminders: { text: string; when: string }[];
}

export const PHONE_HOME: PhoneState = { screen: "home", since: 0, messages: [], reminders: [] };

/** The phone waits on a confirm sheet until the person says yes. */
export function phoneAsk(state: PhoneState, action: PhoneAction, question: string): PhoneState {
  return { ...state, screen: "confirm", action, question, since: Date.now() };
}

export function phoneCancel(state: PhoneState): PhoneState {
  return { ...state, screen: "home", action: undefined, question: undefined, since: Date.now() };
}

export function phonePerform(state: PhoneState, action: PhoneAction, now = Date.now()): PhoneState {
  const base = { ...state, action, question: undefined, since: now };
  switch (action.kind) {
    case "message":
      return { ...base, screen: "message", messages: [...state.messages, { to: action.to, text: action.text, at: now }] };
    case "call":
      return { ...base, screen: "call" };
    case "timer":
      return { ...base, screen: "timer" };
    case "music":
      return { ...base, screen: "music" };
    case "reminder":
      return { ...base, screen: "reminder", reminders: [...state.reminders, { text: action.text, when: action.when }] };
    case "none":
      return { ...state, screen: "home", action: undefined, question: undefined };
  }
}
