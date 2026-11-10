const SESSION_KEY = "sync-task-session";
export const REMEMBER_KEY = "halo-sync-remembered-session";
const MAX_AGE = 30 * 24 * 60 * 60 * 1000;

export function browserStorage(name) {
  try {
    return globalThis[name] ?? null;
  } catch {
    return null;
  }
}

function minimalSession(value) {
  if (
    !value ||
    typeof value.token !== "string" ||
    !value.token ||
    value.token.length > 8192 ||
    !/^[a-z0-9]{15}$/.test(value.record?.id ?? "")
  )
    return null;
  // Persist only the login token and account ID, never passwords or profile fields.
  return { token: value.token, record: { id: value.record.id } };
}

/** Remembering is opt-in; PocketBase still validates expiry and revocation on every restore. */
export class BrowserSessionStore {
  constructor({
    persistent = null,
    transient = null,
    now = () => Date.now(),
  } = {}) {
    this.persistent = persistent;
    this.transient = transient;
    this.now = now;
    this.remember = false;
    this.expiresAt = null;
  }

  load() {
    try {
      const temporary = minimalSession(
        JSON.parse(this.transient?.getItem(SESSION_KEY) || "null"),
      );
      if (temporary) return temporary;
    } catch {
      /* Try remembered storage if transient storage is unavailable. */
    }
    try {
      const saved = JSON.parse(
        this.persistent?.getItem(REMEMBER_KEY) || "null",
      );
      const session = minimalSession(saved?.session);
      if (
        session &&
        Number.isFinite(saved.expiresAt) &&
        saved.expiresAt > this.now() &&
        saved.expiresAt <= this.now() + MAX_AGE
      ) {
        this.remember = true;
        this.expiresAt = saved.expiresAt;
        return session;
      }
      this.persistent?.removeItem(REMEMBER_KEY);
    } catch {
      /* Missing or corrupt saved state starts a fresh sign-in. */
    }
    return null;
  }

  save(value, remember = this.remember) {
    const session = minimalSession(value);
    if (!session)
      throw new Error("Invalid sign-in response. Please sign in again.");
    const expiry = remember
      ? this.remember && this.expiresAt
        ? this.expiresAt
        : this.now() + MAX_AGE
      : null;
    try {
      if (remember) {
        if (!this.persistent) throw new Error("Browser storage unavailable");
        this.persistent.setItem(
          REMEMBER_KEY,
          JSON.stringify({ session, expiresAt: expiry }),
        );
        this.transient?.removeItem(SESSION_KEY);
      } else {
        if (!this.transient) throw new Error("Session storage unavailable");
        this.transient.setItem(SESSION_KEY, JSON.stringify(session));
        this.persistent?.removeItem(REMEMBER_KEY);
      }
      this.remember = remember;
      this.expiresAt = expiry;
    } catch {
      this.clear();
      throw new Error(
        "This browser cannot save sign-in. You can use this tab, but will need to sign in again after closing it.",
      );
    }
  }

  clear(userId = null) {
    try {
      this.transient?.removeItem(SESSION_KEY);
    } catch {
      /* Inaccessible storage. */
    }
    try {
      const saved = JSON.parse(
        this.persistent?.getItem(REMEMBER_KEY) || "null",
      );
      if (
        !userId ||
        !saved?.session?.record?.id ||
        saved.session.record.id === userId
      )
        this.persistent?.removeItem(REMEMBER_KEY);
    } catch {
      /* Inaccessible storage. */
    }
    this.remember = false;
    this.expiresAt = null;
  }
}
