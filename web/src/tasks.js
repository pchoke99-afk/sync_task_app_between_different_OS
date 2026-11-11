const priorities = { high: 0, normal: 1, low: 2 };
const taskFields = [
  "title",
  "description",
  "priority",
  "is_completed",
  "completed_at",
];

export function newRecordId(cryptoProvider = globalThis.crypto) {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  return [...cryptoProvider.getRandomValues(new Uint8Array(15))]
    .map((value) => alphabet[value % alphabet.length])
    .join("");
}

function sortTasks(tasks) {
  return tasks.sort(
    (a, b) =>
      Number(a.is_completed) - Number(b.is_completed) ||
      (priorities[a.priority] ?? 1) - (priorities[b.priority] ?? 1) ||
      String(b.created ?? "").localeCompare(String(a.created ?? "")),
  );
}

const dailyGoal = 3;
const localDay = (date) =>
  `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;

function changedFieldsMatch(record, fields) {
  return Object.entries(fields).every(([key, value]) => record[key] === value);
}

/** User-partitioned offline edits. Failed writes stay queued; creates use stable IDs. */
export class TaskStore {
  constructor(user, api, storage = globalThis.localStorage) {
    if (!/^[a-z0-9]{15}$/.test(user)) throw new Error("Invalid task account.");
    this.user = user;
    this.api = api;
    this.storage = storage;
    this.key = `sync-task-web:v1:${user}`;
    this.queue = [];
    this.tasks = [];
    this.running = null;
    this.completionDay = "";
    this.completions = new Set();
    try {
      const saved = JSON.parse(storage.getItem(this.key) || "{}");
      this.tasks = Array.isArray(saved.tasks)
        ? saved.tasks.filter((t) => t.user === user)
        : [];
      this.queue = Array.isArray(saved.queue)
        ? saved.queue.filter((op) => op.user === user)
        : [];
      this.completionDay = saved.completionDay ?? "";
      if (Array.isArray(saved.completions))
        this.completions = new Set(saved.completions);
    } catch {
      // Missing or corrupt browser storage starts with an empty offline cache.
    }
    this.observeCompletions(this.tasks);
  }

  observeCompletions(tasks, now = new Date()) {
    const day = localDay(now);
    if (this.completionDay !== day) {
      this.completionDay = day;
      this.completions.clear();
    }
    for (const task of tasks) {
      if (
        task.is_completed &&
        localDay(new Date(task.completed_at?.replace(" ", "T"))) === day
      ) {
        this.completions.add(task.id);
      } else {
        this.completions.delete(task.id);
      }
    }
  }

  dailyProgress(now = new Date()) {
    return {
      completed:
        this.completionDay === localDay(now) ? this.completions.size : 0,
      goal: dailyGoal,
    };
  }

  persist() {
    try {
      this.storage.setItem(
        this.key,
        JSON.stringify({
          tasks: this.tasks,
          queue: this.queue,
          completionDay: this.completionDay,
          completions: [...this.completions],
        }),
      );
    } catch {
      throw new Error(
        "Browser storage is full or unavailable. Leave this page open until your edits have synced.",
      );
    }
  }

  overlay(records) {
    const byId = new Map(
      records.filter((t) => t.user === this.user).map((t) => [t.id, t]),
    );
    for (const op of this.queue) {
      if (op.method === "DELETE") byId.delete(op.id);
      else
        byId.set(op.id, {
          ...byId.get(op.id),
          ...op.fields,
          id: op.id,
          user: this.user,
        });
    }
    return sortTasks([...byId.values()]);
  }

  edit(id, fields, method = "PATCH") {
    if (!/^[a-z0-9]{15}$/.test(id)) throw new Error("Invalid task ID.");
    const index = this.tasks.findIndex((t) => t.id === id);
    const existing = this.tasks[index];
    if (method !== "POST" && !existing)
      throw new Error("Task is no longer available. Sync and try again.");
    const safe = Object.fromEntries(
      taskFields
        .filter((key) => key in fields)
        .map((key) => [key, fields[key]]),
    );
    this.queue.push({
      user: this.user,
      id,
      method,
      fields: safe,
      baseUpdated: existing?.updated ?? null,
    });
    if (method === "DELETE") {
      this.tasks.splice(index, 1);
    } else {
      const task = { ...existing, ...safe, id, user: this.user };
      if (index === -1) this.tasks.push(task);
      else this.tasks[index] = task;
      sortTasks(this.tasks);
      this.observeCompletions([task]);
    }
    this.persist();
  }

  discardEdits() {
    if (this.running)
      throw new Error("Wait for sync to finish before discarding edits.");
    for (const op of this.queue) {
      if ("is_completed" in op.fields) this.completions.delete(op.id);
    }
    this.queue = [];
    this.tasks = [];
    this.persist();
  }

  sync() {
    if (this.running) return this.running;
    this.running = this._sync().finally(() => {
      this.running = null;
    });
    return this.running;
  }

  async _sync() {
    while (this.queue.length) {
      const op = this.queue[0];
      if (op.user !== this.user) throw new Error("Task account mismatch.");
      const path = `/pb/api/collections/tasks/records/${op.id}`;
      let current = null;
      try {
        current = await this.api(path);
      } catch (error) {
        if (error.status !== 404) throw error;
      }
      let latest = current;
      if (current && current.user !== this.user)
        throw new Error("Task account mismatch.");
      if (op.method === "POST") {
        if (!current) {
          latest = await this.api("/pb/api/collections/tasks/records", {
            method: "POST",
            body: { ...op.fields, id: op.id, user: this.user },
          });
        } else if (!changedFieldsMatch(current, op.fields)) {
          throw new Error(
            "A queued task conflicts with the server. Your offline copy is preserved.",
          );
        }
      } else if (op.method === "DELETE") {
        if (current) {
          if (op.baseUpdated && current.updated !== op.baseUpdated) {
            throw new Error(
              "A task changed on another device before deletion. Review your offline edits in Settings.",
            );
          }
          await this.api(path, { method: "DELETE" });
        }
      } else {
        if (!current)
          throw new Error(
            "A task was deleted on another device. Your offline edit is preserved in Settings.",
          );
        if (!changedFieldsMatch(current, op.fields)) {
          if (op.baseUpdated && current.updated !== op.baseUpdated) {
            throw new Error(
              "A task changed on another device. Your offline edit is preserved in Settings.",
            );
          }
          latest = await this.api(path, { method: "PATCH", body: op.fields });
        }
      }
      this.queue.shift();
      // Carry forward the version we just wrote, so sequential offline edits remain safe.
      for (const queued of this.queue) {
        if (queued.id === op.id && latest?.updated)
          queued.baseUpdated = latest.updated;
      }
      this.persist();
    }
    // Fetch every page, not just the first 100 tasks.
    const records = [];
    let page = 1;
    let result;
    do {
      const query = new URLSearchParams({
        page: String(page++),
        perPage: "100",
        filter: `user = "${this.user}"`,
        sort: "-created",
      });
      result = await this.api(`/pb/api/collections/tasks/records?${query}`);
      records.push(...result.items);
    } while (page <= result.totalPages);
    this.tasks = this.overlay(records);
    this.observeCompletions(this.tasks);
    this.persist();
    return this.tasks;
  }
}
