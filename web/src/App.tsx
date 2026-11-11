// The site: a landing page, the pipeline workspace, and the TORGO recordings, each its own page
// under one header. The session (microphone, your conversation, recordings being heard) lives
// here, so it survives moving between pages.

import { useEffect, useRef, type MouseEvent } from "react";
import { Dataset } from "./components/Dataset";
import { SiteFooter, SiteHeader } from "./components/SiteChrome";
import { loadDataset } from "./model/datasetLoader";
import { Landing } from "./pages/Landing";
import { PipelinePage } from "./pages/PipelinePage";
import { useRoute, type Page } from "./router";
import { microphoneAllowed, useSession } from "./useSession";

const TITLES: Record<Page, string> = {
  landing: "Understood: speech other assistants get wrong",
  pipeline: "Pipeline · Understood",
  recordings: "Recordings · Understood",
};

export function App() {
  const session = useSession();
  const route = useRoute();
  const { page } = route;

  useEffect(() => {
    document.title = TITLES[page];
  }, [page]);

  // The microphone and any recording belong to the pipeline page. Leaving it stops both (a clip
  // played on the recordings page must not be heard as the person) and closes the voice setup;
  // if the microphone was on, it comes back on with the pipeline, so a hands-free visitor does
  // not lose their voice control.
  const { listening, leavePipeline, startListening, hearRecording, showNotice } = session;
  const resumeListening = useRef(false);
  const pageRef = useRef(page);
  pageRef.current = page;
  useEffect(() => {
    if (page !== "pipeline") {
      if (leavePipeline()) resumeListening.current = true;
    } else if (resumeListening.current) {
      resumeListening.current = false;
      void startListening();
    }
  }, [page, listening, leavePipeline, startListening]);

  // Hands-free start on first load, if the visitor asked for it and the browser already allows
  // the microphone. Only on the pipeline page; anywhere else it waits until the visitor gets there.
  const autoChecked = useRef(false);
  useEffect(() => {
    if (!session.settings.autoListen || autoChecked.current) return;
    autoChecked.current = true; // once, even when React runs this twice in development
    void microphoneAllowed().then((allowed) => {
      if (!allowed) return;
      if (pageRef.current === "pipeline") void startListening();
      else resumeListening.current = true;
    });
    // Only on first load.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // "#/pipeline?hear=<clip>" (the recordings page links here) hears that clip once the page is ready.
  const ready = session.own !== null;
  const handled = useRef<typeof route | null>(null);
  useEffect(() => {
    if (!ready || !route.hearClip || handled.current === route) return;
    handled.current = route;
    const id = route.hearClip;
    history.replaceState(null, "", "#/pipeline");
    requestAnimationFrame(() => {
      const title = document.getElementById("hear-title");
      const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      title?.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "start" });
      title?.focus({ preventScroll: true });
    });
    void loadDataset().then((load) => {
      // The visitor may have moved on while the list loaded: never play a clip off the pipeline.
      if (pageRef.current !== "pipeline") return;
      if (load.status !== "ready") {
        return showNotice(load.status === "missing" ? load.reason : "The recordings couldn’t be loaded. Is the server running?");
      }
      const clip = load.index.clips.find((c) => c.id === id);
      if (clip) void hearRecording({ kind: "torgo", clip, index: load.index });
      else showNotice("That recording isn’t in this copy of TORGO.");
    });
  }, [ready, route, hearRecording, showNotice]);

  // A new page starts at the top; the landing page scrolls itself to a section when asked.
  useEffect(() => {
    if (page !== "landing") window.scrollTo({ top: 0 });
  }, [page]);

  // After moving to another page, focus goes to its heading, so a screen reader starts there.
  // Not on first load, and not when a section or a recording link moves focus itself (the
  // recordings page focuses its own heading).
  const shownRoute = useRef(route);
  useEffect(() => {
    if (shownRoute.current === route) return;
    const pageChanged = shownRoute.current.page !== route.page;
    shownRoute.current = route;
    if (!pageChanged || route.section || route.hearClip || route.page === "recordings") return;
    const heading = route.page === "landing" ? "hero-title" : "pipeline-title";
    document.getElementById(heading)?.focus({ preventScroll: true }); // the new page is already in place when effects run
  }, [route]);

  const skipTarget = page === "recordings" ? "dataset-title" : page === "pipeline" ? "hear-title" : "main";
  return (
    <>
      <SkipLink target={skipTarget}>
        {page === "recordings" ? "Skip to the recordings" : page === "pipeline" ? "Skip to the pipeline" : "Skip to the content"}
      </SkipLink>
      <SiteHeader page={page} />
      {page === "landing" && <Landing section={route.section} />}
      {page === "pipeline" && <PipelinePage session={session} />}
      {page === "recordings" && (
        <main id="main" className="page-shell">
          <Dataset />
        </main>
      )}
      {page !== "pipeline" && <SiteFooter />}
    </>
  );
}

/** Moves focus without touching the address, which here says which page is open. */
function SkipLink({ target, children }: { target: string; children: string }) {
  const onClick = (event: MouseEvent) => {
    event.preventDefault();
    const element = document.getElementById(target);
    if (!element) return;
    if (!element.hasAttribute("tabindex")) element.setAttribute("tabindex", "-1");
    element.focus();
  };
  return (
    <a className="skip-link" href={`#${target}`} onClick={onClick}>
      {children}
    </a>
  );
}
