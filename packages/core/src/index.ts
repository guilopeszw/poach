export { inspectVideo, inspectRecording } from "./extractor.js";
export { readVideoMoment, readDragReleaseFrames } from "./extractor.js";
export { inspectImage } from "./extractor.js";
export { approximateTiming, pixelDifference } from "./motion.js";
export { extractPalette } from "./palette.js";
export type {
  ExtractOptions,
  CaptureInfo,
  MomentOptions,
  InspectionResult,
  InteractionAnnotation,
  Keyframe,
  MotionTiming,
  PointerTrace,
  PointerTraceEvent,
  RGB,
} from "./types.js";
