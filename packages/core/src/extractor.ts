import { spawn } from "node:child_process";
import { mkdtemp, mkdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import { extractPalette } from "./palette.js";
import { approximateTiming, pixelDifference } from "./motion.js";
import type { ExtractOptions, FrameSample, InspectionResult, Keyframe } from "./types.js";

const MAX_VIDEO_BYTES = 512 * 1024 * 1024;
const MAX_DURATION_SECONDS = 30;
const DEFAULT_SAMPLE_WIDTH = 96;
const DEFAULT_SAMPLES_PER_SECOND = 12;

async function run(command: string, args: readonly string[]): Promise<Buffer> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, [...args], { stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let outputBytes = 0;
    child.stdout.on("data", (chunk: Buffer) => {
      outputBytes += chunk.length;
      // Bound output even if a malformed file causes FFmpeg to emit too much.
      if (outputBytes > 64 * 1024 * 1024) {
        child.kill("SIGKILL");
        reject(new Error(`${command} output exceeded the 64 MiB safety limit`));
        return;
      }
      stdout.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", (error) => reject(new Error(`Could not start ${command}: ${error.message}`)));
    child.on("close", (code) => {
      if (code === 0) resolvePromise(Buffer.concat(stdout));
      else reject(new Error(`${command} exited with code ${code}: ${Buffer.concat(stderr).toString("utf8").slice(-2_000)}`));
    });
  });
}

function parseDuration(output: Buffer): number {
  const data = JSON.parse(output.toString("utf8")) as { format?: { duration?: string } };
  const duration = Number(data.format?.duration);
  if (!Number.isFinite(duration) || duration <= 0) throw new Error("Video has no valid duration");
  if (duration > MAX_DURATION_SECONDS) throw new Error(`Video is longer than the ${MAX_DURATION_SECONDS}-second limit`);
  return duration;
}

/** Normalize recorder shutdown latency without relaxing the imported-video limit. */
export async function inspectRecording(videoFile: string, options: ExtractOptions = {}): Promise<InspectionResult> {
  const sourcePath = resolve(videoFile);
  if (![".mov", ".mp4"].includes(extname(sourcePath).toLowerCase())) {
    throw new Error("Recording must be an MP4 or MOV file");
  }
  const file = await stat(sourcePath);
  if (!file.isFile() || file.size > MAX_VIDEO_BYTES) throw new Error("Recording exceeds the 512 MiB limit");
  const probe = await run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "json", sourcePath]);
  const metadata = JSON.parse(probe.toString("utf8")) as { format?: { duration?: string } };
  const duration = Number(metadata.format?.duration);
  if (!Number.isFinite(duration) || duration <= 0) throw new Error("Recording has no valid duration");
  if (duration <= MAX_DURATION_SECONDS) return inspectVideo(sourcePath, options);

  const directory = await mkdtemp(join(tmpdir(), "poach-recording-"));
  const clippedPath = join(directory, "recording.mp4");
  // Re-encode the boundary: stream copy may retain packets beyond 30 seconds.
  await run("ffmpeg", [
    "-v", "error", "-i", sourcePath, "-map", "0:v:0", "-an",
    "-t", String(MAX_DURATION_SECONDS), "-vf", "fps=30",
    "-c:v", "mpeg4", "-q:v", "2", clippedPath,
  ]);
  return inspectVideo(clippedPath, options);
}

// ScreenCaptureKit may store one frame for several seconds of unchanged pixels.
// Resolve the frame already on screen, then seek between its PTS and its predecessor.
interface VideoTimeline {
  /** Preserve the original first-video-stream sampling grid. */
  seekTimes: number[];
  /** Actual presentation frames of the stream FFmpeg will decode. */
  decodeTimes: number[];
  streamIndex: number;
}

async function selectedVideoStream(sourcePath: string): Promise<number> {
  // Let the installed FFmpeg apply its own default/resolution/attached-picture rules.
  // This zero-frame initialization is only needed for files with multiple video streams.
  return new Promise((resolvePromise, reject) => {
    const child = spawn("ffmpeg", ["-hide_banner", "-loglevel", "info", "-i", sourcePath,
      "-an", "-sn", "-dn", "-frames:v", "0", "-vcodec", "pam", "-f", "image2pipe", "pipe:1"],
      { stdio: ["ignore", "ignore", "pipe"] });
    let diagnostics = "";
    let pendingLine = "";
    let droppingLine = false;
    let mapping = false;
    let mappingComplete = false;
    let selected: number | undefined;
    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      diagnostics = (diagnostics + text).slice(-32_768);
      const lines = text.split("\n");
      for (const [index, part] of lines.entries()) {
        if (!droppingLine) pendingLine += part;
        if (pendingLine.length > 32_768) { pendingLine = ""; droppingLine = true; }
        if (index === lines.length - 1) continue;
        if (!droppingLine && !mappingComplete) {
          const line = pendingLine.trimEnd();
          if (line === "Stream mapping:") { mapping = true; selected = undefined; }
          else if (line.startsWith("Output #0,")) mappingComplete = true;
          else if (mapping) {
            const match = /^[ \t]+Stream #0:(\d+)[^\r\n]* -> #0:0\b/.exec(line);
            if (match) selected = Number(match[1]);
          }
        }
        pendingLine = "";
        droppingLine = false;
      }
    });
    child.on("error", reject);
    child.on("close", code => {
      if (code !== 0 || selected === undefined) reject(new Error(`Could not determine FFmpeg's selected video stream: ${diagnostics.slice(-2000)}`));
      else resolvePromise(selected);
    });
  });
}

async function presentationTimes(sourcePath: string): Promise<VideoTimeline> {
  const data = await run("ffprobe", ["-v", "error", "-select_streams", "v", "-show_packets",
    "-show_entries", "stream=index:format=start_time:packet=stream_index,pts_time", "-of", "json", sourcePath]);
  const probe = JSON.parse(data.toString("utf8")) as { streams?: { index: number }[]; format?: { start_time?: string }; packets?: { stream_index: number; pts_time?: string }[] };
  const firstIndex = probe.streams?.[0]?.index;
  if (firstIndex === undefined) throw new Error("Recording has no video stream");
  const streamIndex = probe.streams!.length > 1 ? await selectedVideoStream(sourcePath) : firstIndex;
  if (!probe.streams!.some(stream => stream.index === streamIndex)) throw new Error("FFmpeg selected an unavailable video stream");
  const start = Number(probe.format?.start_time) || 0;
  const timesFor = (index: number) => [...new Set((probe.packets ?? []).filter(packet => packet.stream_index === index)
    .map(packet => Number(packet.pts_time) - start).filter(Number.isFinite))].sort((a, b) => a - b);
  const seekTimes = timesFor(firstIndex);
  const decodeTimes = streamIndex === firstIndex ? seekTimes : timesFor(streamIndex);
  if (!seekTimes.length || !decodeTimes.length) throw new Error("Recording has no timestamped video frames");
  return { seekTimes, decodeTimes, streamIndex };
}

function seekForMoment(times: readonly number[], seconds: number): number {
  let low = 0;
  let high = times.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (times[middle]! <= seconds) low = middle + 1;
    else high = middle;
  }
  return low < 2 ? 0 : Math.max(0, (times[low - 1]! + times[low - 2]!) / 2);
}

// Decode only the distinct presentation frames selected by the existing seek rule.
// PAM carries dimensions with each RGB frame, including rotated and odd-sized media.
async function readFrames(videoPath: string, seeks: readonly number[], times: readonly number[], width: number, streamIndex: number): Promise<FrameSample[]> {
  const targets = [...new Set(seeks.map(seek => {
    const target = times.find(time => time >= Number(seek.toFixed(6)) - 0.0000005);
    if (target === undefined) throw new Error(`Could not decode frame at ${Math.round(seek * 1000)} ms`);
    return target;
  }))].sort((a, b) => a - b);
  const balanced = (terms: string[]): string => terms.length === 1 ? terms[0]! : `(${balanced(terms.slice(0, Math.floor(terms.length / 2)))}+${balanced(terms.slice(Math.floor(terms.length / 2)))})`;
  const select = balanced(targets.map(time => `between(t,${(time - 0.0000005).toFixed(7)},${(time + 0.0000005).toFixed(7)})`));
  const decoded = await decodeSamples(videoPath, select, width, targets.length, streamIndex);
  return seeks.map(seek => decoded[targets.indexOf(times.find(time => time >= Number(seek.toFixed(6)) - 0.0000005)!)]!);
}

async function decodeSamples(videoPath: string, select: string, width: number, count: number, streamIndex: number): Promise<FrameSample[]> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn("ffmpeg", ["-v", "error", "-copyts", "-start_at_zero", "-i", videoPath, "-map", `0:${streamIndex}`,
      "-vf", `select='${select}',scale=${width}:-2:flags=area`, "-fps_mode", "passthrough",
      "-frames:v", String(count), "-f", "image2pipe", "-vcodec", "pam", "-pix_fmt", "rgb24", "pipe:1"],
      { stdio: ["ignore", "pipe", "pipe"] });
    const frames: FrameSample[] = [];
    let pending = Buffer.alloc(0);
    let stderr = "";
    let failure: Error | undefined;
    const fail = (error: Error) => { failure ??= error; child.kill("SIGKILL"); };
    child.stderr.on("data", (chunk: Buffer) => { stderr = (stderr + chunk.toString("utf8")).slice(-2000); });
    child.stdout.on("data", (chunk: Buffer) => {
      if (failure) return;
      pending = Buffer.concat([pending, chunk]);
      try {
        while (pending.length) {
          const end = pending.indexOf("ENDHDR\n");
          if (end < 0) {
            if (pending.length > 1024) throw new Error("Invalid PAM frame header");
            break;
          }
          if (end > 1024) throw new Error("Invalid PAM frame header");
          const header = pending.subarray(0, end + 7).toString("ascii");
          const w = Number(/^WIDTH (\d+)$/m.exec(header)?.[1]);
          const h = Number(/^HEIGHT (\d+)$/m.exec(header)?.[1]);
          if (!header.startsWith("P7\n") || !/^DEPTH 3$/m.test(header) || !/^MAXVAL 255$/m.test(header)
              || w !== width || !Number.isSafeInteger(h) || h < 1 || w * h * 3 > 64 * 1024 * 1024) {
            throw new Error("Invalid PAM sample dimensions");
          }
          const length = w * h * 3;
          if (pending.length < end + 7 + length) break;
          frames.push({ timeMs: 0, width: w, height: h, channels: 3, pixels: Buffer.from(pending.subarray(end + 7, end + 7 + length)) });
          pending = pending.subarray(end + 7 + length);
          if (frames.length > count) throw new Error("Too many decoded samples");
        }
      } catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
    });
    child.on("error", error => { failure ??= new Error(`Could not start ffmpeg: ${error.message}`); });
    child.on("close", code => {
      if (failure) reject(failure);
      else if (code !== 0) reject(new Error(`ffmpeg exited with code ${code}: ${stderr}`));
      else if (pending.length || frames.length !== count) reject(new Error("Truncated ffmpeg sample output"));
      else resolvePromise(frames);
    });
  });
}

async function referencePNG(sourcePath: string, timeMs: number, seek = timeMs / 1000, maxSize = 1280): Promise<Buffer> {
  const png = await run("ffmpeg", [
    "-v", "error", ...(seek > 0 ? ["-ss", seek.toFixed(6)] : []), "-i", sourcePath,
    "-frames:v", "1", "-vf", `scale=w='min(${maxSize},iw)':h='min(${maxSize},ih)':force_original_aspect_ratio=decrease`,
    "-f", "image2pipe", "-vcodec", "png", "pipe:1",
  ]);
  if (!png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error(`Could not decode reference image at ${timeMs} ms`);
  }
  return png;
}

async function probeMomentSource(videoFile: string) {
  const sourcePath = resolve(videoFile);
  if (![".mp4", ".mov"].includes(extname(sourcePath).toLowerCase())) throw new Error("Expected an MP4 or MOV recording");
  const info = await stat(sourcePath);
  if (!info.isFile() || info.size > MAX_VIDEO_BYTES) throw new Error("Recording must be a file no larger than 512 MiB");
  const duration = parseDuration(await run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "json", sourcePath]));
  return { sourcePath, durationMs: duration * 1000 };
}

/** Read a precise visual reference from a bounded local recording. */
export async function readVideoMoment(videoFile: string, timeMs: number): Promise<Buffer> {
  if (!Number.isFinite(timeMs) || timeMs < 0) throw new Error("Timestamp must be a nonnegative number of milliseconds");
  const { sourcePath, durationMs } = await probeMomentSource(videoFile);
  if (timeMs >= durationMs) throw new Error("Timestamp must be before the end of the recording");
  return referencePNG(sourcePath, timeMs, seekForMoment((await presentationTimes(sourcePath)).seekTimes, timeMs / 1000));
}

/** Read a short sequence around a release, ending before the next recorded drag. */
export async function readDragReleaseFrames(videoFile: string, releaseTimeMs: number, nextDragTimeMs?: number) {
  const { sourcePath, durationMs } = await probeMomentSource(videoFile);
  const frames: Array<{ timeMs: number; png: Buffer }> = [];
  const endTimeMs = Math.min(30_000, Math.ceil(durationMs) - 1, (nextDragTimeMs ?? Infinity) - 1);
  if (releaseTimeMs > endTimeMs) return { endTimeMs, frames };
  const timeline = await presentationTimes(sourcePath);
  const times = timeline.seekTimes;
  const offsets = [-80, 150, 800, 2_000, 4_000];
  const sampleTimes = new Set(offsets.map((offset) => Math.max(0, Math.min(releaseTimeMs + offset, endTimeMs))));
  sampleTimes.add(endTimeMs);
  for (const timeMs of sampleTimes) {
    frames.push({ timeMs, png: await referencePNG(sourcePath, timeMs, seekForMoment(times, timeMs / 1000), 768) });
  }
  return { endTimeMs, frames };
}

function chooseKeyframes(frames: readonly FrameSample[], deltas: readonly number[]): readonly { kind: Keyframe["kind"]; index: number }[] {
  if (frames.length === 1) return [{ kind: "start", index: 0 }];
  const peakDelta = Math.max(...deltas);
  // Suppress codec noise in an otherwise stationary screen recording.
  if (peakDelta < 0.00002) return [{ kind: "start", index: 0 }];
  const peakIndex = Math.max(1, deltas.indexOf(peakDelta));
  const meaningfulThreshold = Math.max(0.008, peakDelta * 0.12);
  const firstMotionIndex = deltas.findIndex((delta) => delta >= meaningfulThreshold);
  const startIndex = firstMotionIndex < 0 ? 0 : firstMotionIndex;
  const settleThreshold = Math.max(0.003, peakDelta * 0.08);
  let settledIndex = frames.length - 1;
  // Require a quiet tail of at least three intervals, or the available tail.
  const quietIntervals = Math.min(3, Math.max(1, deltas.length - peakIndex));
  for (let i = peakIndex + quietIntervals; i < frames.length; i += 1) {
    const tail = deltas.slice(i - quietIntervals + 1, i + 1);
    if (tail.length === quietIntervals && tail.every((delta) => delta <= settleThreshold)) {
      settledIndex = i;
      break;
    }
  }
  const byIndex = new Map<number, Keyframe["kind"]>();
  byIndex.set(startIndex, "start");
  if (peakIndex !== startIndex && peakIndex !== settledIndex) byIndex.set(peakIndex, "peak");
  if (settledIndex !== startIndex && settledIndex !== peakIndex) byIndex.set(settledIndex, "settled");
  return [...byIndex].map(([index, kind]) => ({ index, kind })).sort((a, b) => a.index - b.index);
}

/**
 * Analyze a short MP4/MOV recording. Requires `ffmpeg` and `ffprobe` on PATH.
 * Decodes downscaled RGB samples to keep memory and CPU use predictable.
 */
export async function inspectVideo(videoFile: string, options: ExtractOptions = {}): Promise<InspectionResult> {
  const sourcePath = resolve(videoFile);
  const extension = extname(sourcePath).toLowerCase();
  if (extension !== ".mp4" && extension !== ".mov") throw new Error("Only .mp4 and .mov video files are supported");
  const fileInfo = await stat(sourcePath);
  if (!fileInfo.isFile()) throw new Error("Video path must point to a file");
  if (fileInfo.size > MAX_VIDEO_BYTES) throw new Error("Video file exceeds the 512 MiB limit");
  const durationSeconds = parseDuration(await run("ffprobe", [
    "-v", "error", "-show_entries", "format=duration", "-of", "json", sourcePath,
  ]));

  const sampleWidth = Math.max(48, Math.min(256, Math.round(options.sampleWidth ?? DEFAULT_SAMPLE_WIDTH)));
  const sampleRate = Math.max(2, Math.min(24, Math.round(options.samplesPerSecond ?? DEFAULT_SAMPLES_PER_SECOND)));
  const sampleCount = Math.max(2, Math.min(720, Math.ceil(durationSeconds * sampleRate)));
  options.onProgress?.("motion");
  const timeline = await presentationTimes(sourcePath);
  const times = timeline.seekTimes;
  const sampleTimes = Array.from({ length: sampleCount }, (_, index) => {
    const time = Math.min(durationSeconds - 0.001, (index / (sampleCount - 1)) * durationSeconds);
    return Math.round(Math.max(0, time) * 1000);
  });
  const seeks = sampleTimes.map(time => seekForMoment(times, time / 1000));
  const decoded = await readFrames(sourcePath, seeks, timeline.decodeTimes, sampleWidth, timeline.streamIndex);
  const frames = decoded.map((frame, index) => ({ ...frame, timeMs: sampleTimes[index]! }));
  const deltas = frames.slice(1).map((frame, index) => pixelDifference(frames[index]!, frame));
  const keys = chooseKeyframes(frames, deltas);
  options.onProgress?.("frames");
  const outputDirectory = options.outputDirectory
    ? resolve(options.outputDirectory)
    : await mkdtemp(join(tmpdir(), "poach-"));
  await mkdir(outputDirectory, { recursive: true });
  const safeBase = basename(sourcePath, extension).replace(/[^a-zA-Z0-9_-]+/g, "-").slice(0, 48) || "capture";
  const keyframes: Keyframe[] = [];
  for (const { kind, index } of keys) {
    const frame = frames[index]!;
    const imagePath = join(outputDirectory, `${safeBase}-${kind}-${frame.timeMs}ms.png`);
    await writeFile(imagePath, await referencePNG(sourcePath, frame.timeMs, seekForMoment(times, frame.timeMs / 1000)));
    keyframes.push({ kind, timeMs: frame.timeMs, imagePath, motion: index === 0 ? 0 : deltas[index - 1] ?? 0 });
  }
  const motionStartMs = frames[keys[0]?.index ?? 0]?.timeMs ?? 0;
  const settled = keys.find((key) => key.kind === "settled");
  const settledTimeMs = settled ? frames[settled.index]!.timeMs : Math.round(durationSeconds * 1000);
  const durationMs = keys.length === 1 ? 0 : Math.max(0, settledTimeMs - motionStartMs);
  const timing = approximateTiming(frames, deltas, motionStartMs, durationMs);
  const paletteFrame = frames[keys.find((key) => key.kind === "settled")?.index ?? frames.length - 1]!;
  options.onProgress?.("palette");
  const palette = extractPalette(paletteFrame, options.paletteSize ?? 6);

  return {
    mediaType: "video",
    sourcePath,
    durationMs,
    keyframes,
    palette,
    timing,
  };
}

/** Analyze a still image and return one PNG keyframe plus its dominant colors. */
export async function inspectImage(imageFile: string, options: ExtractOptions = {}): Promise<InspectionResult> {
  const sourcePath = resolve(imageFile);
  const extension = extname(sourcePath).toLowerCase();
  if (![".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".bmp"].includes(extension)) {
    throw new Error("Supported still images are PNG, JPEG, WebP, TIFF, and BMP");
  }
  const fileInfo = await stat(sourcePath);
  if (!fileInfo.isFile()) throw new Error("Image path must point to a file");
  if (fileInfo.size > MAX_VIDEO_BYTES) throw new Error("Image file exceeds the 512 MiB limit");
  const probe = JSON.parse((await run("ffprobe", [
    "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", sourcePath,
  ])).toString("utf8")) as { streams?: Array<{ width?: number; height?: number }> };
  const input = probe.streams?.[0];
  if (!input?.width || !input.height) throw new Error("Image has no decodable pixel dimensions");
  const width = Math.max(48, Math.min(256, Math.round(options.sampleWidth ?? DEFAULT_SAMPLE_WIDTH)));
  const raw = await run("ffmpeg", [
    "-v", "error", "-i", sourcePath, "-frames:v", "1", "-vf", `scale=${width}:-2:flags=area`,
    "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
  ]);
  const height = raw.length / (width * 3);
  if (!Number.isInteger(height) || height < 1) throw new Error("Could not decode image pixels");
  const frame: FrameSample = { timeMs: 0, pixels: raw, width, height, channels: 3 };
  options.onProgress?.("frames");
  const outputDirectory = options.outputDirectory ? resolve(options.outputDirectory) : await mkdtemp(join(tmpdir(), "poach-"));
  await mkdir(outputDirectory, { recursive: true });
  const safeBase = basename(sourcePath, extension).replace(/[^a-zA-Z0-9_-]+/g, "-").slice(0, 48) || "image";
  const imagePath = join(outputDirectory, `${safeBase}-image.png`);
  await writeFile(imagePath, await referencePNG(sourcePath, 0));
  options.onProgress?.("palette");
  const palette = extractPalette(frame, options.paletteSize ?? 6);
  return {
    mediaType: "image",
    sourcePath,
    durationMs: 0,
    keyframes: [{ kind: "start", timeMs: 0, imagePath, motion: 0 }],
    palette,
    timing: { durationMs: 0, bezier: null, token: "Still image · no motion duration" },
  };
}
