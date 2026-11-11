// The person's phrasebook and voice clips, kept only in this browser.
//
// Speech recordings of a disabled person are health data, so nothing is stored on the server:
// the phrasebook and a few clips travel with each request and are forgotten there. IndexedDB can
// be missing or blocked (private windows, strict settings), so every call falls back to memory
// and the page still works for the visit.

import type { PhrasebookEntry } from "../../shared/pipeline";
import type { Clip } from "../model/learning";

export interface VoiceStore {
  /** True when data survives a reload; false when only memory is available. */
  readonly persistent: boolean;
  loadEntries(): Promise<PhrasebookEntry[]>;
  saveEntries(entries: PhrasebookEntry[]): Promise<void>;
  loadClips(): Promise<Clip[]>;
  addClip(clip: Clip): Promise<void>;
  clearAll(): Promise<void>;
}

/** Keeps everything in memory. Used in tests, and when IndexedDB is unavailable. */
export class MemoryStore implements VoiceStore {
  readonly persistent: boolean = false;
  private entries: PhrasebookEntry[];
  private clips: Clip[] = [];

  constructor(seed: PhrasebookEntry[] = []) {
    this.entries = seed.map((e) => ({ ...e }));
  }
  async loadEntries() {
    return this.entries.map((e) => ({ ...e }));
  }
  async saveEntries(entries: PhrasebookEntry[]) {
    this.entries = entries.map((e) => ({ ...e }));
  }
  async loadClips() {
    return [...this.clips];
  }
  async addClip(clip: Clip) {
    this.clips = [...this.clips.filter((c) => c.id !== clip.id), clip].slice(-40);
  }
  async clearAll() {
    this.entries = [];
    this.clips = [];
  }
}

const DB_NAME = "understood";
const DB_VERSION = 1;
const MAX_CLIPS = 40;

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("entries")) db.createObjectStore("entries", { keyPath: "id" });
      if (!db.objectStoreNames.contains("clips")) db.createObjectStore("clips", { keyPath: "id" });
    };
    request.onsuccess = () => {
      const db = request.result;
      // Another tab clearing everything deletes the database: let go of it so that can happen.
      db.onversionchange = () => db.close();
      resolve(db);
    };
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error("The browser blocked local storage."));
  });
}

/** Deletes the whole database. Waits up to 3 s if another tab is still holding it open. */
function deleteDatabase(): Promise<void> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") return resolve();
    const request = indexedDB.deleteDatabase(DB_NAME);
    const timer = setTimeout(resolve, 3000);
    request.onsuccess = () => {
      clearTimeout(timer);
      resolve();
    };
    request.onerror = () => {
      clearTimeout(timer);
      reject(request.error);
    };
  });
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

function getAll<T>(db: IDBDatabase, name: string): Promise<T[]> {
  return new Promise((resolve, reject) => {
    const request = db.transaction(name, "readonly").objectStore(name).getAll();
    request.onsuccess = () => resolve(request.result as T[]);
    request.onerror = () => reject(request.error);
  });
}

/** IndexedDB, with a memory copy that takes over if the database fails at any point. */
export class BrowserStore implements VoiceStore {
  private memory = new MemoryStore();
  private constructor(private db: IDBDatabase | null) {}

  get persistent() {
    return this.db !== null;
  }

  static async open(): Promise<BrowserStore> {
    try {
      if (typeof indexedDB === "undefined") return new BrowserStore(null);
      return new BrowserStore(await openDatabase());
    } catch {
      return new BrowserStore(null);
    }
  }

  private async attempt<T>(work: (db: IDBDatabase) => Promise<T>, fallback: () => Promise<T>): Promise<T> {
    if (!this.db) return fallback();
    try {
      return await work(this.db);
    } catch {
      this.db = null; // stop trying for this visit; memory keeps working
      return fallback();
    }
  }

  async loadEntries() {
    return this.attempt((db) => getAll<PhrasebookEntry>(db, "entries"), () => this.memory.loadEntries());
  }

  async saveEntries(entries: PhrasebookEntry[]) {
    await this.memory.saveEntries(entries);
    await this.attempt(
      async (db) => {
        const tx = db.transaction("entries", "readwrite");
        const store = tx.objectStore("entries");
        store.clear();
        for (const entry of entries) store.put(entry);
        await done(tx);
      },
      async () => {},
    );
  }

  async loadClips() {
    return this.attempt((db) => getAll<Clip>(db, "clips"), () => this.memory.loadClips());
  }

  async addClip(clip: Clip) {
    await this.memory.addClip(clip);
    await this.attempt(
      async (db) => {
        const clips = await getAll<Clip>(db, "clips");
        const tx = db.transaction("clips", "readwrite");
        const store = tx.objectStore("clips");
        store.put(clip);
        // Keep the newest few dozen; older clips are dropped, as speech changes over time.
        const old = clips.sort((a, b) => a.createdAt - b.createdAt).slice(0, Math.max(0, clips.length + 1 - MAX_CLIPS));
        for (const c of old) store.delete(c.id);
        await done(tx);
      },
      async () => {},
    );
  }

  /**
   * Forgets everything on this device. The whole database is deleted every time, even when an
   * earlier error switched this visit to memory: a failed write must never leave a person's
   * recordings behind. A fresh, empty database is then opened for the rest of the visit.
   */
  async clearAll() {
    await this.memory.clearAll();
    this.db?.close();
    this.db = null;
    await deleteDatabase().catch(() => {});
    this.db = typeof indexedDB === "undefined" ? null : await openDatabase().catch(() => null);
  }
}
