import test from "node:test";
import assert from "node:assert/strict";
import { BrowserSessionStore, REMEMBER_KEY } from "../src/browser_session.js";

function storage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
}
const session = {
  token: "synthetic-session-token",
  record: { id: "aaaaaaaaaaaaaaa", email: "private@example.test" },
  password: "not-persisted",
};

test("Remember me restores after browser session storage is replaced", () => {
  const persistent = storage();
  const store = new BrowserSessionStore({ persistent, transient: storage() });
  store.save(session, true);
  const restored = new BrowserSessionStore({
    persistent,
    transient: storage(),
  });
  assert.equal(restored.load().token, session.token);
  assert.equal(restored.remember, true);
  assert.equal(
    persistent.getItem(REMEMBER_KEY).includes("private@example.test"),
    false,
  );
  assert.equal(
    persistent.getItem(REMEMBER_KEY).includes("not-persisted"),
    false,
  );
});
test("Unchecked login remains temporary and removes an older remembered login", () => {
  const persistent = storage(),
    transient = storage();
  const store = new BrowserSessionStore({ persistent, transient });
  store.save(session, true);
  store.save(session, false);
  assert.equal(persistent.getItem(REMEMBER_KEY), null);
  assert.equal(
    new BrowserSessionStore({ persistent, transient }).load().token,
    session.token,
  );
  assert.equal(
    new BrowserSessionStore({ persistent, transient: storage() }).load(),
    null,
  );
});
test("Logout removes both login stores without removing offline task edits", () => {
  const persistent = storage(),
    transient = storage();
  persistent.setItem("sync-task-web:v1:aaaaaaaaaaaaaaa", "offline draft");
  const store = new BrowserSessionStore({ persistent, transient });
  store.save(session, true);
  store.clear();
  assert.equal(new BrowserSessionStore({ persistent, transient }).load(), null);
  assert.equal(
    persistent.getItem("sync-task-web:v1:aaaaaaaaaaaaaaa"),
    "offline draft",
  );
});
test("Remembered login has a fixed 30-day limit that refresh does not extend", () => {
  let time = 1000000;
  const persistent = storage(),
    transient = storage(),
    now = () => time;
  const store = new BrowserSessionStore({ persistent, transient, now });
  store.save(session, true);
  time += 29 * 86400000;
  store.save({ ...session, token: "synthetic-refreshed-token" });
  time += 2 * 86400000;
  assert.equal(
    new BrowserSessionStore({ persistent, transient, now }).load(),
    null,
  );
  assert.equal(persistent.getItem(REMEMBER_KEY), null);
});
test("Malformed stored credentials are ignored", () => {
  const persistent = storage();
  persistent.setItem(REMEMBER_KEY, "{bad");
  assert.equal(new BrowserSessionStore({ persistent }).load(), null);
});
test("Unavailable persistent storage never leaves a stale saved login", () => {
  const store = new BrowserSessionStore({
    persistent: {
      getItem: () => null,
      setItem: () => {
        throw new Error("Blocked");
      },
      removeItem: () => {},
    },
    transient: storage(),
  });
  assert.throws(() => store.save(session, true), /cannot save sign-in/);
  assert.equal(store.remember, false);
});
test("Signing out an old tab does not remove a different account remembered in a new tab", () => {
  const persistent = storage(),
    transient = storage();
  const store = new BrowserSessionStore({ persistent, transient });
  store.save(
    { token: "synthetic-other-token", record: { id: "bbbbbbbbbbbbbbb" } },
    true,
  );
  store.clear("aaaaaaaaaaaaaaa");
  assert.equal(
    new BrowserSessionStore({ persistent, transient }).load().record.id,
    "bbbbbbbbbbbbbbb",
  );
});
