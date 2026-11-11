import test from "node:test";
import assert from "node:assert/strict";
import { TaskStore, newRecordId } from "../src/tasks.js";

const user = "aaaaaaaaaaaaaaa",
  id = "bbbbbbbbbbbbbbb";
const initial = {
  id,
  user,
  title: "Study circuits",
  priority: "normal",
  is_completed: false,
  updated: "version1",
};
function storage() {
  const data = new Map();
  return {
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, value) => data.set(key, value),
  };
}
function server(records = [initial]) {
  const rows = new Map(records.map((row) => [row.id, structuredClone(row)]));
  const calls = [];
  let version = 1;
  const api = async (path, { method = "GET", body } = {}) => {
    calls.push({ method, path, body });
    const recordId = path.split("/").pop();
    if (path.includes("?")) return { items: [...rows.values()], totalPages: 1 };
    if (method === "POST") {
      if (rows.has(body.id))
        throw Object.assign(new Error("Duplicate"), { status: 400 });
      const row = { ...body, updated: `version${++version}` };
      rows.set(body.id, row);
      return row;
    }
    if (!rows.has(recordId))
      throw Object.assign(new Error("Missing"), { status: 404 });
    if (method === "DELETE") {
      rows.delete(recordId);
      return null;
    }
    if (method === "PATCH") {
      const row = {
        ...rows.get(recordId),
        ...body,
        updated: `version${++version}`,
      };
      rows.set(recordId, row);
      return row;
    }
    return structuredClone(rows.get(recordId));
  };
  return { rows, calls, api };
}

test("Daily credit survives completion deletion, remote cleanup, reload, and new tasks", async () => {
  const db = server(),
    local = storage();
  const store = new TaskStore(user, db.api, local);
  await store.sync();
  store.edit(id, {
    is_completed: true,
    completed_at: new Date().toISOString(),
  });
  await store.sync();
  db.rows.clear();
  await store.sync();
  assert.deepEqual(store.dailyProgress(), { completed: 1, goal: 3 });
  const restored = new TaskStore(user, db.api, local);
  restored.edit(
    "ccccccccccccccc",
    { title: "Next task", is_completed: false },
    "POST",
  );
  assert.equal(restored.dailyProgress().completed, 1);
  restored.edit(
    "ddddddddddddddd",
    {
      title: "Second win",
      is_completed: true,
      completed_at: new Date().toISOString(),
    },
    "POST",
  );
  restored.edit("ddddddddddddddd", {}, "DELETE");
  assert.equal(restored.dailyProgress().completed, 2);
  await restored.sync();
  assert.equal(new TaskStore(user, db.api, local).dailyProgress().completed, 2);
  assert.equal(
    new TaskStore("eeeeeeeeeeeeeee", db.api, local).dailyProgress().completed,
    0,
  );
});

test("Reopening removes credit, repeated sync cannot duplicate it, and old dates do not count", async () => {
  const db = server(),
    store = new TaskStore(user, db.api, storage());
  await store.sync();
  const completion = {
    is_completed: true,
    completed_at: new Date().toISOString(),
  };
  store.edit(id, completion);
  await store.sync();
  await store.sync();
  assert.equal(store.dailyProgress().completed, 1);
  store.edit(id, { is_completed: false, completed_at: "" });
  assert.equal(store.dailyProgress().completed, 0);
  store.edit(id, completion);
  assert.equal(store.dailyProgress().completed, 1);
  store.edit(id, { is_completed: true, completed_at: "2020-01-01T12:00:00Z" });
  assert.equal(store.dailyProgress().completed, 0);
});

test("Daily progress rolls over at local midnight and excludes malformed and future dates", () => {
  const store = new TaskStore(user, server().api, storage());
  const before = new Date(2026, 10, 10, 23, 59);
  const next = new Date(2026, 10, 11, 0, 1);
  store.observeCompletions(
    [{ id, is_completed: true, completed_at: before.toISOString() }],
    before,
  );
  assert.equal(store.dailyProgress(before).completed, 1);
  assert.equal(store.dailyProgress(next).completed, 0);
  store.observeCompletions(
    [
      { id, is_completed: true, completed_at: before.toISOString() },
      { id: "bad", is_completed: true, completed_at: "invalid" },
      {
        id: "future",
        is_completed: true,
        completed_at: "2028-01-01T12:00:00Z",
      },
    ],
    next,
  );
  assert.equal(store.dailyProgress(next).completed, 0);
});

test("Discarding an offline completion removes provisional daily credit", async () => {
  const db = server(),
    store = new TaskStore(user, db.api, storage());
  await store.sync();
  store.edit(id, {
    is_completed: true,
    completed_at: new Date().toISOString(),
  });
  assert.equal(store.dailyProgress().completed, 1);
  store.discardEdits();
  await store.sync();
  assert.equal(store.dailyProgress().completed, 0);
});

test("An ambiguous create response retries the same ID without duplicating tasks", async () => {
  const db = server([]),
    local = storage();
  let loseResponse = true;
  const api = async (path, options) => {
    const result = await db.api(path, options);
    if (options?.method === "POST" && loseResponse) {
      loseResponse = false;
      throw new Error("Connection lost after write");
    }
    return result;
  };
  let store = new TaskStore(user, api, local);
  store.edit(id, { title: "Study", is_completed: false }, "POST");
  await assert.rejects(store.sync(), /Connection lost/);
  assert.equal(store.queue.length, 1);
  store = new TaskStore(user, api, local);
  await store.sync();
  assert.equal(db.rows.size, 1);
  assert.equal(store.queue.length, 0);
  assert.equal(db.calls.filter((call) => call.method === "POST").length, 1);
});

test("Changed records cannot silently overwrite another device’s edit", async () => {
  const db = server(),
    store = new TaskStore(user, db.api, storage());
  await store.sync();
  store.edit(id, { title: "My offline title" });
  db.rows.set(id, { ...initial, title: "Another device", updated: "version2" });
  await assert.rejects(store.sync(), /changed on another device/);
  assert.equal(db.rows.get(id).title, "Another device");
  assert.equal(store.queue.length, 1);
  assert.equal(store.tasks[0].title, "My offline title");
});

test("Sequential offline edits carry their new versions across failed syncs", async () => {
  const db = server(),
    local = storage();
  let failRead = false;
  const store = new TaskStore(
    user,
    async (path, options) => {
      if (failRead && !options) throw new Error("offline");
      const result = await db.api(path, options);
      if (options?.method === "PATCH") failRead = true;
      return result;
    },
    local,
  );
  await store.sync();
  store.edit(id, { title: "New title" });
  store.edit(id, { description: "Second edit" });
  await assert.rejects(store.sync(), /offline/);
  const recovered = new TaskStore(user, db.api, local);
  await recovered.sync();
  assert.equal(db.rows.get(id).title, "New title");
  assert.equal(db.rows.get(id).description, "Second edit");
  assert.equal(recovered.queue.length, 0);
});

test("Offline cache and writes are isolated by signed-in account", async () => {
  const local = storage(),
    db = server();
  const first = new TaskStore(user, db.api, local);
  await first.sync();
  first.edit(id, { title: "Private title", user: "ccccccccccccccc" });
  const second = new TaskStore("ccccccccccccccc", db.api, local);
  assert.equal(second.tasks.length, 0);
  assert.equal(second.queue.length, 0);
  await first.sync();
  assert.equal(db.rows.get(id).user, user);
});

test("A delete whose response is lost is safe to retry", async () => {
  const db = server(),
    local = storage();
  let loseResponse = true;
  const store = new TaskStore(
    user,
    async (path, options) => {
      const result = await db.api(path, options);
      if (options?.method === "DELETE" && loseResponse) {
        loseResponse = false;
        throw new Error("Lost");
      }
      return result;
    },
    local,
  );
  await store.sync();
  store.edit(id, {}, "DELETE");
  await assert.rejects(store.sync(), /Lost/);
  await new TaskStore(user, db.api, local).sync();
  assert.equal(db.rows.size, 0);
});

test("Sync fetches every page without dropping earlier records", async () => {
  const store = new TaskStore(
    user,
    async (path) => ({
      items: [
        { ...initial, id: path.includes("page=1&") ? id : "ccccccccccccccc" },
      ],
      totalPages: 2,
    }),
    storage(),
  );
  await store.sync();
  assert.equal(store.tasks.length, 2);
});

test("Concurrent sync triggers serialize one write", async () => {
  const db = server([]),
    store = new TaskStore(user, db.api, storage());
  store.edit(id, { title: "Only once" }, "POST");
  await Promise.all([store.sync(), store.sync(), store.sync()]);
  assert.equal(db.calls.filter((call) => call.method === "POST").length, 1);
});

test("Storage failure warns while retaining the draft in memory", () => {
  const store = new TaskStore(user, () => {}, {
    getItem: () => null,
    setItem: () => {
      throw new Error("Full");
    },
  });
  assert.throws(
    () => store.edit(id, { title: "Do not discard" }, "POST"),
    /storage is full/,
  );
  assert.equal(store.queue.length, 1);
  assert.equal(store.tasks[0].title, "Do not discard");
});

test("Browser-generated IDs satisfy PocketBase record ID requirements", () => {
  assert.match(newRecordId(), /^[a-z0-9]{15}$/);
  assert.throws(
    () => new TaskStore("../admin", () => {}, storage()),
    /Invalid/,
  );
});
