// Stage what an installed Poach needs beside its binary (see
// src-tauri/tauri.bundle.conf.json): the analysis engine, a self-contained
// MCP connector and the GNOME extension. Run after building @poach/core and
// @poach/mcp-server (the app:build hook does both).
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { access, cp, mkdir, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const app = fileURLToPath(new URL("../", import.meta.url));
const root = join(app, "../..");
const out = join(app, "src-tauri/resources");

for (const entry of ["packages/core/dist/index.js", "packages/mcp-server/dist/index.js"]) {
  try {
    await access(join(root, entry));
  } catch {
    console.error(`Missing ${entry}. Build the workspace first: pnpm -w exec turbo run build --filter=@poach/mcp-server`);
    process.exit(1);
  }
}

await rm(out, { recursive: true, force: true });

// @poach/core has no runtime dependencies, so its build output runs as is.
await cp(join(root, "packages/core/dist"), join(out, "core"), {
  recursive: true,
  filter: (source) => !/\.(d\.ts|map)$/.test(source),
});
// Mark the copy as ESM: Node 22 detects it, but Node 18 (Debian 12) would
// otherwise load it as CommonJS and find none of its exports.
await writeFile(join(out, "core/package.json"), `${JSON.stringify({ type: "module" })}\n`);

// Same bundling as scripts/build-connectors.mjs for the macOS connector.
await build({
  entryPoints: [join(root, "packages/mcp-server/dist/index.js")],
  outfile: join(out, "mcp/server.mjs"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  banner: { js: "import {createRequire} from 'node:module'; const require=createRequire(import.meta.url);" },
});

const extension = join(out, "gnome-extension");
await mkdir(extension, { recursive: true });
for (const entry of ["metadata.json", "extension.js", "schemas", "icons"]) {
  await cp(join(app, "gnome-extension", entry), join(extension, entry), { recursive: true });
}
execFileSync("glib-compile-schemas", [join(extension, "schemas")]);

console.log(`Staged Poach resources in ${out}`);
