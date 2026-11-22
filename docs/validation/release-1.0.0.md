# Poach 1.0.0 release validation — 2026-11-22

Published [Poach 1.0.0](https://github.com/guilopeszw/poach/releases/tag/v1.0.0) from `dcf97349c78c604859408bbb159891806a544e2e` (main after PRs #20–26). The pre-existing draft was refreshed; no previously published release or tag was replaced.

- Rebuilt the release Swift app, core, bundled MCP server and connector archives with `scripts/package-beta.sh`.
- Core 7/7, MCP 5/5, Chrome 7/7 and workspace typechecks passed. Packaged-server handoff tests passed 3/3.
- Downloaded the draft assets with maintainer credentials into an isolated directory, verified all five asset SHA-256 values, extracted the app/connectors, checked all three packaged versions equal 1.0.0, and verified the app's deep strict signature.
- Launched the extracted app and confirmed it remained running; stopped only that test-owned process afterward.
- Ran the repository smoke protocol through both downloaded connector launchers using only bundled tools and system PATH. Inspection, brief images, annotations, pointer actions and timestamp reads passed.
- Used the real Codex CLI with isolated home/config directories. Migrating an existing local marketplace registration and running the downloaded installer twice passed; the Poach plugin was installed and enabled at version 1.0.0. The user's connector configuration was not changed.
- Native ScreenCaptureKit, Retina/downscaled dimensions, saved evidence and five stop-to-editor measurements are recorded in [native validation](native-2026-11-21.md); the released application code is identical to that tested code.

The initial hosted smoke attempt could not see the draft with its read-only Actions token (`release not found`); this was a draft-access limitation. Equivalent downloaded-asset checks passed locally before publication. The public hosted rerun [45046083625](https://github.com/guilopeszw/poach/actions/runs/45046083625) passed: asset downloads/checksums, package versions, app launch, signature verification and both connector smoke tests.

This release uses the existing local development signature, has no Apple Team ID, and is not notarized. Gatekeeper may require Open Anyway, and native capture requires Screen Recording permission and restart. On macOS 26 permission may need reauthorization after replacing builds. No audio, telemetry or media upload was added.
