export type RGB = readonly [red: number, green: number, blue: number];

export interface Keyframe {
  readonly kind: "start" | "peak" | "settled";
  readonly timeMs: number;
  readonly imagePath: string;
  /** Normalized mean absolute pixel difference from the prior sample (0–1). */
  readonly motion: number;
}

export interface MotionTiming {
  /** Time from the first meaningful change until visual settlement. */
  readonly durationMs: number;
  readonly bezier: readonly [number, number, number, number] | null;
  readonly token: string;
}

/** A pointer action sampled from the active local screen recording. */
export interface PointerTraceEvent {
  readonly timeMs: number;
  readonly kind: "move" | "down" | "up" | "drag";
  /** Normalized coordinate within the captured bounds (0–1). */
  readonly x: number;
  /** Normalized coordinate within the captured bounds (0–1), top-left origin. */
  readonly y: number;
  /** False when the pointer sample is outside the capture bounds; normalized coordinates are clamped to the edge. */
  readonly withinCapture: boolean;
  readonly button?: "left" | "right" | "other";
}

/** Pointer-only interaction evidence, kept with the explicitly shared brief. */
export interface PointerTrace {
  readonly available: boolean;
  readonly coordinateSpace: "normalized-capture-bounds";
  readonly origin: "top-left";
  readonly boundsWidth: number;
  readonly boundsHeight: number;
  readonly sampleIntervalMs: number;
  /** Total pointer polls completed while the recording was active. */
  readonly sampleCount?: number;
  /** Polls where the pointer was inside the recorded bounds. */
  readonly insideSampleCount?: number;
  /** Polls where at least one mouse button was down. */
  readonly buttonSampleCount?: number;
  /** Scroll is not sampled by the capture-scoped pointer poller. */
  readonly scrollCaptured: false;
  readonly truncated: boolean;
  readonly events: readonly PointerTraceEvent[];
}

/** A user-authored label anchored to a time in the captured video. */
export interface InteractionAnnotation {
  readonly timeMs: number;
  readonly text: string;
}

/** Dimensions of the stored media, not necessarily the original display. */
export interface CaptureInfo {
  readonly widthPx: number;
  readonly heightPx: number;
  /** Stored pixels per macOS point when known; null for imported media. */
  readonly deviceScale: number | null;
  readonly imageMaxSize: number;
}
export interface MomentOptions {
  readonly maxSize?: number;
  readonly crop?: { readonly x: number; readonly y: number; readonly width: number; readonly height: number };
}

export interface InspectionResult {
  readonly capture?: CaptureInfo;
  readonly mediaType: "video" | "image";
  readonly sourcePath: string;
  readonly durationMs: number;
  readonly keyframes: readonly Keyframe[];
  readonly palette: readonly string[];
  readonly timing: MotionTiming;
  /** Present for Poach's native screen recordings; imported media has no trace. */
  readonly pointerTrace?: PointerTrace;
  /** Labels attached to timestamps in Poach's review editor. */
  readonly annotations?: readonly InteractionAnnotation[];
}

export interface ExtractOptions {
  readonly onProgress?: (stage: "motion" | "frames" | "palette") => void;
  /** Directory for PNG keyframes. Defaults to a temporary Poach directory. */
  readonly outputDirectory?: string;
  /** Maximum decoded sample width; height is scaled to preserve aspect ratio. */
  readonly sampleWidth?: number;
  /** Analysis samples per second, capped to a safe range. */
  readonly samplesPerSecond?: number;
  /** Number of dominant colors to return. */
  readonly paletteSize?: number;
}

export interface FrameSample {
  readonly timeMs: number;
  readonly pixels: Buffer;
  readonly width: number;
  readonly height: number;
  readonly channels: number;
}
