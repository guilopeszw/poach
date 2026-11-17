# Handoff

## Current status

Current branch: `feat/home-window-redesign`, on top of `feat/optional-capture-timer` (both local only, not pushed, no PR yet). `origin/main` up to `f11d220` is merged in (`a07395f`).

The optional capture timer, the floating capture pill and the merge with main build cleanly and pass the scripted tests. The hands-on manual pass and the final whole-branch review are still pending.

## Home window: capture toggles (`feat/home-window-redesign`)

This branch starts from `feat/optional-capture-timer`. Both are local and not pushed. Merge the timer branch first.

- The capture type (Record, Screenshot) and the capture source (Screen area, Full screen, App window) are sliding toggles. They copy the toggle recorded in Poach brief `9AFBB955…`. A white thumb with a hairline (0.5 pt) grey edge and a faint, tight shadow (4% black, 1 pt blur) sits on a light grey track. The active label is semibold near-black, and the others are grey.
- The thumb glides on a critically damped spring (`.smooth(duration: 0.38)`), which keeps its speed when clicks interrupt each other, and the label colours fade over 0.2 s. The user asked for this to be smoother than the reference's 251 ms ease-out. With Reduce Motion on, it jumps without animating. The code is the pill style of `PoachSegments` in `Views/PoachControls.swift`.
- The source toggle keeps the original card size. It has three equal 44 pt cells with the icon above the title (`stacked: true`). The type toggle is one 26 pt row with rounded-rectangle corners (8 pt on the thumb, 11 pt on the track), not a capsule, and it hides its icons when a title would otherwise be cut off.
- The home window keeps 16 pt margins and 8 pt gaps between the capture controls; it is 324 pt tall so the bottom margin is also 16 pt. Matching the gaps and margins (16 pt gaps, then 8 pt margins) was tried and reverted at the user's request.
- Rounder window corners (an empty compact toolbar) were tried and reverted at the user's request; the window keeps the system corners.
- The drop card has a dashed outline while idle and a solid one while a file hovers over it. Its corners are 9 pt, matching the Record button.
- The upload icon in the drop card has no grey fill behind it.
- **Paste on the home window:** ⌘V on the Capture tab opens the clipboard like a drop (`PoachPastedMedia` in `App/PoachImportMedia.swift`). One copied image or video file opens as is. Raw image data, such as a ⌃⇧⌘4 screenshot, is saved as `screenshot-<UUID>.png` (mode 0600) in the temporary Poach folder, so **Clear unused captures** covers it. Errors appear in the drop card. Tested with `bash scripts/test-pasted-media.sh` and once by hand in the built app.
- The drop card's icon sits 4 pt above its title, and its hint reads "or click to browse · ⌘V to paste".
- I checked both toggles in the design lab at 800 pt and 320 pt, and captured frames while the thumb was moving. The header tabs keep their underline.
- I tried a wider redesign with three corner radii, capsule controls and a drop target covering the whole window. The user asked to revert it, so the rest of the UI matches the timer branch.

- **Area pill:** in Screen area mode the capture pill appears only after a drag ends with a valid area (32 × 32 pt or more), centred on the area and attached to its outline: below it, or above it when there is no room, or just inside its bottom edge when the area fills the screen. Its edge overlaps the outline by 1 pt and gets the same 2 pt white stroke, so they read as one shape. Starting a new drag hides it. The countdown and recording pills stay in that same spot (`CapturePillLayout.panelFrame(attachedTo:on:)`); full screen and app window keep the bottom-centre pill. The rule is `CaptureTargetGeometry.attachedPillFrame`, covered by `bash scripts/test-capture-selection.sh`. The first version never showed the pill because the drag-end handler skipped area mode; fixed in `68a8d97`. Still not checked by hand after the fix: the overlay could not be driven by automation.

## What the timer branch does

- **Floating capture pill** (`Views/CapturePill.swift`) with only ⏱ · ● · ✕ (📷 for screenshots). ⏱ expands Off · 3s · 10s over the whole pill. The same pill stays through the countdown (only ✕ active) and the recording (only stop active; the edge fills over 30 s), replacing the old "Recording screen" panel and the countdown ✕. It sits at the bottom centre of the screen, like main's selection controls.
- **Optional timer** for recordings and screenshots: Off (default), 3s, 10s. The last choice is stored in `UserDefaults` (`captureTimerSeconds`).
- **Area and full screen** use Poach's own overlay (`Capture/CaptureSelection.swift`) with the pill.
- **App window** uses main's preview grid (`Capture/WindowCaptureChooser.swift`, from `507bd90`); its footer is now the same pill. The countdown runs after the choice, then the window is checked again and the capture fails with "That window is no longer available." if it was closed or minimized. When Screen Recording access is denied, the system single-window picker is the fallback (main's behavior).
- **Click-through countdown** (`Capture/CaptureCountdown.swift`): only an outline and the number are shown, and clicks reach other apps. Esc is registered globally only while the countdown runs; the pill's ✕ and ⌘⇧P also cancel.
- **Timer lens** (`CaptureTimerLensPicker` in `Views/CapturePill.swift`): Off · 3s · 10s on one track; pressing lifts a lens that follows the pointer, releasing settles it with a spring. Modeled on an iOS glass tab bar (Poach brief `6CA090EC…`).
- **Timer button icon:** with Off it shows ⏱; with 3s or 10s it shows a stopwatch outline with the seconds centred inside, in the same bold system face as the Off · 3s · 10s options (`CaptureTimerGlyph`).
- **Closing the timer options:** they shrink into the ⏱ button's capsule while the labels slide left and fade (`TimerOptionsCollapse`). Opening still grows them out from the left. Checked by building only; the pill appears only during a capture, so the motion still needs a look by hand.
- **Glass pill, after the iOS 26 tab bar (Poach brief `DECBF599…`):** the pill is a light behind-window blur with a white wash, a bright top rim and a soft shadow (`CapturePillGlass`); inside the window chooser it blurs that window instead (`capturePillBlending`). ⏱ and ✕ are bare icons; the white ● stays raised, and an active timer keeps its orange capsule. Pressing anywhere on the row lifts a clear lens (62 × 58 pt, taller than the pill) that follows the pointer and enlarges the button under it; releasing over an enabled button triggers it (`CapturePillLens`). The real buttons stay underneath for shortcuts and VoiceOver. The pill's own panels are 16 pt larger on every side (`CapturePillLayout.panelFrame`) so the lens and shadow are not clipped. The glass was checked in a throwaway window; the lens drag still needs a look by hand. Hover tooltips on the three buttons no longer show, because the lens layer sits on top.
- **Record button** is white with a red circle; while recording, stop is red with a white square.
- **Space** starts from the pill and stops a recording only while the pill is focused (no global Space shortcut).
- Swift 6.1 build fixes: `@preconcurrency import ScreenCaptureKit`, and a split expression in `PoachFontMatcher.swift` (`f9d4c47`). `main` itself does not build on Swift 6.1 without these.

Design: `docs/superpowers/specs/2026-11-09-optional-capture-timer-design.md`. Plan: `docs/superpowers/plans/2026-11-09-optional-capture-timer.md`. The spec predates the merge: its pointer-hover window selection was replaced by the preview grid.

## Next steps

1. Manual pass on the built app: area / full screen / app window × Record / Screenshot × Off / 3s / 10s; Esc, ✕ and ⌘⇧P during a countdown; the menu bar's New Screenshot / New Recording with a timer set.
2. Final whole-branch review, then open a PR.

## Open questions and decisions

- A glass UI after github.com/Z1Code/glass-refraction was tried and reverted at the user's request; the main windows stay opaque. The capture pill alone is glass, at the user's request (2026-11-16).
- The SDK here is macOS 15.5, so the pill's glass uses `NSVisualEffectView` rather than macOS 26's Liquid Glass API. Revisit once the toolchain ships the macOS 26 SDK.

- A global Space shortcut to stop recording was deferred by the user ("for now"); ⌘⇧P is the global stop.
- During a countdown, Esc cancels the capture instead of closing menus in other apps (accepted trade-off).
- The timer is opened with **T**, because Tab cycles displays in the overlay.

## How to run and test

```sh
swift build --package-path apps/macos
bash scripts/test-capture-selection.sh
bash scripts/test-font-matcher.sh
bash scripts/test-pointer-trace-buffer.sh
bash scripts/test-pasted-media.sh
bash scripts/build-macos-app.sh   # creates outputs/Poach.app
```

If the build fails with a module-cache path error after the repository moves, run `swift package --package-path apps/macos clean`.

Capture requires macOS 15 and Screen Recording permission.
