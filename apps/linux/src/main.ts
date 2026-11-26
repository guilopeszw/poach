import "@fontsource-variable/bricolage-grotesque/standard.css";
import "./styles.css";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { open } from "@tauri-apps/plugin-dialog";
import brandIcon from "../src-tauri/icons/128x128@2x.png";
import pouchIcon from "../src-tauri/icons/icon.png";
import { handoffPrompt, implementationContext, type Note } from "./prompt";

interface Keyframe {
  readonly kind: string;
  readonly timeMs: number;
  readonly imagePath: string;
}

/** Subset of @poach/core's InspectionResult the UI reads; the rest is passed through. */
interface Inspection {
  readonly mediaType: "video" | "image";
  readonly sourcePath: string;
  readonly keyframes: readonly Keyframe[];
  readonly palette: readonly string[];
  readonly timing: {
    readonly durationMs: number;
    readonly bezier: readonly [number, number, number, number] | null;
    readonly token: string;
  };
  readonly capture?: { readonly widthPx: number; readonly heightPx: number };
  readonly [key: string]: unknown;
}

interface Recording {
  readonly path: string;
}

interface RecordingStarted {
  readonly maxSeconds: number;
  readonly controlsHiddenFromVideo: boolean;
}

const STAGES = ["motion", "frames", "palette"] as const;
const KEYFRAME_NAMES: Record<string, string> = { start: "Start", peak: "Peak motion", settled: "Settled" };

function element<T extends Element>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`Missing #${id}`);
  return found as unknown as T;
}

const ui = {
  connector: element<HTMLButtonElement>("connector"),
  connectorMenu: element<HTMLDivElement>("connector-menu"),
  newCapture: element<HTMLButtonElement>("new-capture"),
  capture: element<HTMLElement>("capture"),
  captureActions: element<HTMLDivElement>("capture-actions"),
  progress: element<HTMLOListElement>("progress"),
  screenshot: element<HTMLButtonElement>("screenshot"),
  import: element<HTMLButtonElement>("import"),
  status: element<HTMLParagraphElement>("status"),
  editor: element<HTMLElement>("editor"),
  editorTitle: element<HTMLHeadingElement>("editor-title"),
  editorMeta: element<HTMLParagraphElement>("editor-meta"),
  media: element<HTMLDivElement>("media"),
  timelineBlock: element<HTMLDivElement>("timeline-block"),
  timeline: element<HTMLDivElement>("timeline"),
  track: element<HTMLDivElement>("track"),
  playhead: element<HTMLDivElement>("playhead"),
  timelineEnd: element<HTMLSpanElement>("timeline-end"),
  noteForm: element<HTMLFormElement>("note-form"),
  noteLabel: element<HTMLLabelElement>("note-label"),
  noteText: element<HTMLInputElement>("note-text"),
  notes: element<HTMLOListElement>("notes"),
  keyframes: element<HTMLUListElement>("keyframes"),
  palette: element<HTMLUListElement>("palette"),
  motionSection: element<HTMLElement>("motion-section"),
  curve: element<SVGSVGElement>("curve"),
  motionDuration: element<HTMLParagraphElement>("motion-duration"),
  motionCurve: element<HTMLParagraphElement>("motion-curve"),
  context: element<HTMLTextAreaElement>("context"),
  handoffStatus: element<HTMLParagraphElement>("handoff-status"),
};

element<HTMLImageElement>("brand-mark").src = brandIcon;
element<HTMLImageElement>("stage-pouch").src = pouchIcon;

let inspection: Inspection | null = null;
let notes: Note[] = [];
let video: HTMLVideoElement | null = null;
let connected = false;

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));
const seconds = (ms: number, digits = 2) => `${(ms / 1000).toFixed(digits)} s`;

// --- Views ---------------------------------------------------------------------

function showCapture(): void {
  ui.editor.hidden = true;
  ui.capture.hidden = false;
  ui.newCapture.hidden = true;
  video?.pause();
}

function showEditor(): void {
  ui.capture.hidden = true;
  ui.editor.hidden = false;
  ui.newCapture.hidden = false;
  window.scrollTo({ top: 0 });
}

function setBusy(busy: boolean): void {
  for (const button of ui.captureActions.querySelectorAll("button")) button.disabled = busy;
}

function showProgress(stage: (typeof STAGES)[number] | null): void {
  ui.captureActions.hidden = stage !== null;
  ui.progress.hidden = stage === null;
  const current = stage ? STAGES.indexOf(stage) : -1;
  for (const item of ui.progress.querySelectorAll<HTMLLIElement>("li")) {
    const index = STAGES.indexOf(item.dataset.stage as (typeof STAGES)[number]);
    item.classList.toggle("done", index < current);
    item.classList.toggle("active", index === current);
    if (index === current) item.setAttribute("aria-current", "step");
    else item.removeAttribute("aria-current");
  }
}

// --- Connector -----------------------------------------------------------------

async function refreshConnector(): Promise<void> {
  connected = await invoke<boolean>("connector_connected").catch(() => false);
  ui.connector.textContent = connected ? "Assistant connected" : "No assistant connected";
  ui.connector.classList.toggle("on", connected);
  ui.connector.title = connected ? "" : "Copy the command that connects Poach to Claude Code or Codex";
  if (connected) closeConnectorMenu(false);
}

type Assistant = "claude" | "codex";
const ASSISTANT_NAMES: Record<Assistant, string> = { claude: "Claude Code", codex: "Codex" };

function setupItems(): HTMLButtonElement[] {
  return [...ui.connectorMenu.querySelectorAll<HTMLButtonElement>("[role=menuitem]")];
}

function openConnectorMenu(): void {
  if (connected) return;
  ui.connectorMenu.hidden = false;
  ui.connector.setAttribute("aria-expanded", "true");
  setupItems()[0]?.focus();
}

function closeConnectorMenu(restoreFocus: boolean): void {
  if (ui.connectorMenu.hidden) return;
  ui.connectorMenu.hidden = true;
  ui.connector.setAttribute("aria-expanded", "false");
  if (restoreFocus) ui.connector.focus();
}

/** Copy the setup command; the user runs it once, then opens a new session. */
async function copyConnectorSetup(assistant: Assistant): Promise<void> {
  closeConnectorMenu(true);
  try {
    await writeText(await invoke<string>("connector_command", { assistant }));
    ui.status.textContent = `Setup command copied. Run it in a terminal, then start a new ${ASSISTANT_NAMES[assistant]} session.`;
  } catch (error) {
    ui.status.textContent = `Could not copy the setup command: ${errorText(error)}`;
  }
  ui.handoffStatus.textContent = ui.status.textContent;
}

// --- Capture ---------------------------------------------------------------------

/** Poach hides while recording; the controls window stops it and the result arrives as an event. */
async function startRecording(source: "monitor" | "window"): Promise<void> {
  setBusy(true);
  ui.status.textContent = source === "window" ? "Pick a window in the system dialog." : "Starting the recording…";
  try {
    const started = await invoke<RecordingStarted>("start_recording", { source });
    ui.status.textContent = started.controlsHiddenFromVideo
      ? "Recording."
      : "Recording. Turn on the Poach Capture GNOME extension to keep the controls out of screen recordings.";
  } catch (error) {
    ui.status.textContent = errorText(error);
    setBusy(false);
  }
}

async function takeScreenshot(): Promise<void> {
  setBusy(true);
  ui.status.textContent = "Choose what to capture in the system dialog.";
  try {
    await analyze(await invoke<string>("take_screenshot"), false);
  } catch (error) {
    ui.status.textContent = errorText(error);
    showProgress(null);
  } finally {
    setBusy(false);
  }
}

async function importFile(): Promise<void> {
  let path: string | string[] | null;
  try {
    path = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "Images and videos", extensions: ["png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "mp4", "mov"] }],
    });
  } catch (error) {
    ui.status.textContent = `Could not open the file picker: ${errorText(error)}`;
    return;
  }
  if (typeof path !== "string") return;
  setBusy(true);
  try {
    await analyze(path, false);
  } catch (error) {
    ui.status.textContent = errorText(error);
    showProgress(null);
  } finally {
    setBusy(false);
  }
}

async function analyze(path: string, isRecording: boolean): Promise<void> {
  showCapture();
  showProgress("motion");
  ui.status.textContent = "";
  inspection = await invoke<Inspection>("inspect", { path, isRecording });
  showProgress(null);
  notes = [];
  ui.context.value = "";
  ui.handoffStatus.textContent = "";
  renderEditor(path);
  showEditor();
}

// --- Editor -----------------------------------------------------------------------

function renderEditor(path: string): void {
  video = null;
  if (!inspection) return;
  const isVideo = inspection.mediaType === "video";
  ui.editorTitle.textContent = isVideo ? "Recording" : "Screenshot";
  ui.editorMeta.textContent = describeMedia(path);

  ui.media.replaceChildren();
  video = null;
  if (isVideo) {
    video = document.createElement("video");
    void loadVideo(video, inspection.sourcePath);
    video.controls = true;
    video.preload = "auto";
    video.setAttribute("aria-label", "Captured recording");
    video.addEventListener("loadedmetadata", renderTimeline);
    video.addEventListener("timeupdate", updatePlayhead);
    video.addEventListener("seeked", updatePlayhead);
    ui.media.append(video);
  } else {
    const image = document.createElement("img");
    image.src = convertFileSrc(inspection.sourcePath);
    image.alt = "Captured screenshot";
    ui.media.append(image);
  }
  ui.timelineBlock.hidden = !isVideo;
  ui.motionSection.hidden = !isVideo;

  renderPalette(inspection.palette);
  renderMotion(inspection.timing);
  renderKeyframes(inspection.keyframes, isVideo);
  renderNotes();
}

let videoUrl: string | null = null;

/**
 * WebKitGTK hands video URLs to GStreamer, which cannot read Tauri's asset://
 * scheme. Fetch the file (capped at 30 s, so a few MB) and play it from a blob.
 */
async function loadVideo(target: HTMLVideoElement, path: string): Promise<void> {
  if (videoUrl) URL.revokeObjectURL(videoUrl);
  videoUrl = null;
  try {
    const response = await fetch(convertFileSrc(path));
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const type = path.toLowerCase().endsWith(".mov") ? "video/quicktime" : "video/mp4";
    videoUrl = URL.createObjectURL(new Blob([await response.arrayBuffer()], { type }));
    target.src = videoUrl;
  } catch (error) {
    ui.editorMeta.textContent = `The video could not be loaded: ${errorText(error)}`;
  }
}

/** WCAG relative luminance of a #rrggbb color. */
function luminance(hex: string): number {
  const channels = [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16) / 255);
  const [r, g, b] = channels.map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(first: string, second: string): number {
  const [light, dark] = [luminance(first), luminance(second)].sort((a, b) => b - a) as [number, number];
  return (light + 0.05) / (dark + 0.05);
}

/** Swatch label with the higher contrast, falling back to black when neither reaches 4.5:1. */
function labelColor(hex: string): string {
  const best = ["#16173a", "#ffffff"].reduce((a, b) => (contrast(b, hex) > contrast(a, hex) ? b : a));
  return contrast(best, hex) >= 4.5 ? best : "#000000";
}

function renderPalette(palette: readonly string[]): void {
  ui.palette.classList.remove("reveal");
  ui.palette.replaceChildren(
    ...palette.map((hex, index) => {
      const item = document.createElement("li");
      const swatch = document.createElement("button");
      swatch.type = "button";
      swatch.className = "swatch";
      swatch.style.background = hex;
      swatch.style.color = labelColor(hex);
      swatch.style.animationDelay = `${index * 45}ms`;
      const code = document.createElement("span");
      code.textContent = hex;
      const action = document.createElement("span");
      action.className = "swatch-action";
      action.textContent = "Copy";
      swatch.append(code, action);
      swatch.setAttribute("aria-label", `Copy ${hex}`);
      swatch.addEventListener("click", () => {
        void writeText(hex).then(() => {
          action.textContent = "Copied";
          swatch.classList.add("copied");
          window.setTimeout(() => {
            action.textContent = "Copy";
            swatch.classList.remove("copied");
          }, 1200);
        });
      });
      item.append(swatch);
      return item;
    }),
  );
  // Restart the one entrance animation in the app: colors pour into the panel.
  void ui.palette.offsetWidth;
  ui.palette.classList.add("reveal");
}

function renderMotion(timing: Inspection["timing"]): void {
  const ns = "http://www.w3.org/2000/svg";
  const shape = (name: string, attributes: Record<string, string | number>) => {
    const node = document.createElementNS(ns, name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
    return node;
  };
  ui.curve.replaceChildren();
  if (timing.durationMs <= 0) {
    ui.motionDuration.textContent = "No motion";
    ui.motionCurve.textContent = "Nothing moved enough to measure.";
    return;
  }
  ui.motionDuration.textContent = seconds(timing.durationMs);
  const bezier = timing.bezier;
  if (!bezier) {
    ui.motionCurve.textContent = "Easing could not be estimated.";
    return;
  }
  ui.motionCurve.textContent = `cubic-bezier(${bezier.join(", ")})`;
  // 100×100 box, y grows downward, so flip the curve's y values.
  const [x1, y1, x2, y2] = bezier.map((value) => value * 100) as [number, number, number, number];
  ui.curve.append(
    shape("path", { class: "axis", d: "M0 0V100H100" }),
    shape("line", { class: "handle", x1: 0, y1: 100, x2: x1, y2: 100 - y1 }),
    shape("line", { class: "handle", x1: 100, y1: 0, x2: x2, y2: 100 - y2 }),
    shape("path", { class: "path", d: `M0 100C${x1} ${100 - y1} ${x2} ${100 - y2} 100 0` }),
    shape("circle", { class: "knot", cx: x1, cy: 100 - y1, r: 3.5 }),
    shape("circle", { class: "knot", cx: x2, cy: 100 - y2, r: 3.5 }),
  );
}

function renderKeyframes(frames: readonly Keyframe[], isVideo: boolean): void {
  ui.keyframes.replaceChildren(
    ...frames.map((frame) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "keyframe";
      button.disabled = !isVideo;
      button.addEventListener("click", () => seek(frame.timeMs));
      const image = document.createElement("img");
      image.src = convertFileSrc(frame.imagePath);
      image.alt = "";
      const name = document.createElement("span");
      name.className = "keyframe-name";
      name.textContent = KEYFRAME_NAMES[frame.kind] ?? frame.kind;
      const time = document.createElement("span");
      time.className = "keyframe-time";
      time.textContent = seconds(frame.timeMs);
      button.append(image, name, time);
      button.setAttribute("aria-label", `Go to ${name.textContent} at ${time.textContent}`);
      item.append(button);
      return item;
    }),
  );
}

/** "9.2 s, 1920 × 1080" for recordings; imported files keep their name. */
function describeMedia(path: string): string {
  const parts: string[] = [];
  if (!/\/captures\/(recording|screenshot)-/.test(path)) parts.push(path.split("/").pop() ?? "");
  if (durationMs() > 0) parts.push(seconds(durationMs(), 1));
  if (inspection?.capture) parts.push(`${inspection.capture.widthPx} × ${inspection.capture.heightPx}`);
  return parts.filter(Boolean).join(", ");
}

// --- Timeline ----------------------------------------------------------------------

function durationMs(): number {
  return video && Number.isFinite(video.duration) ? video.duration * 1000 : 0;
}

function marker(className: string, timeMs: number, label: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `marker ${className}`;
  button.style.left = `${Math.min(100, (timeMs / Math.max(1, durationMs())) * 100)}%`;
  button.setAttribute("aria-label", label);
  button.title = label;
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    seek(timeMs);
  });
  return button;
}

function renderTimeline(): void {
  if (!inspection || !video) return;
  ui.editorMeta.textContent = describeMedia(inspection.sourcePath);
  for (const old of ui.timeline.querySelectorAll(".marker")) old.remove();
  // Markers need the clip length; they appear once the video's metadata loads.
  ui.timelineEnd.textContent = durationMs() > 0 ? seconds(durationMs(), 1) : "";
  if (durationMs() <= 0) return;
  ui.timeline.append(
    ...inspection.keyframes.map((frame) =>
      marker("keyframe-tick", frame.timeMs, `${KEYFRAME_NAMES[frame.kind] ?? frame.kind} keyframe at ${seconds(frame.timeMs)}`)),
    ...notes.map((note) => marker("note-pin", note.timeMs, `Note at ${seconds(note.timeMs)}: ${note.text}`)),
  );
  updatePlayhead();
}

function updatePlayhead(): void {
  if (!video) return;
  const total = durationMs();
  ui.playhead.style.left = total ? `${(video.currentTime * 1000 / total) * 100}%` : "0";
  ui.noteLabel.textContent = `Note at ${seconds(video.currentTime * 1000)}`;
}

function seek(timeMs: number): void {
  if (!video) return;
  video.pause();
  video.currentTime = timeMs / 1000;
}

ui.timeline.addEventListener("click", (event) => {
  const box = ui.timeline.getBoundingClientRect();
  seek(Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)) * durationMs());
});

// --- Notes -------------------------------------------------------------------------

function renderNotes(): void {
  ui.notes.replaceChildren(
    ...notes.map((note, index) => {
      const item = document.createElement("li");
      const jump = document.createElement("button");
      jump.type = "button";
      jump.className = "link";
      jump.textContent = seconds(note.timeMs);
      jump.setAttribute("aria-label", `Go to ${jump.textContent}`);
      jump.addEventListener("click", () => seek(note.timeMs));
      const text = document.createElement("span");
      text.textContent = note.text;
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "link quiet";
      remove.textContent = "Remove";
      remove.setAttribute("aria-label", `Remove note at ${jump.textContent}`);
      remove.addEventListener("click", () => {
        notes.splice(index, 1);
        renderNotes();
      });
      item.append(jump, text, remove);
      return item;
    }),
  );
  renderTimeline();
}

function addNote(event: SubmitEvent): void {
  event.preventDefault();
  const text = ui.noteText.value.trim();
  if (!video || !text) return;
  video.pause();
  notes.push({ timeMs: Math.round(video.currentTime * 1000), text });
  notes.sort((first, second) => first.timeMs - second.timeMs);
  ui.noteText.value = "";
  renderNotes();
}

// --- Handoff -----------------------------------------------------------------------

async function handoff(assistant: "claude" | "codex"): Promise<void> {
  if (!inspection) return;
  await refreshConnector();
  if (!connected) {
    ui.handoffStatus.textContent = "Open a Claude Code or Codex session with the Poach connector, then try again.";
    return;
  }
  try {
    const context = implementationContext(ui.context.value, notes);
    const briefId = await invoke<string>("share_handoff", { inspection, context, annotations: notes });
    await writeText(handoffPrompt(briefId, inspection.mediaType === "video"));
    ui.handoffStatus.textContent = `Prompt copied. Paste it into ${assistant === "claude" ? "Claude Code" : "Codex"}.`;
  } catch (error) {
    ui.handoffStatus.textContent = errorText(error);
  }
}

// --- Wiring ------------------------------------------------------------------------

for (const button of document.querySelectorAll<HTMLButtonElement>("[data-record]")) {
  button.addEventListener("click", () => void startRecording(button.dataset.record === "window" ? "window" : "monitor"));
}
for (const button of document.querySelectorAll<HTMLButtonElement>("[data-assistant]")) {
  button.addEventListener("click", () => void handoff(button.dataset.assistant === "codex" ? "codex" : "claude"));
}
ui.screenshot.addEventListener("click", () => void takeScreenshot());
ui.import.addEventListener("click", () => void importFile());
ui.newCapture.addEventListener("click", () => {
  showCapture();
  // The New capture button is now hidden; keep keyboard focus in the page.
  ui.captureActions.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
});
ui.connector.addEventListener("click", () => {
  if (ui.connectorMenu.hidden) openConnectorMenu();
  else closeConnectorMenu(true);
});
for (const item of setupItems()) {
  item.addEventListener("click", () => void copyConnectorSetup(item.dataset.setup === "codex" ? "codex" : "claude"));
}
ui.connectorMenu.addEventListener("keydown", (event) => {
  const items = setupItems();
  const index = items.indexOf(document.activeElement as HTMLButtonElement);
  if (event.key === "Escape") {
    event.preventDefault();
    closeConnectorMenu(true);
  } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    items[(index + step + items.length) % items.length]?.focus();
  }
});
document.addEventListener("click", (event) => {
  if (!(event.target instanceof Node) || !ui.connector.parentElement?.contains(event.target)) closeConnectorMenu(false);
});

// Actions from the top bar menu and the global shortcut (via the GNOME extension).
void listen<string>("menu-action", (event) => {
  if (event.payload === "screenshot") {
    showCapture();
    void takeScreenshot();
  } else if (event.payload === "new-recording") {
    showCapture();
    ui.captureActions.querySelector<HTMLButtonElement>("[data-record]")?.focus();
  } else if (event.payload === "record-screen") {
    showCapture();
    void startRecording("monitor");
  }
});
ui.noteForm.addEventListener("submit", addNote);

void listen<Recording>("recording-finished", (event) => {
  void analyze(event.payload.path, true)
    .catch((error: unknown) => {
      ui.status.textContent = errorText(error);
      showProgress(null);
    })
    .finally(() => setBusy(false));
});
void listen<string>("recording-failed", (event) => {
  ui.status.textContent = event.payload;
  setBusy(false);
});
void listen<string>("inspect-progress", (event) => {
  const stage = STAGES.find((name) => name === event.payload);
  if (stage) showProgress(stage);
});

function applyWindowRadius(radius: number): void {
  document.documentElement.style.setProperty("--window-radius", `${radius}px`);
}
void invoke<number>("window_radius").then(applyWindowRadius).catch(() => undefined);
void listen<number>("window-radius", (event) => applyWindowRadius(event.payload));

void refreshConnector();
window.setInterval(() => void refreshConnector(), 5000);
