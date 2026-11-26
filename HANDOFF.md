# Handoff

## Current status

Current branch: `feat/home-window-redesign`, on top of `feat/optional-capture-timer` (both local only, not pushed, no PR yet). On 2026-11-26 it was rebased onto `main` at `2b1e440` (the v1.0.0 release). Replaying it linearly dropped its earlier merges of main, so `1263984` restores the result of merging the old tip with main. The pre-rebase tip is kept as `backup/home-window-redesign-pre-rebase`; delete it once the rebased branch has been checked by hand.

Building now needs a full Xcode (26.6 is installed) so `actool` compiles the Liquid Glass icon, and the Apple Development certificate is used for signing automatically.

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

- **Area pill:** in Screen area mode the capture pill appears only after a drag ends with a valid area (32 × 32 pt or more), centred on the area and 12 pt away from its outline: below it, or above it when there is no room, or just inside its bottom edge when the area fills the screen. It has no outline of its own: the drop's white ring fades out as the pill appears. It enters with `CapturePillDropIn`, after Poach brief `EA0756C8…`: in one continuous, accelerating move (a single ease-in path from the outline to the pill's centre, so it never stops on the way) the outline swells into a wide, flat lobe that rounds into a drop on a stretching neck and pinches off about 80% along the path (a metaball: a `Canvas` with blur and an alpha threshold, drawn only on the pill's side of the outline), and the drop stretches as it keeps falling; squashes on landing, then spreads sideways while its height catches up a beat later, settling with a small wobble (about 4% overshoot) while its white fades and the glass shows through, then the buttons fade in (`CapturePill.controlsOpacity`). About 0.8 s in all (0.30 s travel, 0.38 s spread, 0.12 s button fade), shortened at the user's request. Reduce Motion shows the pill at once. The drop-in was checked frame by frame in a throwaway window. The user chose the gap over touching the outline because a pill wider than the area looked wrong when attached. Starting a new drag hides it. The countdown and recording pills stay in that same spot (`CapturePillLayout.panelFrame(attachedTo:on:)`); full screen and app window keep the bottom-centre pill. The rule is `CaptureTargetGeometry.attachedPillFrame`, covered by `bash scripts/test-capture-selection.sh`. The first version never showed the pill because the drag-end handler skipped area mode; fixed in `68a8d97`. Still not checked by hand after the fix: the overlay could not be driven by automation.

## What the timer branch does

- **Floating capture pill** (`Views/CapturePill.swift`) with only ⏱ · ● · ✕ (📷 for screenshots). ⏱ expands Off · 3s · 10s over the whole pill. The same pill stays through the countdown (only ✕ active) and the recording (only stop active; the edge fills over 30 s), replacing the old "Recording screen" panel and the countdown ✕. It sits at the bottom centre of the screen, like main's selection controls.
- **Optional timer** for recordings and screenshots: Off (default), 3s, 10s. The last choice is stored in `UserDefaults` (`captureTimerSeconds`).
- **Area and full screen** use Poach's own overlay (`Capture/CaptureSelection.swift`) with the pill.
- **App window** uses main's preview grid (`Capture/WindowCaptureChooser.swift`, from `507bd90`); its footer is now the same pill. The countdown runs after the choice, then the window is checked again and the capture fails with "That window is no longer available." if it was closed or minimized. When Screen Recording access is denied, the system single-window picker is the fallback (main's behavior).
- **Click-through countdown** (`Capture/CaptureCountdown.swift`): only an outline and the number are shown, and clicks reach other apps. Esc is registered globally only while the countdown runs; the pill's ✕ and ⌘⇧P also cancel.
- **Timer selector** (`CaptureTimerLensPicker` in `Views/CapturePill.swift`), after Poach brief `FDBFE307…`: Off · 3s · 10s on one track. At rest the choice sits on a soft white thumb (near-black label, the others grey). Pressing lifts the thumb into a larger, almost clear lens with a bright rim that follows the pointer; the option under it becomes the choice at once, and releasing settles it back with a spring. The user wants the lens only here, because this is the one selector; the capture pill's buttons are utilities and have no lens. While lifted, the lens refracts the labels: magnified 1.22× inside, bent harder (1.6×, slightly blurred) along a 6 pt rim band; drawn with masked, scaled copies of the labels, not a shader. Not seen in motion: the drag cannot be automated here.
- **Timer button icon:** with Off it shows ⏱; with 3s or 10s it shows a stopwatch outline with the seconds centred inside, in the same bold system face as the Off · 3s · 10s options (`CaptureTimerGlyph`).
- **Closing the timer options:** they shrink into the ⏱ button's capsule while the labels slide left and fade (`TimerOptionsCollapse`). Opening still grows them out from the left. Checked by building only; the pill appears only during a capture, so the motion still needs a look by hand.
- **Glass pill, after the iOS 26 tab bar (Poach brief `DECBF599…`):** the pill is a thin behind-window blur (70% opacity) with a light 12% white wash and a soft shadow, edged like glass rather than outlined: a specular highlight on the top edge that fades down the sides, a faint blurred spectral fringe around the rim, and a small inner glint (`CapturePillGlass`, `CapturePillGlassEdge`); inside the window chooser it blurs that window instead (`capturePillBlending`). ⏱ and ✕ are bare icons; the white ● stays raised, and an active timer keeps its orange capsule. The pill's own panels are 16 pt larger on every side (`CapturePillLayout.panelFrame`) so the timer lens and the shadow are not clipped. The glass was checked in a throwaway window. A press lens on the three buttons was tried and removed at the user's request.
- **Record button** is white with a red circle; while recording, stop is red with a white square.
- **Space** starts from the pill and stops a recording only while the pill is focused (no global Space shortcut).
- Swift 6.1 build fixes: `@preconcurrency import ScreenCaptureKit`, and a split expression in `PoachFontMatcher.swift` (`f9d4c47`). `main` itself does not build on Swift 6.1 without these.

Design: `docs/superpowers/specs/2026-11-09-optional-capture-timer-design.md`. Plan: `docs/superpowers/plans/2026-11-09-optional-capture-timer.md`. The spec predates the merge: its pointer-hover window selection was replaced by the preview grid.

## Next steps

1. Manual pass on the built app: area / full screen / app window × Record / Screenshot × Off / 3s / 10s; Esc, ✕ and ⌘⇧P during a countdown; the menu bar's New Screenshot / New Recording with a timer set.
2. Final whole-branch review, then open a PR.

## Open questions and decisions

- A glass UI after github.com/Z1Code/glass-refraction was tried and reverted at the user's request; the main windows stay opaque. The capture pill alone is glass, at the user's request (2026-11-16).
- **Toolchain:** Command Line Tools 26.6 are installed (Swift 6.3.3, macOS 26.5 SDK); a clean build has no errors or warnings. On macOS 26 the pill's background is Liquid Glass (`glassEffect(.regular, in: Capsule())`) and the lifted timer lens is clear Liquid Glass under the labels; macOS 14 and 15 keep the `NSVisualEffectView` glass and the faked lens refraction (`CapturePillLegacyGlass`). Building with the macOS 26 SDK also opts the windows into the macOS 26 look, so the home window has the system's rounder corners even though our own rounder-corner attempt was reverted. The design lab has a **Pill** surface over a busy backdrop for checking the glass. Xcode 26.6 is now installed too; it changes the build (compiled icon, Apple Development signing) but not the glass, which the macOS 26 SDK and the OS provide either way.
- **Liquid Glass limits (macOS 26):** the pill glass is forced to the light scheme (`.environment(\.colorScheme, .light)`), otherwise it turns dark over dark windows or in Dark Mode and the dark icons disappear. The public glass (`glassEffect` `.regular`/`.clear`, `NSGlassEffectView`) blurs what is behind heavily and bends only a thin rim, whether the backdrop is in the same window or another app; a test app over dark text showed no variant that keeps the background sharp with a strong lens like iOS. The lifted timer lens is 64 pt tall and overhangs the pill; `TimerOptionsCollapse` only masks while the options fold away.
- **System glass experiment (`feat/pill-native-glass`, from this branch):** `CapturePillStyle` (key `capturePillStyle`) adds `unified` on macOS 26 next to the shipped `custom` pill, which stays the default. `unified` gives each button its own interactive glass and merges them into one capsule with `glassEffectUnion`; its ⏱ button and the timer options share a `glassEffectID`, its glass is not forced light, and its icons are `.primary`. A `split` style (separate `.glass` buttons) and the system segmented control for the timer were tried and dropped at the user's request: the user prefers `unified` and `custom`. Finding: in an inactive app macOS drops the colour of `.glassProminent` and of `Glass.tint`, and the pill always shows while another app is active (⌘⇧P keeps it frontmost), so the primary button paints its red or ink itself. **Timer lens:** in both styles, opening the timer slims the pill's glass to a 36 pt track (`CapturePillLayout.optionsTrackHeight`) and the chosen option rests under a clear capsule lens, 52 pt tall and 1.65 options wide, that stands out of the pill above, below and past the ends, after a reference the user shared. The lens is only a thin rim, bright at the top-left and bottom-right, with a grey edge on the light pill; a clear Liquid Glass fill was tried and dropped because it became an opaque grey patch over dark backgrounds. Labels use `.primary`/`.secondary`, so they follow the unified pill into Dark Mode; the custom pill forces light content as well as light glass. Pressing still lifts the lens a little larger. In the unified pill the slim glass is applied to the options with `CenteredCapsule`; as a background inside the `GlassEffectContainer` it was drawn over the labels. Checked in the design lab (Pill surface, **Pill glass** picker); the morph animation still needs a look by eye. A process started from the shell stays inactive even with `NSApp.activate()`, and extra launch arguments stop the lab window from opening; set the surface and style with `defaults write Poach …` instead.

- A global Space shortcut to stop recording was deferred by the user ("for now"); ⌘⇧P is the global stop.
- During a countdown, Esc cancels the capture instead of closing menus in other apps (accepted trade-off).
- The selection overlay registers Esc globally too (`CaptureSelectionWindowController.escape`, unregistered in `finish`). macOS keeps the previous app active after ⌘⇧P, so a view-level Esc never fired; and in Screen area mode the pill's ✕ shortcut only exists after a drag. Esc closes the timer options first, then cancels. Checked in the built app: ⌘⇧P from Finder, then Esc, closes the overlay.
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
