// What the page does after the server decides, as pure functions: no network, no timers.
//
// `resolveDecision` takes the finished turn and the question that was waiting (if any) and
// returns an Outcome: what to say, what to act on, what the phone shows, what was learned.
// `afterAct` does the same for /api/act's answer.

import type { ActResponse, PhrasebookEntry } from "../../shared/pipeline";
import { DEMO_CONTACTS } from "../../shared/pipeline";
import { classifyAnswer, confirmQuestion, learnFromTurn, matchOption, optionLabels, wordMiss, words } from "./learning";
import { phoneAsk, phoneCancel, phonePerform, type PhoneState } from "./phone";
import { HEARERS, type TurnModel } from "./turn";

/** A question the assistant asked and is waiting on. The next turn is its answer. */
export interface Pending {
  /** understand: "did you mean X?"; choose: "A or B?"; action: "send it?"; again: "say it again". */
  kind: "understand" | "choose" | "action" | "again";
  question: string;
  expectedAnswers: string[];
  /** The turn the question is about. Its recognisers' texts are what gets learned. */
  subject?: TurnModel;
  /** For understand and action: the meaning being checked. */
  reading?: string;
  options?: string[];
  action?: ActResponse;
  /** A question about an answer ("Did you say yes?") keeps the question it was answering. */
  parent?: Pending;
}

export interface Learned {
  entries: PhrasebookEntry[];
  changed: PhrasebookEntry[];
  clip?: { turnId: string; text: string; difficulty: number };
}

export interface Outcome {
  /** The question now waiting. Undefined clears it. */
  pending?: Pending;
  say?: string;
  tone?: "question" | "done" | "error";
  /** Text to send to /api/act. */
  actOn?: string;
  /** The turn whose meaning a later yes to the action would confirm (only if not yet learned). */
  actSubject?: TurnModel;
  phone?: (phone: PhoneState) => PhoneState;
  learned?: Learned;
  /** The turn ended in a question or a no: one more failed try. */
  failed?: boolean;
  resetTries?: boolean;
}

export function resolveDecision(turn: TurnModel, pending: Pending | undefined, entries: PhrasebookEntry[]): Outcome {
  const decision = turn.decision!.decision;
  // When a question is about an answer, the question being answered stays underneath it.
  const outer = pending?.kind === "again" ? pending.parent : pending;
  switch (decision.kind) {
    case "cannotHear":
      return { pending, say: decision.message, tone: "error", failed: true };
    case "askAgain":
      return {
        pending: { kind: "again", question: decision.question, expectedAnswers: pending?.expectedAnswers ?? [], parent: outer },
        say: decision.question,
        tone: "question",
        failed: true,
      };
    case "confirm":
      return {
        pending: { kind: "understand", question: decision.question, reading: decision.reading, expectedAnswers: ["yes", "no"], subject: turn, parent: outer },
        say: decision.question,
        tone: "question",
        failed: true,
      };
    case "choose":
      return {
        pending: {
          kind: "choose",
          question: decision.question,
          options: decision.options,
          expectedAnswers: [...optionLabels(decision.options), "no"],
          subject: turn,
          parent: outer,
        },
        say: decision.question,
        tone: "question",
        failed: true,
      };
    case "act":
      // Nothing was waiting: the reading simply goes ahead, and nothing is learned from it.
      if (!pending) return { actOn: decision.text, actSubject: turn, resetTries: true };
      return answer(pending, decision.text, turn, entries);
  }
}

function answer(p: Pending, text: string, turn: TurnModel, entries: PhrasebookEntry[]): Outcome {
  if (p.kind === "again") return p.parent ? answer(p.parent, text, turn, entries) : { actOn: text, actSubject: turn, resetTries: true };
  const reply = classifyAnswer(text);
  const subject = p.subject ?? turn;

  if (p.kind === "understand") {
    const reading = p.reading ?? text;
    if (reply.kind === "yes") {
      const learned = learn(subject, reading, "confirmation", entries);
      if (p.parent) {
        const above = answer(p.parent, reading, turn, learned.entries);
        return { ...above, learned: merge(learned, above.learned) };
      }
      return { learned, actOn: reading, resetTries: true };
    }
    if (reply.kind === "no") {
      const corrected = reply.rest ? correction(reply.rest, reading, subject) : null;
      if (corrected) return { learned: learn(subject, corrected, "correction", entries), actOn: corrected, resetTries: true };
      if (p.parent) return { pending: p.parent, say: p.parent.question, tone: "question", failed: true };
      return { say: "Okay, I won't. Please say it again in your own words.", failed: true };
    }
    return { pending: p, say: `Please say yes or no. ${p.question}`, tone: "question", failed: true };
  }

  if (p.kind === "choose") {
    const option = matchOption(text, p.options ?? []);
    if (option) return { learned: learn(subject, option, "confirmation", entries), actOn: option, resetTries: true };
    if (reply.kind === "no") return { say: "Okay, neither. Please say it again in your own words.", failed: true };
    return { pending: p, say: p.question, tone: "question", failed: true };
  }

  // An action waiting for a yes.
  const action = p.action!;
  if (reply.kind === "yes") {
    const learned = p.subject && p.reading ? learn(p.subject, p.reading, "confirmation", entries) : undefined;
    return { learned, phone: (phone) => phonePerform(phone, action.action), say: doneSentence(action), tone: "done", resetTries: true };
  }
  if (reply.kind === "no") return { phone: phoneCancel, say: "Okay, I won't.", failed: true };
  return { pending: p, say: `Please say yes or no. ${p.question}`, tone: "question", failed: true };
}

/** After /api/act: do it, or ask first when it would reach another person. */
export interface ActOutcome {
  pending?: Pending;
  phone: PhoneState;
  say: string;
  tone?: Outcome["tone"];
}

export function afterAct(response: ActResponse, phone: PhoneState, text: string, subject?: TurnModel): ActOutcome {
  const action = response.action;
  if (action.kind === "none") return { phone, say: response.reply };
  if (response.needsConfirmation) {
    // The server's reply is already the question for messages and calls; otherwise build one.
    const question = response.reply.trim().endsWith("?") ? response.reply.trim() : confirmQuestion(action);
    return {
      pending: { kind: "action", question, expectedAnswers: ["yes", "no"], action: response, subject, reading: text },
      phone: phoneAsk(phone, action, question),
      say: question,
      tone: "question",
    };
  }
  return { phone: phonePerform(phone, action), say: response.reply, tone: "done" };
}

/** What the assistant says once a confirmed action is done. Never the question again. */
export function doneSentence(response: ActResponse): string {
  if (!response.reply.trim().endsWith("?")) return response.reply;
  const action = response.action;
  if (action.kind === "message") return `Sent to ${action.to}.`;
  if (action.kind === "call") return `Calling ${action.to}.`;
  return "Done.";
}

/**
 * The meaning a "no, ..." correction points at: one of Claude's other readings if the words
 * fit, or the same sentence with the contact's name swapped ("no, Sam" for "Message Mum ...").
 */
export function correction(rest: string, reading: string, subject: TurnModel): string | null {
  const alternatives = subject.repair.reading?.alternatives ?? [];
  const picked = matchOption(rest, [reading, ...alternatives]);
  if (picked && picked !== reading) return picked;
  const name = DEMO_CONTACTS.find((c) => words(rest).includes(c.toLowerCase()));
  const current = DEMO_CONTACTS.find((c) => words(reading).includes(c.toLowerCase()));
  if (name && current && name !== current) return reading.replace(new RegExp(`\\b${current}\\b`, "i"), name);
  return null;
}

function learn(turn: TurnModel, meant: string, source: "confirmation" | "correction", entries: PhrasebookEntry[]): Learned {
  const { entries: next, changed } = learnFromTurn(turn, meant, source, entries);
  const difficulty = Math.max(0, ...HEARERS.map((h) => (turn.lanes[h].text ? wordMiss(turn.lanes[h].text!, meant) : 0)));
  return { entries: next, changed, clip: { turnId: turn.turnId, text: meant, difficulty } };
}

function merge(first: Learned, second?: Learned): Learned {
  if (!second) return first;
  return { entries: second.entries, changed: [...first.changed, ...second.changed], clip: second.clip ?? first.clip };
}
