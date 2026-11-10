# Handoff

## Current status

Branch `feat/optional-capture-timer` (local only, not pushed, no PR yet), rebased on `main` at `d8a23dd` (Poach 1.0, PR #5).

The optional capture timer and Poach-owned capture selection are implemented and build cleanly. The hands-on manual pass (all modes × Record/Screenshot × Off/3s/10s) and the final whole-branch review are still pending.

## What this branch does

- **Floating capture pill** (`Views/CapturePill.swift`) with only ⏱ · ● · ✕ (📷 for screenshots). ⏱ expands Off · 3s · 10s over the whole pill. The same pill stays through the countdown (only ✕ active) and the recording (only stop active; the edge fills over 30 s), replacing the old "Recording screen" panel and the countdown ✕.
- **Optional timer** for recordings and screenshots: Off (default), 3s, 10s. The last choice is stored in `UserDefaults` (`captureTimerSeconds`).
- **Poach-owned selection** for all three modes (`Capture/CaptureSelection.swift`). Apple's `SCContentSharingPicker` is gone: macOS hides other apps' windows while it is open, so no timer control could be shown there. Window mode highlights the window under the pointer; click or Tab chooses.
- **Click-through countdown** (`Capture/CaptureCountdown.swift`): only an outline and the number are shown, and clicks reach other apps. Esc is registered globally only while the countdown runs; the pill's ✕ and ⌘⇧P also cancel.
- Window selection reloads the window list when the active desk changes.
- **Space** starts from the pill and stops a recording only while the pill is focused (no global Space shortcut).
- `@preconcurrency import ScreenCaptureKit` fixes Swift 6.1 strict-concurrency build errors that also affect `main`.

Design: `docs/superpowers/specs/2026-11-09-optional-capture-timer-design.md`. Plan: `docs/superpowers/plans/2026-11-09-optional-capture-timer.md`.

## Next steps

1. Manual pass on the built app (see the plan's Task 5, Step 4 and Review Focus), including the new pill UI.
2. Final whole-branch review, then open a PR.

## Open questions and decisions

- A global Space shortcut to stop recording was deferred by the user ("for now"); ⌘⇧P is the global stop.
- During a countdown, Esc cancels the capture instead of closing menus in other apps (accepted trade-off).
- The timer is opened with **T** in the selection overlay, because Tab is used to cycle displays and windows.

## How to run and test

```sh
swift build --package-path apps/macos
bash scripts/test-capture-selection.sh
bash scripts/test-pointer-trace-buffer.sh
bash scripts/build-macos-app.sh   # creates outputs/Poach.app
```

Capture requires macOS 15 and Screen Recording permission.
