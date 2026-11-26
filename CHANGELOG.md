# Changelog

User-visible changes are recorded here. **Unreleased** describes changes on `main`; it does not mean a new app download has been published. Versions and release dates are added only when a packaged release is published.

## Unreleased

No changes yet.

## 1.0.1 — 2026-11-26

[Release and downloads](https://github.com/guilopeszw/poach/releases/tag/v1.0.1).

### Changed

- Reduce the macOS app bundle size by using Bun for inspection and MCP while retaining the existing connector executable path.
- Share the bundled media libraries between FFmpeg and ffprobe to further reduce the macOS app bundle size.
- Use a smaller icon in both connector downloads and share one packaged analysis core between the macOS app and its MCP server.

## 1.0.0 — 2026-11-22

[Release and downloads](https://github.com/guilopeszw/poach/releases/tag/v1.0.0).

### Added

- Live Chrome inspector with CSS dimensions, typography, colors and animation timing, plus keyboard selection and parent navigation. [#25](https://github.com/guilopeszw/poach/pull/25)
- Measured child-component hierarchy, relative rectangles, styles and short text at pin and finish, preserved in briefs, favorites and `.poach` exports. [#24](https://github.com/guilopeszw/poach/pull/24)
- Explicit image/source dimensions, known macOS point dimensions and native-resolution detail crops through `poach_read_moment`. [#22](https://github.com/guilopeszw/poach/pull/22)
- Richer browser observations at requested moments, including layout, colors, animations, page coordinates and clearly marked prior states. [#23](https://github.com/guilopeszw/poach/pull/23)

### Changed

- Batch motion samples through one FFmpeg process instead of launching one process per sample. Batch reference keyframes and drag-release sequences separately. [#20](https://github.com/guilopeszw/poach/pull/20), [#21](https://github.com/guilopeszw/poach/pull/21)
- Preserve compatibility with older briefs, favorites and exports; new evidence fields are optional. Privacy, permissions and 24-hour brief retention are unchanged.

### Fixed

- Multi-video stream/timestamp mismatches, including misleading media comments in FFmpeg diagnostics.
- Supported maximum sampling configurations being rejected by a cumulative buffer limit.
- Odd-origin crops changing colors through chroma alignment; crops now preserve exact full-frame RGB pixels, including rotated video.
- Visible children being skipped beneath boxless or visibility-overriding wrappers.
- Prior viewport rectangles appearing current after scrolling; document coordinates and baseline guidance distinguish observation-time geometry.

### Validation and attribution

- Native ScreenCaptureKit recording/screenshot, Retina/downscaled dimensions, exact native-video output parity, MCP crops, end boundaries and native favorite/export/import/share passed. Five measured native stops reached editor-show completion in **1.07s median** (0.95–1.18s), after one excluded warm-up on Apple M5 / macOS 26.6.2. [Method and results](docs/validation/native-2026-11-21.md)
- Historical core benchmarks and the reference-batching tradeoff are documented separately: [sampling](docs/benchmarks/sampling-2026-11-21.md), [references](docs/benchmarks/references-2026-11-21.md).
- Child measurement and inspector work adapts AnyPoach improvements by Miguel Mochizuki and contributors; see [NOTICE](NOTICE).

For earlier releases, see [GitHub releases](https://github.com/guilopeszw/poach/releases) and the [commit history](https://github.com/guilopeszw/poach/commits/main/).
