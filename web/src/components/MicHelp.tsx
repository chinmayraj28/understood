// Shown when the microphone was refused. A page cannot make the browser ask again once the site
// is blocked: only the person can change that, in the browser's site settings. So this says
// exactly where, offers "Ask again" (which works while the browser may still ask), and the page
// starts listening by itself the moment the setting changes to Allow (useSession).

export function MicHelp(props: { permission: PermissionState | "unknown"; onRetry: () => void }) {
  const blockedBySite = props.permission === "denied";
  return (
    <div className="mic-help" role="alert">
      <p className="mic-help-title">{blockedBySite ? "The microphone is blocked for this site" : "The microphone couldn’t be opened"}</p>
      {blockedBySite ? (
        <ol>
          <li>Click the icon at the left end of the address bar (next to the address).</li>
          <li>
            Turn <strong>Microphone</strong> on, or choose <strong>Reset permission</strong>.
          </li>
          <li>Listening starts by itself. If it doesn&rsquo;t, press Ask again.</li>
        </ol>
      ) : (
        <ol>
          <li>Press Ask again, and choose Allow when the browser asks.</li>
          <li>
            If nothing asks, your Mac may be blocking the browser: open <strong>System Settings → Privacy &amp; Security → Microphone</strong>,
            turn on your browser, then restart it.
          </li>
        </ol>
      )}
      <button className="button small" onClick={props.onRetry}>
        Ask again
      </button>
    </div>
  );
}
