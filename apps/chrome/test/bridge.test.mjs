import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

test("oversized evidence drops only the optional end snapshot, then fails clearly", async () => {
  let body;
  const context = vm.createContext({ Blob, AbortSignal, Map, Promise, chrome: { storage: { local: { get: async () => ({ pairingCode: "test" }) } }, runtime: { onMessage: { addListener() {} } } }, fetch: async (_url, options) => { body = options.body; return { ok: true }; } });
  const source = await readFile(new URL("../bridge.js", import.meta.url), "utf8");
  vm.runInContext(source + "\nglobalThis.testHandle = handle;", context);
  const evidence = { components: [{ text: "start" }], componentsAtEnd: [{ text: "x".repeat(256 * 1024) }] };
  const sent = await context.testHandle({ poachBridge: "capture", evidence, final: true });
  assert.equal(sent.ok, true);
  assert.deepEqual(JSON.parse(body), { components: [{ text: "start" }] });
  assert.ok(evidence.componentsAtEnd, "do not mutate the source snapshot");
  body = undefined;
  const rejected = await context.testHandle({ poachBridge: "capture", evidence: { components: [{ text: "x".repeat(256 * 1024) }] }, final: true });
  assert.match(rejected.error, /evidence limit/);
  assert.equal(body, undefined);
});
