# Contributing to Poach

Thanks for helping improve Poach. The project is a pnpm/Turborepo monorepo with a native SwiftUI client, a TypeScript analysis core, and an MCP server.

## Contribute a change

Create a topic branch from the latest `main` and open a pull request against `main`. Explain the problem, the resulting behavior, and how you verified it. For interface changes, include a screenshot or short recording made with synthetic or explicitly shareable media. Call out changes to permissions, storage, or supported macOS versions.

**Every commit must be atomic and use a Conventional Commit subject** in the form `type(scope): summary`. Choose the area touched as the scope and describe the change with an imperative verb. For example:

```text
fix(codex): install a single connector launcher argument
style(editor): outline the instructions field
docs(readme): show the outlined instructions field
```

Keep one independently reviewable change per commit. Include regression tests with the fix they verify. Split unrelated edits, formatting, or documentation into separate commits. Use `feat` for new behavior, `fix` for corrections, `docs` for documentation, and `style`, `refactor`, `test`, `build`, `ci`, or `chore` when appropriate. Flag breaking interface changes with `!` before the colon and describe the migration in the commit body.

Use a lowercase scope made of letters, digits, dots, underscores, slashes, or hyphens, starting with a letter or digit. The check also accepts `perf` and `revert`. Rebase your branch to update it and reword any failing commits. Every PR must pass the commit check and resolve review conversations. PRs from contributors require approval from @guilopeszw, the code owner for every path. New commits dismiss earlier approvals. For an owner-authored PR, the owner can use GitHub’s review bypass to rebase and merge after the checks pass. Reserve repository administrator access for the owner.

Run the checks for each package you touch. Keep generated builds, dependency directories, app bundles, temporary captures, and private media out of commits. Update the README and this guide when commands, capabilities, permissions, or data handling change. Contributions are licensed under the repository’s [Apache License 2.0](LICENSE).

## Development setup

Install Node.js 20.19 or newer, the pnpm version pinned in [package.json](package.json), Swift 6, and the `ffmpeg` and `ffprobe` command-line tools. On macOS, install FFmpeg with Homebrew:

```sh
brew install ffmpeg
```

Then install dependencies and build the TypeScript packages:

```sh
pnpm install --frozen-lockfile
pnpm build
pnpm exec turbo run typecheck
```

The Swift package targets macOS 14 or later. Testing native screen recording requires macOS 15 or later and Screen Recording permission. Build the macOS package with:

```sh
swift build --package-path apps/macos
```

Run the pointer-trace event-cap regression check with `bash scripts/test-pointer-trace-buffer.sh`.

To build a Finder-openable app bundle, run `bash scripts/build-macos-app.sh`. It creates `outputs/Poach.app`, which is ignored by Git.

### Screen recording signing

For Screen Recording development on macOS 26, use an `Apple Development` identity with a Team ID. The build script prefers that identity automatically; set `POACH_CODESIGN_IDENTITY` to its exact name when you have more than one. Apple documents that ScreenCaptureKit permission must be granted to the app and that the app must restart after authorization ([capture guide](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [manage signing identities in Xcode](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)).

`Poach Local Development` is a self-signed fallback with no Team ID. It keeps the certificate stable, but macOS 26 may still invalidate Screen Recording approval across rebuilds. Ad-hoc signing can also invalidate approval. If Poach is enabled in System Settings but capture is denied, quit and reopen it once; if the denial persists, confirm that the running app is the same signed copy and rebuild with an Apple Development identity. Repeatedly toggling the permission does not repair a signing mismatch. The build script warns when the selected identity has no Team ID. For direct GitHub distribution, use a Developer ID Application identity; notarization is a separate release step. The packaging script bundles the pinned Node.js and FFmpeg tools.

## Project conventions

- Keep the analysis core deterministic, typed, headless, and independent from the macOS app.
- Keep MCP stdout reserved for protocol messages. Send diagnostics to stderr.
- Keep screen recordings local. Do not add network upload or telemetry without explicit product approval.
- Capture only what the person selected or explicitly started. Avoid recording microphone or system audio unless the product flow clearly requests it.
- Prefer system frameworks and existing command-line tools over adding runtime dependencies.
- Keep temporary media bounded and document any new retention behavior.
- Use clear, accessible labels and respect macOS appearance, contrast, and motion preferences.
- Add focused documentation when changing commands, permissions, supported file formats, or user data handling.

## Capture and handoff checks

The explicit MCP share action keeps the latest brief in `~/Library/Caches/Poach/active-brief.json` and writes each share to `~/Library/Caches/Poach/briefs/<uuid>.json`. Preserve the latest-brief format for callers that omit an ID, and resolve a supplied brief ID to its archived file. Keep files user-only (`0700` directories, `0600` brief files). All shared briefs expire after 24 hours; expired archives are removed when read by ID, while only the app replaces the latest snapshot, and media referenced by any unexpired brief must remain protected from storage cleanup. Document any changes to this validity period. Native screen recordings also sample pointer position and mouse-button state at a nominal 120 Hz while capture is active, capped at 5,000 events; coordinates and timestamps are relative to the captured bounds and recording start. Include sample, in-bounds, and held-button counts so an empty event list can be distinguished from a sampler that never ran. The copied handoff must reflect the trace actually present and must not promise click/drag observations when none were sampled. MCP derives sample-based click/drag candidates from these events and returns nearby actions from `poach_read_moment`. The brief includes bounded frame sequences for the three most recent releases inside the capture, with a final sample before the next drag or at clip end. Pointer polling can miss or misclassify brief actions, so correlate candidates with frames and user notes and never present inferred effects as recorded facts. The local trace has no keyboard or scroll data, uses no global event monitor or event tap, and is included only in an explicitly shared brief. Imported media does not receive a native pointer trace.

During selected-area recording, Poach shows a click-through dim mask and soft edge shadow outside the recorded rectangle; the capture filter excludes Poach windows so the overlay stays out of the saved video. Verify that the overlay follows the selected bounds, target clicks pass through, and no shadow pixels appear in the clip. The review window uses AVKit for local video playback. Playhead notes are included as timestamped text and structured annotations in the explicitly shared snapshot, so users can label observed actions in their own words. The pointer trace records sampled movement, button down/up transitions, and drag samples; it does not claim to infer intent. Poach does not call an LLM API; the connected assistant interprets the capture evidence.

`poach_read_moment` accesses the latest explicitly shared video by default or a selected brief when given its ID, enforcing the same 24-hour validity period. It returns reference pixels directly, without retaining additional image files. Keep this scope when extending assistant inspection.

When validating automatic stop, let a native capture reach the full 30-second limit and verify the resulting clip with ffprobe. ScreenCaptureKit shutdown can add extra frames; the app uses `inspectRecording` to trim that overrun, while file imports use the strict `inspectVideo` limit. Confirm the returned source path points to the trimmed clip so playback and MCP moments use the same timeline.

Run `pnpm --filter @poach/core test` for the recording boundary regression. It requires FFmpeg/ffprobe, generates a synthetic 31.5-second clip, verifies normalization to 30 seconds and final-moment access, and checks that the import limit remains strict. Fixtures and extracted images are temporary and removed after the test.

Run `pnpm --filter @poach/mcp-server test` to verify assistant handoff through a real MCP stdio client. This test uses an isolated temporary HOME, synthetic video and brief; it checks notes, color instructions, images, timestamp bounds, mismatched handoff IDs, and expiry without touching your active shared brief.

For capture diagnostics, use `log show --last 5m --style compact --predicate 'subsystem == "dev.poach.app" AND category == "CaptureLifecycle"'`. These macOS logs contain lifecycle milestones and numeric failure codes, not capture contents, notes, or source paths. A successful run reports selection requested, recording started, stop requested, file finalized, analysis completed, and review editor presented.

Shortcut validation: with Poach running, physically press Command–Shift–P from another app, verify selection opens, and cancel with Escape. Repeat during a recording to verify stop. Registration status is logged under subsystem `dev.poach.app`, category `HotKey`; status 0 confirms registration, not delivery. App-targeted synthetic keypresses are insufficient evidence of global shortcut delivery.

When checking assistant setup, verify the connector is available from the Settings tab and the review sheet. Verify **Copy handoff for chat** disables on disconnect and enables after initialization. Click both MCP copy buttons. Verify the Codex command quotes paths with spaces, the Claude JSON contains the poach server entry, and both buttons disable when the runtime is missing. The packaging script bundles the server and its JavaScript dependencies into the app. The connectors launch that server. To test portability, run `bash scripts/package-beta.sh`, move the archives outside the checkout, install the Codex marketplace with its included installer, and test both servers from their extracted locations.

When checking video comments, post at two different times, close and reopen the sidebar, and select the earlier comment. Verify the player seeks to that moment and both timestamps appear in the brief returned by `poach_read_brief` after choosing **Copy handoff for chat**.

Motion-analysis checks include stationary video. Verify that a quiet recording yields one resting frame, zero motion duration, and a null easing estimate in the assistant brief.

When changing the local dropzone benchmark, check the PNG success path, MP4 refusal, drag cancellation, and Replay in a browser. Use the benchmark server command below.

Run `pnpm run build:connectors` after MCP changes. To exercise the bundled server rather than the development entry point, set `POACH_TEST_SERVER` to the absolute path to the packaged server.mjs and run `node --test packages/mcp-server/test/handoff.test.mjs`. To exercise Claude, unpack the .mcpb and run the command from its manifest with Poach installed in Applications. The tests use synthetic media and an isolated Poach cache.

When changing storage cleanup, verify it with temporary fixtures. Cover native recordings, trimmed videos, generated frames, active handoff paths, the open edit, unrelated files, and symlinks. An unreadable shared brief must prevent deletion.

### Bundled tools

The Apple silicon beta includes official Node.js 22.23.4 and a local LGPL build of FFmpeg 8.1.3. `scripts/bundle-runtime.sh` verifies pinned archive digests, caches the build, and stages the executables and notices. Include the exact FFmpeg source archive and build script alongside beta downloads. Test inspection with only the bundled bin directory and macOS system directories on PATH. Both connector packages launch the app’s server from Applications or the current user’s Applications folder.

## Run the MCP server

Build first, then configure an MCP client to launch the server's compiled JavaScript. Example configuration:

```json
{
  "mcpServers": {
    "poach": {
      "command": "node",
      "args": ["/absolute/path/to/poach/packages/mcp-server/dist/index.js"],
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
      }
    }
  }
}
```

`poach_inspect` accepts an absolute `videoPath` and optional `outputDirectory`. It returns structured JSON with `keyframes`, `palette`, and `timing`. The MCP server only reads local video files and writes extracted PNGs; it does not upload recordings.

## Repository map

```text
apps/macos/          SwiftUI menu-bar app, capture service, and floating HUD
packages/core/       TypeScript frame extraction, motion analysis, and palette code
packages/mcp-server/ Local MCP server for media inspection and assistant handoff
scripts/             Local packaging helpers
```

## Local dropzone benchmark

From the project root, run `python3 -m http.server 8741 --bind 127.0.0.1 --directory apps/benchmark` and open [the local benchmark](http://127.0.0.1:8741/). Record the drop zone and both sample files using Poach’s **Screen area** mode. Drag **mood.png** into the target to see progress, or **demo.mp4** to see the size-limit response. **Replay** resets the demo. Both files and the progress indicator are simulated locally.

[Context meter](http://127.0.0.1:8741/context-meter.html) runs on the same benchmark server. Hover a category to isolate its token count. Use **Compact** and **Undo** to compare totals.


## Package and verify a release (authorized maintainers)

Run `bash scripts/package-beta.sh` to produce the app archive, Codex installer, Claude extension, FFmpeg source archive, build recipe, and `SHA256SUMS.txt` in `outputs/beta/`. Verify the packaged files with `cd outputs/beta && shasum -a 256 -c SHA256SUMS.txt`. Run `open outputs/Poach.app` to launch the local build. The capture shortcut is Command–Shift–P. For an installer upgrade check, register a copy of the old local marketplace in a temporary Codex home. Run the packaged installer twice and verify that Poach is enabled and points to the installed marketplace.

Only maintainers authorized by the repository owner may publish a release. Prepare release assets in a draft, verify them, then publish. Future releases are immutable once published. Use a new version for corrections. All tags require repository administrator access to create, update, or delete. The personal repository owner currently holds the only administrator account. GitHub also allows users with write access to manage releases, including releases for existing tags. Grant repository write access only to people explicitly authorized to publish. Keep workflow permissions read-only and review any credentials or GitHub App installation that requests contents write access.

### Smoke-test screenshot capture

On macOS 15 or later, switch to **Screenshot**, choose **Screen area**, **Full screen**, or **App window**, then click **Take screenshot…**. Capture a test surface and confirm that the editor opens with its still image and palette. For Screen area, the camera button or Return confirms the selection immediately. Check that Poach’s UI and pointer are absent from the PNG, Escape cancels the area selector, and **Clear unused captures** preserves the open screenshot and screenshots referenced by unexpired handoffs.
