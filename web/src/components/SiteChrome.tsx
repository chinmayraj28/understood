// The bar across the top of every page and the footer under it.

import type { ReactNode } from "react";
import { href, type Page } from "../router";

export function SiteHeader({ page, actions }: { page: Page; actions?: ReactNode }) {
  return (
    <header className="site-header">
      <div className="site-header-inner">
        <a className="wordmark" href={href.landing} aria-label="Understood, home">
          <ForkMark />
          <span>Understood</span>
        </a>
        <nav className="site-nav" aria-label="Main">
          <a href={href.how}>How it works</a>
          <a href={href.results}>Results</a>
          <a href={href.pipeline} aria-current={page === "pipeline" ? "page" : undefined}>
            Pipeline
          </a>
          <a href={href.recordings} aria-current={page === "recordings" ? "page" : undefined}>
            Recordings
          </a>
        </nav>
        <div className="site-actions">
          {actions ??
            (page !== "pipeline" && (
              <a className="button primary small" href={href.pipeline}>
                Open the pipeline
              </a>
            ))}
        </div>
      </div>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="site-footer-inner">
        <div className="footer-brand">
          <a className="wordmark" href={href.landing}>
            <ForkMark />
            <span>Understood</span>
          </a>
          <p>A speech pipeline for people with dysarthria, built for the Hiya Voice AI Challenge, accessibility track.</p>
        </div>
        <div className="footer-cols">
          <div>
            <h2>Use it</h2>
            <ul>
              <li>
                <a href={href.pipeline}>Pipeline</a>
              </li>
              <li>
                <a href={href.recordings}>Recordings</a>
              </li>
              <li>
                <a href={href.results}>Results</a>
              </li>
            </ul>
          </div>
          <div>
            <h2>Built with</h2>
            <ul>
              <li>ElevenLabs Scribe and realtime</li>
              <li>Gemini Flash, through OpenRouter</li>
              <li>Claude Haiku 5.5</li>
            </ul>
          </div>
          <div>
            <h2>Data</h2>
            <p>
              TORGO, University of Toronto and Holland Bloorview (Rudzicz, Namasivayam and Wolff, 2012). Used to evaluate only, never to train,
              and never published here.
            </p>
          </div>
        </div>
      </div>
    </footer>
  );
}

/** The mark: a track meeting a switch, one branch lit. */
export function ForkMark() {
  return (
    <svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--ink)" />
      <path d="M5 21h8c3 0 4-2 6-6s3-6 7-6" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round" />
      <path d="M13 21h13" fill="none" stroke="var(--mark)" strokeWidth="3" strokeLinecap="round" />
      <circle cx="5" cy="21" r="3" fill="#fff" />
    </svg>
  );
}
