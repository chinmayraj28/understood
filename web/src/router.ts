// Which page the address shows. Hash routes, so the site stays a set of static files:
//   #/            the landing page (and #/how, #/results: the same page, scrolled to a section)
//   #/pipeline    the pipeline workspace
//   #/profiles    your profiles: whose voice the pipeline hears (#/profiles?new opens "New profile")
//   #/recordings  the TORGO speakers, as cards (#/recordings/F01: that speaker's recordings)
//   #/research    what fine-tuning a speech model on the speakers' own recordings did
// Older links still work: #dataset opens the recordings, and #hear=<clip> opens the pipeline
// and hears that clip.

import { useEffect, useState } from "react";

export type Page = "landing" | "pipeline" | "profiles" | "recordings" | "research";

export interface Route {
  page: Page;
  /** A landing-page section to scroll to ("how", "results"). */
  section?: string;
  /** A TORGO clip to hear as soon as the pipeline is ready. */
  hearClip?: string;
  /** A TORGO speaker whose recordings the recordings page shows, such as "F01". */
  speaker?: string;
  /** Open the "New profile" form on the profiles page. */
  create?: boolean;
}

export function parseRoute(hash: string): Route {
  const h = hash.replace(/^#/, "");
  if (h.startsWith("hear=")) {
    // A broken link ("#hear=%E0") opens the pipeline without a clip, rather than a blank page.
    try {
      return { page: "pipeline", hearClip: decodeURIComponent(h.slice(5)) };
    } catch {
      return { page: "pipeline" };
    }
  }
  if (h.startsWith("/recordings/")) {
    // A speaker id is letters and digits ("F01", "FC02"); anything else opens the list of speakers.
    const speaker = h.slice("/recordings/".length).split(/[/?]/)[0];
    return /^[A-Za-z0-9]{1,12}$/.test(speaker) ? { page: "recordings", speaker: speaker.toUpperCase() } : { page: "recordings" };
  }
  if (h === "dataset" || h.startsWith("dataset") || h.startsWith("/recordings")) return { page: "recordings" };
  if (h === "/research" || h.startsWith("/research/") || h.startsWith("/research?")) return { page: "research" };
  if (h === "/profiles" || h.startsWith("/profiles/") || h.startsWith("/profiles?")) {
    return new URLSearchParams(h.split("?")[1] ?? "").has("new") ? { page: "profiles", create: true } : { page: "profiles" };
  }
  if (h.startsWith("/pipeline")) {
    const clip = new URLSearchParams(h.split("?")[1] ?? "").get("hear");
    return clip ? { page: "pipeline", hearClip: clip } : { page: "pipeline" };
  }
  const section = h.startsWith("/") ? h.slice(1) : "";
  return section && ["how", "results"].includes(section) ? { page: "landing", section } : { page: "landing" };
}

export const href = {
  landing: "#/",
  how: "#/how",
  results: "#/results",
  pipeline: "#/pipeline",
  profiles: "#/profiles",
  newProfile: "#/profiles?new",
  recordings: "#/recordings",
  speaker: (id: string) => `#/recordings/${encodeURIComponent(id)}`,
  research: "#/research",
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
