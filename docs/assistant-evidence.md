# Assistant evidence reference

Poach processes media locally. Sharing creates a local brief available by ID for 24 hours; browser page data is untrusted evidence. Existing briefs, favorites and version 1 `.poach` files remain readable when newer optional fields are absent.

## Image dimensions and detail crops

Every MCP image is captioned with its actual returned dimensions and known stored-source dimensions. Optional `evidence.capture` contains:

| Field | Meaning |
|---|---|
| `widthPx`, `heightPx` | Dimensions of the stored recording or image, after capture-time reduction and orientation. |
| `widthPoints`, `heightPoints` | Native capture bounds in macOS points, when known; absent on imports. |
| `deviceScale` | Horizontal stored pixels per macOS point; null/unknown for imports. Use both dimensions for exact mapping after encoder rounding. |
| `imageMaxSize` | Default reference-image limit (1280px); a saved favorite may keep a smaller preview. |

Browser CSS pixels are a separate coordinate space. Browser `devicePixelRatio` and `viewport` describe the page; do not equate them automatically with macOS points or recorded pixels.

`poach_read_moment` accepts the existing `briefId` and `timeMs`, plus optional `crop` and `maxSize`:

```json
{
  "briefId": "<shared brief ID>",
  "timeMs": 500,
  "crop": { "x": 65, "y": 43, "width": 97, "height": 73 },
  "maxSize": 1280
}
```

Crop coordinates are integers in stored-video pixels from the top-left, within the displayed/oriented source frame. Cropping preserves the selected full-frame RGB pixels before resizing. `maxSize` is an integer from 16 to 8192, defaults to 1280, and never enlarges pixels. The 5 MiB MCP image budget still applies. Native resolution means the stored recording, which may already be downscaled from the display. Favorites keep reference frames without their original recording; use `poach_read_brief` for those saved frames.

## Browser observations and timing

The brief can include `browserEvidence`: selected-component styles, events, states and available animation timing/keyframes. Moment responses include measured rectangles, visual styles and typography, with available page viewport and pixel ratio. A CSS font stack is a preference list, not proof of the font that rendered each glyph.

Browser `atMs` is relative to its session. Add `videoOffsetMs`, when present, for estimated video positions. Alignment retains observations within the recording interval plus one second of margin and the preceding state. Browser animation timing comes from the page; video-derived easing remains approximate.

State `rect` is a viewport CSS rectangle **at that observation’s timestamp**. Optional `pageRect` is its document-space CSS rectangle. Scrolling alone does not consume a state slot. A carried-forward state is marked `baseline: true`; its viewport geometry may be stale after scrolling. Confirm current placement in the video rather than treating a prior rectangle as a live measurement.

## Child-component snapshots and inspector

The companion measures visible descendants at pin time (`components`) and finish (`componentsAtEnd`). Each component has a sequential `id`, the nearest retained `parent` (or -1 for the root), a target description, root-relative CSS `rect`, bounded computed `styles` and short direct `text`.

Snapshots retain at most 40 components within six levels, with at most 80 text characters per component. Larger trees retain the largest areas clipped to the chosen root, in document order. Hidden and editable subtrees are excluded; visible children beneath `display: contents` or visibility-overriding wrappers remain measurable. These are two snapshots, not continuous tracking.

The bridge keeps its 256 KiB limit. It first drops only the optional end snapshot if necessary, then reports a clear size error if the remaining session is too large. MCP summarizes the snapshots without repeating the entire list in each moment response. Favorites and exports preserve the optional evidence.

During selection, the isolated inspector shows CSS size, typography, colors, visual properties and running animation timing. Hover/focus to inspect, ↑ for a parent, click/Enter to pin, Escape to cancel. It is removed before capture and stops refreshing on pin, cancel, navigation or target removal.

## Performance and evidence

Ordinary single-video inspection uses a sampling pass and a reference-frame pass. Multi-video files add one constant zero-frame initialization to preserve FFmpeg’s automatic stream selection and the legacy seek grid. Sampling buffers are framed incrementally with per-frame bounds; supported 720-sample/256px configurations remain valid.

See [native validation](validation/native-2026-11-21.md), [sampling measurements](benchmarks/sampling-2026-11-21.md), and [reference-frame tradeoffs](benchmarks/references-2026-11-21.md). Reported results apply to their identified commits, tools, fixtures and machine; core timings are distinct from native stop-to-editor latency.
