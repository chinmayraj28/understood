// Which page the address shows. Hash routes, so the site stays a set of static files:
//   #/            the landing page (and #/how, #/results: the same page, scrolled to a section)
//   #/pipeline    the pipeline workspace
//   #/recordings  the TORGO recordings
// Older links still work: #dataset opens the recordings, and #hear=<clip> opens the pipeline
// and hears that clip.

import { useEffect, useState } from "react";

export type Page = "landing" | "pipeline" | "recordings";

export interface Route {
  page: Page;
  /** A landing-page section to scroll to ("how", "results"). */
  section?: string;
  /** A TORGO clip to hear as soon as the pipeline is ready. */
  hearClip?: string;
}

export function parseRoute(hash: string): Route {
  const h = hash.replace(/^#/, "");
  if (h.startsWith("hear=")) return { page: "pipeline", hearClip: decodeURIComponent(h.slice(5)) };
  if (h === "dataset" || h.startsWith("dataset") || h.startsWith("/recordings")) return { page: "recordings" };
  if (h.startsWith("/pipeline")) {
    const clip = new URLSearchParams(h.split("?")[1] ?? "").get("hear");
    return clip ? { page: "pipeline", hearClip: clip } : { page: "pipeline" };
  }
  const section = h.startsWith("/") ? h.slice(1) : "";
  return section && ["how", "results", "privacy"].includes(section) ? { page: "landing", section } : { page: "landing" };
}

export const href = {
  landing: "#/",
  how: "#/how",
  results: "#/results",
  pipeline: "#/pipeline",
  recordings: "#/recordings",
  hear: (clipId: string) => `#/pipeline?hear=${encodeURIComponent(clipId)}`,
};

export function useRoute(): Route {
  const [route, setRoute] = useState(() => parseRoute(window.location.hash));
  useEffect(() => {
    const onHash = () => setRoute(parseRoute(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  return route;
}
