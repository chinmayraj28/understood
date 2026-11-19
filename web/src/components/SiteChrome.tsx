// The bar across the top of every page and the footer under it.

import { onSectionLink } from "../pages/Landing";
import { href, type Page } from "../router";

export function SiteHeader({ page }: { page: Page }) {
  return (
    <header className="site-header">
      <div className="site-header-inner">
        <a className="wordmark" href={href.landing} aria-label="Understood, home">
          <ForkMark />
          <span>Understood</span>
        </a>
        <nav className="site-nav" aria-label="Main">
          <a href={href.how} onClick={onSectionLink("how")}>
            How it works
          </a>
          <a href={href.results} onClick={onSectionLink("results")}>
            Results
          </a>
          <a href={href.pipeline} aria-current={page === "pipeline" ? "page" : undefined}>
            Pipeline
          </a>
          <a href={href.recordings} aria-current={page === "recordings" ? "page" : undefined}>
            Recordings
          </a>
        </nav>
        <div className="site-actions">
          {page !== "pipeline" && (
            <a className="button primary small" href={href.pipeline}>
              Open the pipeline
            </a>
          )}
        </div>
      </div>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="site-footer-inner">
        <a className="wordmark" href={href.landing}>
          <ForkMark />
          <span>Understood</span>
        </a>
        <p>
          Built for the Hiya Voice AI Challenge. Evaluated on TORGO (Rudzicz, Namasivayam and Wolff, 2012), University of Toronto and Holland
          Bloorview.
        </p>
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
