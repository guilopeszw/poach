# Optional capture timer and Poach-owned screen/window selection

Date: 2026-11-09
Branch: `feat/optional-capture-timer`

## Intent

Today every recording waits through a forced three-second countdown. Screenshots, added on `main` in `95c7722` (PR #5), have no timer at all. The user wants to choose the delay when starting a capture, like a camera timer, and wants the default to be no delay.

The timer control must live in the capture selection UI itself. That works for **Screen area**, which already uses a Poach overlay. **Full screen** and **App window** currently use Apple's `SCContentSharingPicker`. Its top bar ("Compartilhar Tela Inteira", "Cancelar", "Compartilhar…") is drawn by macOS. Poach cannot add controls to it, and testing showed macOS also hides other apps' windows while the picker is open (a panel at window levels 200, 498, 499 and 1000 was reported off-screen). The user therefore decided to replace the system picker with Poach-owned selection for all three modes, so the timer sits in the same place everywhere.

## Goals

- A camera-style timer with three values: **Off**, **3s**, **10s**. No 5s.
- The timer applies to **both recordings and screenshots** (user decision, 2026-11-10), as on a camera.
- **Off is the default.** With Off, recording starts as soon as the user confirms.
- The same control in all three capture modes, in the same Poach selection panel.
- **Full screen** and **App window** selection handled by Poach, not by `SCContentSharingPicker`.
- **App window** selection: the window under the pointer is highlighted and selected with a click (like ⌘⇧4 then Space). Cancel with Esc or ✕.

## Non-goals

- Timer values other than Off, 3s and 10s, or a custom value.
- Picking hidden or minimized windows. The user brings the window forward first.
- Audio, longer clips, or any change to the 30-second limit.
- Localizing the Poach UI. It stays in English.

## Anti-goals

- Anything that makes a capture start with a countdown when the user chose Off.
- A selection UI where it is unclear what will be recorded. The system picker used to make this obvious; the Poach highlight now has to.
- Any new network transmission, analytics, or retention of captures (see `AGENTS.md`).

## Decided by the user

### Timer control (all modes)

- Collapsed: a round button with a timer icon. Grey when Off, orange (Poach's take on the iOS yellow) when 3s or 10s.
- Clicking it expands inline into **Off · 3s · 10s** with the current value highlighted. Choosing a value collapses it. This mirrors the iOS Camera timer.
- Panel button order is **⏱ · ● · ✕** (timer, record, cancel). Record comes before cancel. For screenshots the middle button is the existing dark camera button: **⏱ · 📷 · ✕**.
- In the narrow selection panel, the expanded options temporarily replace ● and ✕.

### Full screen

- Same pattern as Screen area: the screen is dimmed, and the selection panel (⏱ · ● · ✕) appears in the existing corner position (left or right edge, from the `windowEdge` setting).
- With several displays, the display under the pointer is the selected one and is visibly highlighted.

### App window

- Hovering highlights the window under the pointer. Clicking selects it. The panel then confirms with ● (start, honouring the timer) or cancels with ✕ / Esc.

### During the countdown: the screen is free

- The point of the timer is to let the user prepare the screen (open a menu, hover something, focus another app). So when the countdown starts, the dimming goes away and the overlay stops catching clicks (`ignoresMouseEvents`). Only an outline of the chosen target (area, display or window) and the countdown number stay visible.
- Esc cancels the countdown even when another app has focus (user decision). Poach registers Esc as a global hotkey only while the countdown runs and unregisters it the moment the countdown ends or is cancelled. ✕ on the countdown UI and ⌘⇧P also cancel.
- Known consequence: during the countdown, Esc pressed to close a menu in another app cancels the capture instead and does not reach that app.
- This applies to all three modes, including the Screen area flow already built on this branch, which currently blocks the screen during the countdown and has to be reworked.

### Screenshots

- Screenshots use the same Poach-owned selection (area, display, window) and the same timer, countdown and cancel rules as recordings.
- The countdown overlay (outline, number, ✕) is fully closed before the image is captured, so it never appears in the screenshot. The same applies to the first recorded frame.
- Space starts a screenshot from the selection panel, like Return and the camera button.

### Space bar

- **Start:** in the selection panel (all three modes), Space starts the capture exactly like Return and ●, honouring the timer.
- **Stop:** Space stops the recording only while Poach's "Recording screen" panel has keyboard focus (for example after clicking it). There is no global Space shortcut, because it would swallow every space typed into the app being recorded. ⌘⇧P stays the global way to stop.
- The user accepted this split "for now". A global Space stop may be revisited later.

## Builder's calls (made by Claude; the user can override)

- The last timer choice is remembered across captures and launches (`UserDefaults` key `captureTimerSeconds`). The first launch starts at Off.
- One timer value is shared by all three modes.
- Keyboard and VoiceOver: the timer button is labelled "Timer" with value "Off" / "3 seconds" / "10 seconds". When expanded, Left/Right change the value, and Return or Esc collapse it. Esc while expanded collapses the options instead of cancelling the capture.
- The record button's help text reflects the timer: "Start recording (Return)" for Off, otherwise "Start the 3 seconds countdown (Return)".
- Remove the macOS < 15.2 `chooseDisplay` `NSAlert` fallback and the `SCContentSharingPicker` code, since nothing uses them after this change. Capture still requires macOS 15 (unchanged), and importing files on macOS 14 is unaffected.
- No new permission: Screen area already needs Screen Recording access through `SCShareableContent`, and Full screen and App window now use the same path.
- Poach's own windows stay excluded from display captures (as today) and are never offered as window targets.
- When the timer is on, the countdown shows the existing `PoachCountdown` visual next to the chosen target's outline, in a click-through overlay, with a separate small clickable ✕. `RecordingStatusWindowController.countDown` goes away, unless the builder finds reusing its small panel for the ✕ simpler.
- Keyboard-only target choice in Full screen and App window: Tab cycles through the available displays or windows and highlights each one, VoiceOver announces the app and window title (or the display name), and Return chooses. Pointer hover and click keep working.

## Already built on this branch

- Rebased onto `main` at `d8a23dd` (PR #5, Poach 1.0, which added screenshots and moved selection into `ScreenCaptureService.selectTarget(mode:screenshot:)`).
- Committed: `@preconcurrency import ScreenCaptureKit`, which fixes Swift 6.1 strict-concurrency errors that also break `main`.
- Uncommitted: `Views/CaptureTimerControl.swift` (`PoachCaptureTimer` and `PoachCaptureTimerControl`). The earlier Screen area wiring was written against pre-1.0 code and is kept only as a reference stash; it is redone on top of the new code.
- The floating panel over the system picker was proven not to work and is not carried over.

## Left to the builder

- How to find the window under the pointer. For example, use `CGWindowListCopyWindowInfo` front-to-back order to pick the frontmost layer-0 window at the pointer, then match it to an `SCWindow` by `windowID`. Build the filter with `SCContentFilter(desktopIndependentWindow:)`.
- The highlight's exact look (outline, tint), as long as it clearly shows what will be recorded and matches the Screen area overlay.
- How to structure the overlay code: extend `RegionSelectionWindowController` or add sibling controllers.
- Pointer-trace bounds for window captures (`pointerCaptureBounds`): keep using `filter.contentRect`.

## Docs to update

Per `AGENTS.md`, update `README.md` and `CONTRIBUTING.md` where capture behaviour is described: the optional timer, and that Full screen and App window are now chosen in Poach. Create `HANDOFF.md`, which the repo does not have yet.

## Verification

- `swift build --package-path apps/macos` passes.
- Manual, on the built app, for each mode and for both Record and Screenshot, with Off, 3s and 10s: Off starts immediately; 3s and 10s count down, and the countdown can be cancelled with Esc or ✕; the last choice is remembered.
- Window mode: the highlight follows the pointer across windows and displays, Poach's own windows are never offered, and the recording contains only the chosen window.
- Space starts from the selection panel; Space stops only when the recording panel is focused; typing spaces in other apps during a recording does nothing to Poach.
- Keyboard only: Tab reaches the timer, arrows change it, Return starts, Esc cancels. In window/display mode, Tab cycles targets. VoiceOver reads the labels above.
- During a 10s countdown, clicks reach the apps underneath, and Esc (with another app focused), ✕ or ⌘⇧P cancels. After the countdown, Esc reaches other apps normally again.
