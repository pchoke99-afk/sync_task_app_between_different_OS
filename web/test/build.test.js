import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";

test("The installable page embeds the exact Home Screen PNG without a separate fetch", async () => {
  const root = new URL("../", import.meta.url);
  execFileSync(process.execPath, ["build.mjs"], { cwd: root });
  const html = await readFile(new URL("dist/index.html", root), "utf8");
  const appleLink = html.match(/<link\s+rel="apple-touch-icon"[^>]*>/);
  assert.ok(appleLink, "Built page declares its Apple Home Screen icon");
  const encoded = appleLink[0].match(/href="data:image\/png;base64,([^"]+)"/);
  assert.ok(encoded, "Home Screen icon is embedded for iOS 27.2");
  const image = await readFile(new URL("apple-touch-icon.png", root));
  assert.deepEqual(Buffer.from(encoded[1], "base64"), image);
  assert.equal(image.readUInt32BE(16), 180);
  assert.equal(image.readUInt32BE(20), 180);
});
