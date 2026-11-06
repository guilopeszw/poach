import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm, access, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const exec = promisify(execFile);
test("shared brief carries notes and visual moments through MCP", { timeout: 30_000 }, async (t) => {
  const home = await mkdtemp(join(tmpdir(), "poach-handoff-test-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const cache = join(home, "Library/Caches/Poach");
  await mkdir(cache, { recursive: true });
  const video = join(home, "demo.mp4");
  const png = join(home, "reference.png");
  await exec("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=30", "-t", "2", "-c:v", "libx264", video]);
  await exec("ffmpeg", ["-v", "error", "-i", video, "-frames:v", "1", png]);
  const brief = { version: 1, briefId: "df5ff2b4-663c-41ec-8de2-5c90e837bd82", sharedAt: Date.now() / 1000, context: "[1.00s] Expand on hover. Replace #000000 with #008080.", instruction: "Recreate the interaction", evidence: { mediaType: "video", sourcePath: video, keyframes: [{ imagePath: png, kind: "start", timeMs: 0 }], annotations: [{ timeMs: 1000, text: "The heart fills on click." }], pointerTrace: { available: true, coordinateSpace: "normalized-capture-bounds", origin: "top-left", boundsWidth: 800, boundsHeight: 600, sampleIntervalMs: 1000 / 120, sampleCount: 132, insideSampleCount: 110, buttonSampleCount: 12, scrollCaptured: false, truncated: false, events: [ { timeMs: 900, kind: "down", x: 0.5, y: 0.5, button: "left", withinCapture: true }, { timeMs: 980, kind: "up", x: 0.5, y: 0.5, button: "left", withinCapture: true }, { timeMs: 1200, kind: "down", x: 0.1, y: 0.2, button: "left", withinCapture: true }, { timeMs: 1250, kind: "drag", x: 0.4, y: 0.5, button: "left", withinCapture: true }, { timeMs: 1400, kind: "up", x: 0.8, y: 0.8, button: "left", withinCapture: true } ] } } };
  brief.evidence.pointerTrace.events.push(
    { timeMs: 1500, kind: "down", x: 0.998, y: 0.5, button: "left", withinCapture: true },
    { timeMs: 1600, kind: "up", x: 1, y: 0.5, button: "left", withinCapture: false },
    { timeMs: 1800, kind: "down", x: 0.998, y: 0.5, button: "left", withinCapture: true },
    { timeMs: 1900, kind: "drag", x: 1, y: 0.5, button: "left", withinCapture: false },
    { timeMs: 2000, kind: "up", x: 1, y: 0.5, button: "left", withinCapture: false },
  );
  const path = join(cache, "active-brief.json");
  await writeFile(path, JSON.stringify(brief));
  const client = new Client({ name: "poach-handoff-test", version: "1.0.0" });
  const transport = new StdioClientTransport({ command: process.execPath, args: [process.env.POACH_TEST_SERVER ?? new URL("../dist/index.js", import.meta.url).pathname], env: { ...process.env, HOME: home }, stderr: "pipe" });
  await client.connect(transport);
  t.after(() => client.close());
  const shared = await client.callTool({ name: "poach_read_brief", arguments: {} });
  assert.ok(!shared.isError);
  assert.equal(shared.structuredContent.context, brief.context);
  assert.equal(shared.content.filter(item => item.type === "image").length, 1);
  const actions = shared.structuredContent.evidence.interactionActions.actions;
  assert.deepEqual(actions.map(action => action.kind), ["click", "drag", "drag", "drag"]);
  assert.equal(shared.structuredContent.evidence.interactionActions.samplingBased, true);
  assert.equal(actions[2].durationMs, 100);
  assert.equal(shared.structuredContent.evidence.pointerTrace.sampleIntervalMs, 1000 / 120);
  assert.equal(shared.structuredContent.evidence.pointerTrace.sampleCount, 132);
  assert.equal(shared.structuredContent.evidence.pointerTrace.insideSampleCount, 110);
  assert.equal(shared.structuredContent.evidence.pointerTrace.buttonSampleCount, 12);
  assert.equal(actions[0].timeMs, 900);
  assert.equal(actions[1].durationMs, 200);
  assert.equal(actions[2].kind, "drag");
  assert.equal(actions[2].timeMs, 1500);
  assert.equal(actions[3].durationMs, 200);
  const moment = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 1000 } });
  assert.ok(!moment.isError);
  assert.equal(moment.content.filter(item => item.type === "image").length, 1);
  assert.match(moment.content.find(item => item.type === "text").text, /The heart fills on click/);
  assert.match(moment.content.find(item => item.type === "text").text, /sample-derived click\/drag candidates/);
  assert.match(moment.content.find(item => item.type === "text").text, /Pointer trace summary: 132 samples, 110 inside the capture, 12 with a button held, 10 recorded pointer events, and 4 summarized clicks or drags\./);
  for (const name of ["poach_read_brief", "poach_read_moment"]) {
    const args = name === "poach_read_moment" ? { timeMs: 500 } : {};
    const matching = await client.callTool({ name, arguments: { ...args, briefId: brief.briefId } });
    assert.ok(!matching.isError);
    const stale = await client.callTool({ name, arguments: { ...args, briefId: "827fb563-c2a2-4bf6-91a1-846528d715e9" } });
    assert.equal(stale.isError, true);
    assert.match(stale.content[0].text, /replaced/);
  }
  const outside = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 30000 } });
  assert.equal(outside.isError, true);
  const noActions = {
    ...brief,
    evidence: {
      ...brief.evidence,
      pointerTrace: { ...brief.evidence.pointerTrace, sampleCount: 44, insideSampleCount: 40, buttonSampleCount: 0, events: [] },
    },
  };
  await writeFile(path, JSON.stringify(noActions));
  const emptyTraceMoment = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 1000 } });
  assert.ok(!emptyTraceMoment.isError);
  assert.match(emptyTraceMoment.content.find(item => item.type === "text").text, /Pointer trace summary: 44 samples, 40 inside the capture, 0 with a button held, 0 recorded pointer events, and 0 summarized clicks or drags\./);
  const unavailableTrace = {
    ...brief,
    evidence: {
      ...brief.evidence,
      pointerTrace: { ...brief.evidence.pointerTrace, available: false, sampleCount: 0, insideSampleCount: 0, buttonSampleCount: 0, events: [] },
    },
  };
  await writeFile(path, JSON.stringify(unavailableTrace));
  const unavailableMoment = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 1000 } });
  assert.ok(!unavailableMoment.isError);
  const unavailableText = unavailableMoment.content.find(item => item.type === "text").text;
  assert.match(unavailableText, /No native pointer trace was included/);
  assert.doesNotMatch(unavailableText, /Pointer trace summary:/);
  const truncatedTrace = {
    ...brief,
    evidence: {
      ...brief.evidence,
      pointerTrace: {
        ...brief.evidence.pointerTrace,
        truncated: true,
        events: [{ timeMs: 990, kind: "down", x: 0.5, y: 0.5, button: "left", withinCapture: true }],
      },
    },
  };
  await writeFile(path, JSON.stringify(truncatedTrace));
  const truncatedMoment = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 1000 } });
  assert.ok(!truncatedMoment.isError);
  const truncatedText = truncatedMoment.content.find(item => item.type === "text").text;
  assert.match(truncatedText, /Trace reached its event limit; later actions may be incomplete/);
  assert.match(truncatedText, /Incomplete button-down without a matching release/);
  await writeFile(path, JSON.stringify({ ...brief, sharedAt: brief.sharedAt - 86401 }));
  const expired = await client.callTool({ name: "poach_read_brief", arguments: {} });
  assert.equal(expired.isError, true);
  await assert.rejects(access(path));
});

test("connection status follows initialized clients independently", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "poach-connection-test-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const directory = join(home, "Library/Caches/Poach/connections");
  const transport = () => new StdioClientTransport({
    command: process.execPath,
    args: [process.env.POACH_TEST_SERVER ?? new URL("../dist/index.js", import.meta.url).pathname],
    env: { ...process.env, HOME: home },
    stderr: "pipe",
  });
  async function expectActive(count) {
    for (let attempt = 0; attempt < 100; attempt++) {
      const files = await readdir(directory).catch(error => {
        if (error.code === "ENOENT") return [];
        throw error;
      });
      if (files.length === count) return;
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    assert.fail(`Expected ${count} active MCP sessions`);
  }
  const uninitialized = transport();
  await uninitialized.start();
  await expectActive(0);
  await uninitialized.close();
  const a = new Client({ name: "first", version: "1" });
  const b = new Client({ name: "second", version: "1" });
  try {
    await a.connect(transport());
    await b.connect(transport());
    await expectActive(2);
    await a.close();
    await expectActive(1);
    await b.close();
    await expectActive(0);
  } finally {
    await a.close();
    await b.close();
  }
});
