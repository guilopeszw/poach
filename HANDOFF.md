# Handoff

## Current status

Current branch: `feat/home-window-redesign`, on top of `feat/optional-capture-timer` (both local only, not pushed, no PR yet). `origin/main` up to `f11d220` is merged in (`a07395f`).

The optional capture timer, the floating capture pill and the merge with main build cleanly and pass the scripted tests. The hands-on manual pass and the final whole-branch review are still pending.

## Home window: capture toggles (`feat/home-window-redesign`)

This branch starts from `feat/optional-capture-timer`. Both are local and not pushed. Merge the timer branch first.

- The capture type (Record, Screenshot) and the capture source (Screen area, Full screen, App window) are sliding toggles. They copy the toggle recorded in Poach brief `9AFBB955…`. A white thumb with a 1 pt grey edge and a soft shadow sits on a light grey track. The active label is semibold near-black, and the others are grey.
- The labels change as soon as you click. Only the thumb moves, over 251 ms with `cubic-bezier(0.16, 1, 0.3, 1)`. With Reduce Motion on, it jumps without animating. The code is the pill style of `PoachSegments` in `Views/PoachControls.swift`.
- The source toggle keeps the original card size. It has three equal 44 pt cells with the icon above the title (`stacked: true`). The type toggle is one 26 pt row, and it hides its icons when a title would otherwise be cut off.
- I checked both toggles in the design lab at 800 pt and 320 pt, and captured frames while the thumb was moving. The header tabs keep their underline.
- I tried a wider redesign with three corner radii, capsule controls and a drop target covering the whole window. The user asked to revert it, so the rest of the UI matches the timer branch.

## What the timer branch does

- **Floating capture pill** (`Views/CapturePill.swift`) with only ⏱ · ● · ✕ (📷 for screenshots). ⏱ expands Off · 3s · 10s over the whole pill. The same pill stays through the countdown (only ✕ active) and the recording (only stop active; the edge fills over 30 s), replacing the old "Recording screen" panel and the countdown ✕. It sits at the bottom centre of the screen, like main's selection controls.
- **Optional timer** for recordings and screenshots: Off (default), 3s, 10s. The last choice is stored in `UserDefaults` (`captureTimerSeconds`).
- **Area and full screen** use Poach's own overlay (`Capture/CaptureSelection.swift`) with the pill.
- **App window** uses main's preview grid (`Capture/WindowCaptureChooser.swift`, from `507bd90`); its footer is now the same pill. The countdown runs after the choice, then the window is checked again and the capture fails with "That window is no longer available." if it was closed or minimized. When Screen Recording access is denied, the system single-window picker is the fallback (main's behavior).
- **Click-through countdown** (`Capture/CaptureCountdown.swift`): only an outline and the number are shown, and clicks reach other apps. Esc is registered globally only while the countdown runs; the pill's ✕ and ⌘⇧P also cancel.
- **Timer lens** (`CaptureTimerLensPicker` in `Views/CapturePill.swift`): Off · 3s · 10s on one track; pressing lifts a lens that follows the pointer, releasing settles it with a spring. Modeled on an iOS glass tab bar (Poach brief `6CA090EC…`).
- **Record button** is white with a red circle; while recording, stop is red with a white square.
- **Space** starts from the pill and stops a recording only while the pill is focused (no global Space shortcut).
- Swift 6.1 build fixes: `@preconcurrency import ScreenCaptureKit`, and a split expression in `PoachFontMatcher.swift` (`f9d4c47`). `main` itself does not build on Swift 6.1 without these.

Design: `docs/superpowers/specs/2026-11-09-optional-capture-timer-design.md`. Plan: `docs/superpowers/plans/2026-11-09-optional-capture-timer.md`. The spec predates the merge: its pointer-hover window selection was replaced by the preview grid.

## Next steps

1. Manual pass on the built app: area / full screen / app window × Record / Screenshot × Off / 3s / 10s; Esc, ✕ and ⌘⇧P during a countdown; the menu bar's New Screenshot / New Recording with a timer set.
2. Final whole-branch review, then open a PR.

## Open questions and decisions

- A glass UI after github.com/Z1Code/glass-refraction was tried and reverted at the user's request; the app stays opaque white.

- A global Space shortcut to stop recording was deferred by the user ("for now"); ⌘⇧P is the global stop.
- During a countdown, Esc cancels the capture instead of closing menus in other apps (accepted trade-off).
- The timer is opened with **T**, because Tab cycles displays in the overlay.

## How to run and test

```sh
swift build --package-path apps/macos
bash scripts/test-capture-selection.sh
bash scripts/test-font-matcher.sh
bash scripts/test-pointer-trace-buffer.sh
bash scripts/build-macos-app.sh   # creates outputs/Poach.app
```

If the build fails with a module-cache path error after the repository moves, run `swift package --package-path apps/macos clean`.

Capture requires macOS 15 and Screen Recording permission.
