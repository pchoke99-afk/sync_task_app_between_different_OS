import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.dirname(fileURLToPath(import.meta.url));
const dest = path.join(root, "dist");
await rm(dest, { recursive: true, force: true });
await mkdir(dest, { recursive: true });
for (const name of [
  "styles.css",
  "apple-touch-icon.png",
  "icon.svg",
  "icon-192.png",
  "icon-512.png",
  "manifest.webmanifest",
  "src",
]) {
  await cp(path.join(root, name), path.join(dest, name), { recursive: true });
}
// iOS 27.2's Home Screen sheet can fail to fetch an otherwise valid icon URL.
// Keep the PNG as the source of truth and embed it for that separate loader.
const icon = await readFile(path.join(root, "apple-touch-icon.png"));
const html = await readFile(path.join(root, "index.html"), "utf8");
const iconHref = 'href="/apple-touch-icon.png"';
if (!html.includes(iconHref)) {
  throw new Error("The Apple Home Screen icon link is missing.");
}
await writeFile(
  path.join(dest, "index.html"),
  html.replace(
    iconHref,
    `href="data:image/png;base64,${icon.toString("base64")}"`,
  ),
);
await mkdir(path.join(dest, "vendor/core"), { recursive: true });
await mkdir(path.join(dest, "vendor/lang"), { recursive: true });
for (const name of ["tesseract.min.js", "worker.min.js"]) {
  await cp(
    path.join(root, "node_modules/tesseract.js/dist", name),
    path.join(dest, "vendor", name),
  );
}
for (const name of await readdir(
  path.join(root, "node_modules/tesseract.js-core"),
)) {
  if (name.endsWith("-lstm.wasm") || name.endsWith("-lstm.wasm.js")) {
    await cp(
      path.join(root, "node_modules/tesseract.js-core", name),
      path.join(dest, "vendor/core", name),
    );
  }
}
await cp(
  path.join(
    root,
    "node_modules/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz",
  ),
  path.join(dest, "vendor/lang/eng.traineddata.gz"),
);
for (const [source, target] of [
  ["tesseract.js/LICENSE.md", "TESSERACT-LICENSE"],
  ["tesseract.js-core/LICENSE", "TESSERACT-CORE-LICENSE"],
  ["@tesseract.js-data/eng/README.md", "ENGLISH-DATA-README"],
]) {
  await cp(
    path.join(root, "node_modules", source),
    path.join(dest, "vendor", target),
  );
}
const hash = createHash("sha256");
async function hashDirectory(directory) {
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort(
    (a, b) => a.name.localeCompare(b.name),
  )) {
    const file = path.join(directory, entry.name);
    hash.update(path.relative(dest, file));
    if (entry.isDirectory()) await hashDirectory(file);
    else hash.update(await readFile(file));
  }
}
await hashDirectory(dest);
const worker = (await readFile(path.join(root, "sw.js"), "utf8")).replace(
  "__BUILD_ID__",
  hash.digest("hex").slice(0, 16),
);
await writeFile(path.join(dest, "sw.js"), worker);
console.log(
  "Built web/dist with locally hosted OCR. No credentials are bundled.",
);
