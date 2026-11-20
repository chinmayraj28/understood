// Profiles: several people (or one person at different times) can each have their own voice
// set up in this browser. A profile is a name; what it knows (phrasebook and voice clips) lives
// in its own IndexedDB database, so profiles never mix. The list of profiles and which one is in
// use are small settings in localStorage.
//
// The first profile keeps the database the page used before profiles existed ("understood"),
// so a phrasebook learned earlier is still there, now under "My voice".

import { DB_NAME } from "./store";
import { readSetting, writeSetting } from "./settings";

export interface Profile {
  id: string;
  name: string;
  createdAt: number;
  /** Being created: not kept until its first phrases are recorded. A draft left by a closed tab is deleted on the next visit. */
  draft?: boolean;
}

/** A new profile is only kept once this many phrases of the voice are recorded. */
export const MIN_SETUP_PHRASES = 3;

export const FIRST_PROFILE: Profile = { id: "default", name: "My voice", createdAt: 0 };
export const MAX_NAME_LENGTH = 40;

/** The IndexedDB database that holds this profile's phrasebook and clips. */
export function databaseName(id: string): string {
  return id === FIRST_PROFILE.id ? DB_NAME : `${DB_NAME}-profile-${id}`;
}

function isProfile(value: unknown): value is Profile {
  const p = value as Profile;
  return typeof p?.id === "string" && p.id.length > 0 && typeof p.name === "string" && typeof p.createdAt === "number";
}

function savedProfiles(): Profile[] {
  const saved = readSetting<unknown>("profiles", []);
  return Array.isArray(saved) ? saved.filter(isProfile) : [];
}

/** The saved profiles, without unfinished drafts. Never empty: with none saved, there is the first profile. */
export function loadProfiles(): Profile[] {
  const list = savedProfiles().filter((p) => !p.draft);
  return list.length > 0 ? list : [FIRST_PROFILE];
}

/** Drafts left behind by a tab closed mid-creation: their databases are to be deleted. */
export function abandonedDrafts(): Profile[] {
  return savedProfiles().filter((p) => p.draft);
}

export function saveProfiles(profiles: Profile[]) {
  writeSetting("profiles", profiles);
}

/** The profile in use, or the first one if the saved one is gone. */
export function loadActiveProfile(profiles: Profile[]): string {
  const id = readSetting<string>("activeProfile", profiles[0].id);
  return profiles.some((p) => p.id === id) ? id : profiles[0].id;
}

export function saveActiveProfile(id: string) {
  writeSetting("activeProfile", id);
}

export function newProfileId(): string {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** A name as typed, tidied: trimmed, inner spaces collapsed, at most 40 characters. */
export function cleanProfileName(name: string): string {
  return name.trim().replace(/\s+/g, " ").slice(0, MAX_NAME_LENGTH);
}

/** A name not already taken: "My voice", then "My voice 2". */
export function freeProfileName(profiles: Profile[], wanted: string): string {
  const taken = new Set(profiles.map((p) => p.name.toLowerCase()));
  if (!taken.has(wanted.toLowerCase())) return wanted;
  for (let n = 2; ; n++) if (!taken.has(`${wanted} ${n}`.toLowerCase())) return `${wanted} ${n}`;
}
