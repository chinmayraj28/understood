// Loads the list of TORGO recordings once per visit, for the recordings view and the pipeline's
// recording picker. Only the local server has the route; a hosted copy, or a request from another
// machine, gets "missing" with a reason the page can show.

import type { DatasetIndex, DatasetResponse } from "../../shared/dataset";
import { clipAudioUrl } from "../../shared/dataset";
import { readRecording, type DecodedAudio } from "../audio/decode";

export type DatasetLoad = { status: "ready"; index: DatasetIndex } | { status: "missing"; reason: string } | { status: "failed" };

const LOCAL_ONLY = "The recordings can only be used when you run the site on your own computer.";
let loading: Promise<DatasetLoad> | null = null;

export function loadDataset(): Promise<DatasetLoad> {
  loading ??= fetchDataset().then((result) => {
    if (result.status === "failed") loading = null; // a failed load can be tried again
    return result;
  });
  return loading;
}

async function fetchDataset(): Promise<DatasetLoad> {
  try {
    const r = await fetch("/api/dataset");
    // The hosted site has no dataset route (a 404, or its page instead of JSON), and the local
    // server refuses other machines (403).
    const json = (r.headers.get("content-type") ?? "").includes("application/json");
    if (r.status === 404 || r.status === 403 || (r.ok && !json)) return { status: "missing", reason: LOCAL_ONLY };
    if (!r.ok) return { status: "failed" };
    const body = (await r.json()) as DatasetResponse;
    return body.available ? { status: "ready", index: body } : { status: "missing", reason: body.reason };
  } catch {
    return { status: "failed" };
  }
}

/** A TORGO clip's audio, read from this computer's disk by the local server. */
export async function loadClipAudio(id: string, signal?: AbortSignal): Promise<{ bytes: ArrayBuffer; audio: DecodedAudio }> {
  const r = await fetch(clipAudioUrl(id), { signal });
  if (!r.ok) throw new Error(`The recording ${id} could not be read (${r.status}).`);
  const bytes = await r.arrayBuffer();
  return { bytes, audio: await readRecording(bytes) };
}

/** For tests: forget the cached list. */
export function resetDatasetLoader() {
  loading = null;
}
