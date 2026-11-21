import { pathToFileURL } from "node:url";
import { readFile, rm, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
const [entry, file, method] = process.argv.slice(2);
const api = await import(pathToFileURL(entry));
const outputDirectory = await mkdtemp(join(tmpdir(), "poach-bench-"));
try {
  const result = await api[method ?? "inspectVideo"](file, { outputDirectory });
  const images = [];
  for (const frame of result.keyframes) {
    images.push((await readFile(frame.imagePath)).toString("base64"));
    frame.imagePath = basename(frame.imagePath);
  }
  result.sourcePath = basename(result.sourcePath);
  console.log(JSON.stringify({ result, images }));
} finally { await rm(outputDirectory, { recursive: true, force: true }); }
