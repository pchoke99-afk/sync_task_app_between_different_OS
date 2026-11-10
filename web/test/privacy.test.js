import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { Calendar } from "../src/calendar.js";

test("Service worker never intercepts private APIs, OAuth queries, or other origins", async () => {
  const handlers = {};
  vm.runInNewContext(
    await readFile(new URL("../sw.js", import.meta.url), "utf8"),
    {
      self: {
        addEventListener: (event, handler) => {
          handlers[event] = handler;
        },
        location: { origin: "https://tasks.example.test" },
      },
      URL,
    },
  );
  for (const [method, url] of [
    ["GET", "/pb/api/collections/tasks/records"],
    ["GET", "/ai/conversations"],
    ["POST", "/ai/chat"],
    ["GET", "/index.html?token=private"],
    ["GET", "https://accounts.google.com/gsi/client"],
  ]) {
    let intercepted = false;
    handlers.fetch({
      request: { method, url: new URL(url, "https://tasks.example.test").href },
      respondWith: () => {
        intercepted = true;
      },
    });
    assert.equal(intercepted, false, url);
  }
});

test("Calendar sends only busy intervals to the assistant and retains tokens in memory", async () => {
  const calendar = new Calendar();
  calendar.token = "synthetic-test-token";
  calendar.expiry = Date.now() + 60000;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url, "https://www.googleapis.com/calendar/v3/freeBusy");
    assert.equal(options.headers.Authorization, "Bearer synthetic-test-token");
    return {
      ok: true,
      json: async () => ({
        calendars: {
          primary: {
            busy: [
              { start: "2026-11-10T18:00:00Z", end: "2026-11-10T19:00:00Z" },
            ],
            summary: "Private event title",
          },
        },
      }),
    };
  };
  try {
    const availability = await calendar.availability();
    assert.deepEqual(Object.keys(availability).sort(), [
      "busy",
      "time_max",
      "time_min",
    ]);
    assert.equal(
      JSON.stringify(availability).includes("synthetic-test-token"),
      false,
    );
    assert.equal(
      JSON.stringify(availability).includes("Private event title"),
      false,
    );
    calendar.disconnect();
    assert.equal(calendar.token, null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
