// Small per-visitor preferences in localStorage. Any failure (private window, blocked storage)
// falls back to the default; nothing important depends on them.

export function readSetting<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(`understood.${key}`);
    return raw === null ? fallback : (JSON.parse(raw) as T);
  } catch {
    return fallback;
  }
}

export function writeSetting<T>(key: string, value: T) {
  try {
    localStorage.setItem(`understood.${key}`, JSON.stringify(value));
  } catch {
    /* storage blocked: the setting lasts for this visit only */
  }
}
