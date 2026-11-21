import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { inspectRecording, inspectVideo, readVideoMoment } from "../dist/index.js";

const exec = promisify(execFile);

test("native recorder overrun is clipped while imported videos stay bounded", { timeout: 120_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "poach-boundary-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, "overrun.mov");
  await exec("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=30",
    "-t", "31.5", "-c:v", "libx264", "-pix_fmt", "yuv420p", source]);
  await assert.rejects(inspectVideo(source), /30-second limit/);
  const result = await inspectRecording(source);
  assert.notEqual(result.sourcePath, source);
  t.after(() => rm(dirname(result.sourcePath), { recursive: true, force: true }));
  for (const folder of new Set(result.keyframes.map(frame => dirname(frame.imagePath)))) {
    t.after(() => rm(folder, { recursive: true, force: true }));
  }
  const { stdout } = await exec("ffprobe", ["-v", "error", "-show_entries", "format=duration",
    "-of", "default=nw=1:nk=1", result.sourcePath]);
  assert.equal(Number(stdout), 30);
  assert.ok(result.keyframes.length > 0);
  const frame = await readVideoMoment(result.sourcePath, 29_900);
  assert.deepEqual([...frame.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  await assert.rejects(readVideoMoment(result.sourcePath, 30_000));
});

test("moments between sparse frames show the frame held on screen", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "poach-sparse-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, "sparse.mov");
  await exec("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=1/2",
    "-frames:v", "3", "-c:v", "libx264", source]);
  const first = await readVideoMoment(source, 0);
  assert.deepEqual(await readVideoMoment(source, 1999), first);
  assert.notDeepEqual(await readVideoMoment(source, 2000), first);
  assert.deepEqual(await readVideoMoment(source, 5999), await readVideoMoment(source, 4000));
});

test("a stationary capture reports no estimated easing", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "poach-static-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, "rest.mov");
  await exec("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=black:size=96x64:rate=12",
    "-t", "1", "-c:v", "libx264", source]);
  const result = await inspectVideo(source, { outputDirectory: directory });
  assert.deepEqual(result.keyframes.map(frame => frame.kind), ["start"]);
  assert.equal(result.timing.durationMs, 0);
  assert.equal(result.timing.bezier, null);
});

// Exercise the streaming boundary with a fake decoder; ffprobe still reads a real clip.
test("batched samples reject truncated output and decoder failures", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "poach-stream-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = join(directory, "source.mov");
  await exec("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=black:size=96x64:rate=12", "-t", "1", "-c:v", "libx264", source]);
  const previous = process.env.PATH;
  try {
    const decoder = join(directory, "ffmpeg");
    await writeFile(decoder, "#!/bin/sh\nprintf 'P7\\nWIDTH 96\\nHEIGHT 64\\nDEPTH 3\\nMAXVAL 255\\nTUPLTYPE RGB\\nENDHDR\\n'\n");
    await chmod(decoder, 0o700);
    process.env.PATH = directory + ":" + previous;
    await assert.rejects(inspectVideo(source), /Truncated/);
    await writeFile(decoder, "#!/bin/sh\necho decoder-failed >&2\nexit 7\n");
    await assert.rejects(inspectVideo(source), /code 7: decoder-failed/);
    await writeFile(decoder, "#!/bin/sh\nprintf 'P7\\nWIDTH 999999\\nHEIGHT 64\\nDEPTH 3\\nMAXVAL 255\\nENDHDR\\n'\n");
    await assert.rejects(inspectVideo(source), /Invalid PAM/);
  } finally { process.env.PATH = previous; }
});
