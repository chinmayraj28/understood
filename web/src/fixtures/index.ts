// Every replayed example, in the order the page offers them.

import type { Replay } from "./build";
import { callSam, messageMum } from "./replaysA";
import { ammaOrMum, geminiTimeout, nothingHeard, plainNo } from "./replaysB";

export type { Replay, ReplayTurn } from "./build";

export const REPLAYS: Replay[] = [callSam, messageMum, plainNo, ammaOrMum, geminiTimeout, nothingHeard];
