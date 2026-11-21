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

async function makeVideoFixture(videoPath, rgb, afterRGB) {
  const width = 96;
  const height = 64;
  const headerSize = 54;
  const pixels = Buffer.alloc(headerSize + width * height * 3);
  pixels.write("BM");
  pixels.writeUInt32LE(pixels.length, 2);
  pixels.writeUInt32LE(headerSize, 10);
  pixels.writeUInt32LE(40, 14);
  pixels.writeInt32LE(width, 18);
  pixels.writeInt32LE(height, 22);
  pixels.writeUInt16LE(1, 26);
  pixels.writeUInt16LE(24, 28);
  if (afterRGB) {
    for (let frame = 0; frame < 10; frame++) {
      pixels.fill(Buffer.from([...(frame < 8 ? rgb : afterRGB)].reverse()), headerSize);
      await writeFile(`${videoPath}-${frame}.bmp`, pixels);
    }
    await exec("ffmpeg", ["-v", "error", "-framerate", "5", "-i", `${videoPath}-%d.bmp`, "-c:v", "mpeg4", "-pix_fmt", "yuv420p", videoPath]);
    return;
  }
  pixels.fill(Buffer.from([...rgb].reverse()), headerSize);
  const imagePath = `${videoPath}.bmp`;
  await writeFile(imagePath, pixels);
  await exec("ffmpeg", ["-v", "error", "-loop", "1", "-i", imagePath, "-t", "2", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", videoPath]);
}

test("shared brief carries notes and visual moments through MCP", { timeout: 30_000 }, async (t) => {
  const home = await mkdtemp(join(tmpdir(), "poach-handoff-test-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const cache = join(home, "Library/Caches/Poach");
  await mkdir(cache, { recursive: true });
  const video = join(home, "demo.mp4");
  const png = join(home, "reference.png");
  await makeVideoFixture(video, [0, 128, 128], [255, 0, 0]);
  await exec("ffmpeg", ["-v", "error", "-i", video, "-frames:v", "1", "-c:v", "png", "-f", "image2pipe", png]);
  const brief = { version: 1, briefId: "df5ff2b4-663c-41ec-8de2-5c90e837bd82", sharedAt: Date.now() / 1000, context: "[1.00s] Expand on hover. Replace #000000 with #008080.", instruction: "Recreate the interaction", evidence: { mediaType: "video", sourcePath: video, keyframes: [{ imagePath: png, kind: "start", timeMs: 0 }], annotations: [{ timeMs: 1000, text: "The heart fills on click." }], pointerTrace: { available: true, coordinateSpace: "normalized-capture-bounds", origin: "top-left", boundsWidth: 800, boundsHeight: 600, sampleIntervalMs: 1000 / 120, sampleCount: 132, insideSampleCount: 110, buttonSampleCount: 12, scrollCaptured: false, truncated: false, events: [ { timeMs: 900, kind: "down", x: 0.5, y: 0.5, button: "left", withinCapture: true }, { timeMs: 980, kind: "up", x: 0.5, y: 0.5, button: "left", withinCapture: true }, { timeMs: 1200, kind: "down", x: 0.1, y: 0.2, button: "left", withinCapture: true }, { timeMs: 1250, kind: "drag", x: 0.4, y: 0.5, button: "left", withinCapture: true }, { timeMs: 1400, kind: "up", x: 0.8, y: 0.8, button: "left", withinCapture: true } ] } } };
  brief.evidence.pointerTrace.events.push(
    { timeMs: 1700, kind: "down", x: 0.998, y: 0.5, button: "left", withinCapture: true },
    { timeMs: 1800, kind: "up", x: 1, y: 0.5, button: "left", withinCapture: false },
    { timeMs: 1800, kind: "down", x: 0.998, y: 0.5, button: "left", withinCapture: true },
    { timeMs: 1900, kind: "drag", x: 1, y: 0.5, button: "left", withinCapture: false },
    { timeMs: 2000, kind: "up", x: 1, y: 0.5, button: "left", withinCapture: false },
  );
  brief.evidence.browserEvidence = {
    videoOffsetMs: -100,
    events: [{ atMs: 1075, type: "drop", target: { tag: "div" } }],
    states: [{
      atMs: 1250,
      text: "Uploaded",
      styles: {
        fontFamily: '"Fixture Sans", sans-serif',
        fontSize: "24px",
        fontWeight: "650",
        fontStyle: "italic",
        lineHeight: "30px",
        letterSpacing: "-0.5px",
        opacity: "1",
      },
    }, { atMs: 1900, text: "Too big" }],
  };
  const path = join(cache, "active-brief.json");
  await writeFile(path, JSON.stringify(brief));
  const client = new Client({ name: "poach-handoff-test", version: "1.0.0" });
  const transport = new StdioClientTransport({ command: process.execPath, args: [process.env.POACH_TEST_SERVER ?? new URL("../dist/index.js", import.meta.url).pathname], env: { ...process.env, HOME: home }, stderr: "pipe" });
  await client.connect(transport);
  t.after(() => client.close());
  const shared = await client.callTool({ name: "poach_read_brief", arguments: {} });
  assert.ok(!shared.isError);
  assert.equal(shared.structuredContent.context, brief.context);
  assert.deepEqual(shared.structuredContent.evidence.browserEvidence, brief.evidence.browserEvidence);
  const sharedImages = shared.content.filter(item => item.type === "image");
  assert.equal(sharedImages.length, 4);
  assert.ok(shared.content.some(item => item.type === "text" && item.text.startsWith("After drag release: 1699 ms")));
  assert.notEqual(sharedImages[1].data, sharedImages.at(-1).data, "the tail frame shows the post-release color change");
  const twoDrops = structuredClone(brief);
  twoDrops.evidence.pointerTrace.events.unshift(
    { timeMs: 100, kind: "down", x: 0.1, y: 0.1, button: "left", withinCapture: true },
    { timeMs: 200, kind: "drag", x: 0.3, y: 0.3, button: "left", withinCapture: true },
    { timeMs: 300, kind: "up", x: 0.4, y: 0.4, button: "left", withinCapture: true },
  );
  await writeFile(path, JSON.stringify(twoDrops));
  const multiple = await client.callTool({ name: "poach_read_brief", arguments: { briefId: brief.briefId } });
  const releaseEvidence = multiple.content.filter(item => item.type === "text").map(item => item.text);
  assert.ok(!multiple.isError);
  assert.ok(releaseEvidence.some(text => text.startsWith("Drag release candidate at 300 ms")));
  assert.ok(releaseEvidence.some(text => text.startsWith("After drag release: 1199 ms")));
  assert.ok(releaseEvidence.some(text => text.startsWith("Drag release candidate at 1400 ms")));
  assert.ok(releaseEvidence.some(text => text.startsWith("After drag release: 1699 ms")));
  await writeFile(path, JSON.stringify(brief));
  const cropped = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 0, crop: { x: 0, y: 0, width: 32, height: 24 }, maxSize: 1280 } });
  assert.ok(!cropped.isError);
  assert.ok(cropped.content.some(item => item.type === "text" && item.text.includes("Image 32×24 pixels")));
  const invalidCrop = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 0, crop: { x: 0, y: 0, width: 9999, height: 24 } } });
  assert.ok(invalidCrop.isError);
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
  assert.equal(actions[2].timeMs, 1700);
  assert.equal(actions[3].durationMs, 200);
  const moment = await client.callTool({ name: "poach_read_moment", arguments: { timeMs: 1000 } });
  assert.ok(!moment.isError);
  assert.equal(moment.content.filter(item => item.type === "image").length, 1);
  assert.match(moment.content.find(item => item.type === "text").text, /The heart fills on click/);
  const momentText = moment.content.find(item => item.type === "text").text;
  assert.match(momentText, /"type":"drop".*"estimatedVideoMs":975/);
  assert.match(momentText, /"text":"Uploaded".*"estimatedVideoMs":1150/);
  const browserLine = momentText.split("\n").find(line => line.startsWith("Nearby Chrome evidence"));
  const [, upload] = JSON.parse(browserLine.slice(browserLine.indexOf("): ") + 3));
  const { opacity, ...typography } = brief.evidence.browserEvidence.states[0].styles;
  assert.deepEqual(upload.styles, typography);
  assert.doesNotMatch(momentText, /Too big/);
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
  assert.match(expired.content[0].text, /expired/);
  await access(path);
});

test("archived briefs remain readable by ID after a newer brief is shared", { timeout: 30_000 }, async (t) => {
  const home = await mkdtemp(join(tmpdir(), "poach-brief-archive-test-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const cache = join(home, "Library/Caches/Poach");
  const archive = join(cache, "briefs");
  await mkdir(archive, { recursive: true });
  const olderVideo = join(home, "older.mp4");
  const latestVideo = join(home, "latest.mp4");
  await makeVideoFixture(olderVideo, [255, 0, 0]);
  await makeVideoFixture(latestVideo, [0, 0, 255]);

  const older = {
    version: 1,
    briefId: "a2e9bf72-26b9-4a9d-888a-fc47ad798813",
    sharedAt: Date.now() / 1000,
    context: "First prompt: make the PNG badge red.",
    instruction: "Recreate the recorded interaction.",
    evidence: { mediaType: "video", sourcePath: olderVideo, keyframes: [], annotations: [] },
  };
  const latest = {
    ...older,
    briefId: "b7f24322-2d3c-42e9-8d72-4d5d7ef96441",
    context: "Second prompt: make the dropzone compact.",
    evidence: { ...older.evidence, sourcePath: latestVideo },
  };
  await writeFile(join(archive, `${older.briefId}.json`), JSON.stringify(older));
  await writeFile(join(cache, "active-brief.json"), JSON.stringify(latest));

  const client = new Client({ name: "poach-brief-archive-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [process.env.POACH_TEST_SERVER ?? new URL("../dist/index.js", import.meta.url).pathname],
    env: { ...process.env, HOME: home },
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(() => client.close());

  const firstPrompt = await client.callTool({ name: "poach_read_brief", arguments: { briefId: older.briefId, includeKeyframes: false } });
  assert.ok(!firstPrompt.isError);
  assert.equal(firstPrompt.structuredContent.briefId, older.briefId);
  assert.equal(firstPrompt.structuredContent.context, older.context);

  const mostRecent = await client.callTool({ name: "poach_read_brief", arguments: { includeKeyframes: false } });
  assert.ok(!mostRecent.isError);
  assert.equal(mostRecent.structuredContent.briefId, latest.briefId);
  assert.equal(mostRecent.structuredContent.context, latest.context);

  const olderMoment = await client.callTool({ name: "poach_read_moment", arguments: { briefId: older.briefId, timeMs: 500 } });
  const latestMoment = await client.callTool({ name: "poach_read_moment", arguments: { briefId: latest.briefId, timeMs: 500 } });
  assert.ok(!olderMoment.isError);
  assert.ok(!latestMoment.isError);
  const olderFrame = olderMoment.content.find(item => item.type === "image");
  const latestFrame = latestMoment.content.find(item => item.type === "image");
  assert.ok(olderFrame);
  assert.ok(latestFrame);
  assert.notEqual(olderFrame.data, latestFrame.data, "each brief ID should read its own recording");

  const preset = {
    ...latest,
    briefId: "c87701b6-62ae-44be-bd74-34604931a854",
    evidence: {
      ...latest.evidence,
      sourcePath: "",
      keyframes: [{ kind: "peak", timeMs: 500, imagePath: join(home, "preset.png") }],
      annotations: [{ timeMs: 500, text: "The badge expands here." }],
      visualFontMatch: {
        family: "Georgia", face: "Bold Italic", postScriptName: "Georgia-BoldItalic",
        region: { x: 0.1, y: 0.2, width: 0.5, height: 0.1 },
      },
    },
  };
  await writeFile(preset.evidence.keyframes[0].imagePath, Buffer.from(latestFrame.data, "base64"));
  await writeFile(join(archive, `${preset.briefId}.json`), JSON.stringify(preset));
  const saved = await client.callTool({ name: "poach_read_brief", arguments: { briefId: preset.briefId } });
  assert.ok(!saved.isError);
  assert.equal(saved.structuredContent.briefId, preset.briefId);
  assert.deepEqual(saved.structuredContent.evidence.visualFontMatch, preset.evidence.visualFontMatch);
  assert.deepEqual(saved.structuredContent.evidence.annotations, preset.evidence.annotations);
  assert.equal(saved.content.find(item => item.type === "image")?.data, latestFrame.data);
  const savedMoment = await client.callTool({ name: "poach_read_moment", arguments: { briefId: preset.briefId, timeMs: 500 } });
  assert.equal(savedMoment.isError, true);
  assert.match(savedMoment.content[0].text, /Use poach_read_brief to see its saved frames/);

  const olderPath = join(archive, `${older.briefId}.json`);
  await writeFile(olderPath, JSON.stringify({ ...older, sharedAt: older.sharedAt - 86401 }));
  const expired = await client.callTool({ name: "poach_read_brief", arguments: { briefId: older.briefId } });
  assert.equal(expired.isError, true);
  assert.match(expired.content[0].text, /expired/);
  await assert.rejects(access(olderPath), { code: "ENOENT" });
  await access(join(cache, "active-brief.json"));
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
