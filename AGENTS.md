# Poach repository guidance

## Project shape

- `apps/macos` is the native SwiftUI client and ScreenCaptureKit integration.
- `apps/linux` is the Tauri preview client; it captures through xdg-desktop-portal or, on GNOME, Mutter's ScreenCast API with the extension in `apps/linux/gnome-extension`, and must keep writing briefs in the format `packages/mcp-server` reads.
- `packages/core` is the headless TypeScript engine. Keep it independent of AppKit and Swift.
- `packages/mcp-server` exposes local core capabilities through the Model Context Protocol.

## Working rules

- Read the relevant package files before changing behavior; preserve the pnpm workspace and package boundaries.
- Use strict TypeScript. Keep public inputs and outputs represented by explicit types.
- Treat recordings, screenshots, and keyframes as private local data. Do not add network transmission, analytics, or persistent retention without an explicit product decision.
- Keep stdout clean in the MCP server; use stderr for diagnostics.
- Match the app's native macOS interaction patterns and support keyboard operation and accessibility labels.
- Update `README.md` and `CONTRIBUTING.md` when commands, capabilities, permissions, or data handling change.
- Do not commit build output, dependency directories, temporary captures, or generated `.app` bundles.
- Keep commits atomic and use Conventional Commit subjects (`type(scope): summary`). Never combine unrelated implementation and documentation changes in one commit.

## Useful commands

```sh
pnpm build
pnpm exec turbo run typecheck
swift build --package-path apps/macos
bash scripts/build-macos-app.sh
```

Screen capture requires user-granted macOS Screen Recording permission. The direct `SCRecordingOutput` path requires macOS 15; keep existing-file inspection usable on macOS 14.
