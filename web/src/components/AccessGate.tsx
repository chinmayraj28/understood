// The keyword screen for a public demo link. When the server is locked (ACCESS_KEY set), the page
// asks once for the keyword sent with the submission, checks it, and keeps it in this browser.

import { useEffect, useState, type FormEvent, type ReactNode } from "react";

const STORE = "understood-access-key";

function storedKey(): string {
  try {
    return localStorage.getItem(STORE) ?? "";
  } catch {
    return "";
  }
}

async function unlock(key: string): Promise<boolean> {
  const r = await fetch("/api/unlock", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ key }) }).catch(() => null);
  return Boolean(r?.ok);
}

export function AccessGate({ children }: { children: ReactNode }) {
  const [state, setState] = useState<"checking" | "open" | "locked">("checking");
  const [key, setKey] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    void (async () => {
      const health = (await fetch("/api/health").then((r) => r.json()).catch(() => null)) as { locked?: boolean } | null;
      if (!health?.locked) return setState("open");
      const saved = storedKey();
      setState(saved && (await unlock(saved)) ? "open" : "locked");
    })();
  }, []);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setError("");
    if (await unlock(key.trim())) {
      try {
        localStorage.setItem(STORE, key.trim());
      } catch {
        /* this visit only */
      }
      setState("open");
    } else {
      setError("That keyword is not right.");
    }
  };

  if (state === "open") return <>{children}</>;
  if (state === "checking") return null;
  return (
    <main className="gate">
      <form className="gate-card" onSubmit={(e) => void submit(e)}>
        <h1>Understood</h1>
        <p>This demo is private. Enter the keyword that came with the submission.</p>
        <label htmlFor="gate-key">Keyword</label>
        <input id="gate-key" type="password" autoComplete="off" autoFocus value={key} onChange={(e) => setKey(e.target.value)} />
        {error && <p role="alert" className="gate-error">{error}</p>}
        <button className="button primary" type="submit">
          Open the demo
        </button>
      </form>
    </main>
  );
}
