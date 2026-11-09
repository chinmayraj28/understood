// Review finding 6: "Clear everything" must delete the browser database every time, even after
// an earlier error switched the visit to memory, so no recording is ever left behind.
import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserStore } from "../../src/storage/store";

/** A pretend IndexedDB whose transactions can be made to fail. */
function fakeIndexedDB(options: { openFails?: boolean; transactionsFail?: boolean } = {}) {
  const connections: { close: ReturnType<typeof vi.fn> }[] = [];
  const deleteDatabase = vi.fn((name: string) => {
    const request: { onsuccess?: () => void; onerror?: () => void; name: string } = { name };
    setTimeout(() => request.onsuccess?.(), 0);
    return request;
  });
  const open = vi.fn(() => {
    const request: Record<string, unknown> & { onsuccess?: () => void; onerror?: () => void } = {};
    setTimeout(() => {
      if (options.openFails) {
        request.error = new Error("blocked");
        request.onerror?.();
        return;
      }
      const db = {
        objectStoreNames: { contains: () => true },
        close: vi.fn(),
        onversionchange: null,
        transaction: () => {
          if (options.transactionsFail) throw new Error("The disk is full.");
          throw new Error("not used in these tests");
        },
      };
      connections.push(db);
      request.result = db;
      request.onsuccess?.();
    }, 0);
    return request;
  });
  vi.stubGlobal("indexedDB", { open, deleteDatabase });
  return { open, deleteDatabase, connections };
}

afterEach(() => vi.unstubAllGlobals());

describe("Clear everything", () => {
  it("deletes the database even after a write error switched the visit to memory", async () => {
    const idb = fakeIndexedDB({ transactionsFail: true });
    const store = await BrowserStore.open();
    expect(store.persistent).toBe(true);
    await store.saveEntries([]); // fails inside: the store falls back to memory
    expect(store.persistent).toBe(false);
    await store.clearAll();
    expect(idb.deleteDatabase).toHaveBeenCalledWith("understood");
  });

  it("deletes the database even when it could never be opened", async () => {
    const idb = fakeIndexedDB({ openFails: true });
    const store = await BrowserStore.open();
    expect(store.persistent).toBe(false);
    await store.clearAll();
    expect(idb.deleteDatabase).toHaveBeenCalledWith("understood");
  });

  it("closes its own connection first, deletes, then opens a fresh empty database", async () => {
    const idb = fakeIndexedDB();
    const store = await BrowserStore.open();
    await store.clearAll();
    expect(idb.connections[0].close).toHaveBeenCalled();
    expect(idb.deleteDatabase).toHaveBeenCalledTimes(1);
    expect(idb.open).toHaveBeenCalledTimes(2);
    expect(store.persistent).toBe(true);
  });

  it("empties the in-memory copy too", async () => {
    fakeIndexedDB({ openFails: true });
    const store = await BrowserStore.open();
    await store.saveEntries([{ id: "a", heard: "call some", meant: "call Sam", hearer: "scribe", timesConfirmed: 1, lastConfirmedAt: 0, source: "confirmation" }]);
    await store.clearAll();
    expect(await store.loadEntries()).toEqual([]);
  });
});
