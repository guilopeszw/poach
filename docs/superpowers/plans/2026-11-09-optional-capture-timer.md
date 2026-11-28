# Optional Capture Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pre-capture countdown optional (Off · 3s · 10s, default Off) for recordings and screenshots. Replace Apple's content-sharing picker with Poach-owned selection for Full screen and App window, so the timer lives in one panel for all three modes.

**Architecture:** Pure, Foundation-only logic (the timer model, window hit-testing, Tab cycling, coordinate conversion) lives in small files that are tested with `swiftc` precondition tests, following `scripts/test-pointer-trace-buffer.sh`. One AppKit selection controller returns a `CaptureTarget` for any mode. A separate click-through countdown controller runs after selection, with a temporary global Esc hotkey. `ScreenCaptureService` turns the target into an `SCContentFilter` and no longer touches `SCContentSharingPicker`.

**Tech Stack:** Swift 6 language mode (toolchain 6.1), SwiftUI + AppKit, ScreenCaptureKit, Carbon `RegisterEventHotKey`.

**Spec:** `docs/superpowers/specs/2026-11-09-optional-capture-timer-design.md`

## Global Constraints

- Timer values: exactly Off (0), 3s (3), 10s (10). Default Off. `UserDefaults` key `captureTimerSeconds`. Any other stored value reads as Off.
- Panel button order: ⏱ · ● · ✕ for recordings, ⏱ · 📷 · ✕ for screenshots (existing camera button). The expanded timer options temporarily replace ● and ✕.
- Timer accessibility: label "Timer", value "Off" / "3 seconds" / "10 seconds".
- Capture requires macOS 15 (unchanged). The package still targets macOS 14, and file import must keep working there.
- No new permissions, no network, no retention (`AGENTS.md`). Poach's own windows are never capture targets and stay excluded from display captures.
- The countdown overlay is closed before the screenshot or first frame is captured.
- Esc is registered as a global hotkey **only** while a countdown runs, and is unregistered on completion, cancel, or error.
- Space has no global registration. It starts from the selection panel, and stops only while Poach's recording panel is key.
- UI copy stays in English.
- Commits: Conventional Commits, no AI attribution trailer, and implementation and docs never in the same commit.

## Review Focus

1. **The window closes or moves between selection and the first frame** (especially after a 10s countdown). Expect a clear error alert ("That window is no longer available."), no crash or empty recording. → Task 5, Step 4.
2. **Secondary display with a different height or arrangement.** The countdown outline and number must sit on the chosen target, not offset. → Task 2 conversion test and Task 5, Step 4.
3. **⌘⇧P pressed during a countdown.** It must cancel, not be ignored or start a second capture. → Task 5, Step 4.
4. **The Esc hotkey leaks after an error.** For example, `SCShareableContent` throws after the countdown: Esc must work normally in other apps afterwards. → Task 3 (`defer`) and Task 5, Step 4.
5. **Non-window surfaces under the pointer:** menu bar, Dock, desktop, tiny utility windows, Poach overlays. They must never be offered as window targets. → Task 2 tests.

---

### Task 1: Timer model and camera-style control

**Files:**
- Create: `apps/macos/Sources/Capture/CaptureTimer.swift` (Foundation only)
- Modify: `apps/macos/Sources/Views/CaptureTimerControl.swift` (already exists, uncommitted; remove the enum from it and use the model)
- Create: `apps/macos/Tests/CaptureSelectionTests/CaptureSelectionTests.swift`
- Create: `scripts/test-capture-selection.sh`

**Interfaces:**
- Produces:
  - `enum PoachCaptureTimer: Int, CaseIterable, Identifiable { case off = 0, three = 3, ten = 10 }`
  - `static let storageKey = "captureTimerSeconds"`
  - `init(storedSeconds: Int)`: unknown values become `.off`
  - `var seconds: Int`, `var shortTitle: String` ("Off", "3s", "10s"), `var spokenTitle: String` ("Off", "3 seconds", "10 seconds")
  - `func stepped(by delta: Int) -> PoachCaptureTimer`, clamped (no wrap)
  - `static var current: PoachCaptureTimer`, read from `UserDefaults.standard`
  - `PoachCaptureTimerControl(isExpanded: Binding<Bool>, style: .light | .dark = .light, expandsLeading: Bool = false)`. Keep it as it is, but replace its private `step` with `stepped(by:)`.

- [ ] **Step 1: Write the failing tests** in `CaptureSelectionTests.swift`. Use a `@main enum CaptureSelectionTests` with `static func main()` and `precondition`s, like `PointerTraceBufferTests`:

```swift
precondition(PoachCaptureTimer(storedSeconds: 0) == .off)
precondition(PoachCaptureTimer(storedSeconds: 3) == .three)
precondition(PoachCaptureTimer(storedSeconds: 10) == .ten)
precondition(PoachCaptureTimer(storedSeconds: 5) == .off)
precondition(PoachCaptureTimer(storedSeconds: -1) == .off)
precondition(PoachCaptureTimer.off.stepped(by: 1) == .three)
precondition(PoachCaptureTimer.ten.stepped(by: 1) == .ten)
precondition(PoachCaptureTimer.off.stepped(by: -1) == .off)
precondition(PoachCaptureTimer.allCases.map(\.shortTitle) == ["Off", "3s", "10s"])
precondition(PoachCaptureTimer.three.spokenTitle == "3 seconds")
print("Capture timer model passed.")
```

- [ ] **Step 2: Create `scripts/test-capture-selection.sh`**, a copy of `scripts/test-pointer-trace-buffer.sh` that compiles `Sources/Capture/CaptureTimer.swift` together with the test file. Task 2 adds its source file to the same `swiftc` line.
- [ ] **Step 3: Run `bash scripts/test-capture-selection.sh`.** Expected: a compile failure ("cannot find 'PoachCaptureTimer'").
- [ ] **Step 4: Implement `CaptureTimer.swift`.** Move the enum out of `CaptureTimerControl.swift`, add `init(storedSeconds:)` and `stepped(by:)`, and switch the control's `timer` and `step` to the model.
- [ ] **Step 5: Run `bash scripts/test-capture-selection.sh`** (expected: "Capture timer model passed.") and `swift build --package-path apps/macos` (expected: "Build complete!").
- [ ] **Step 6: Commit** only the files above.

```bash
git add apps/macos/Sources/Capture/CaptureTimer.swift apps/macos/Sources/Views/CaptureTimerControl.swift apps/macos/Tests/CaptureSelectionTests scripts/test-capture-selection.sh
git commit -m "feat(macos): add camera-style capture timer control"
```

### Task 2: Window targets, cycling and coordinate conversion (pure)

**Files:**
- Create: `apps/macos/Sources/Capture/CaptureTargetGeometry.swift` (Foundation + CoreGraphics only)
- Modify: `apps/macos/Tests/CaptureSelectionTests/CaptureSelectionTests.swift`, `scripts/test-capture-selection.sh`

**Interfaces:**
- Produces:
  - `struct CaptureWindowCandidate: Equatable { let windowID: CGWindowID; let ownerPID: pid_t; let appName: String; let title: String; let frame: CGRect; let layer: Int }`. `frame` uses global top-left coordinates, as `CGWindowListCopyWindowInfo` reports.
  - `var spokenName: String`: "\(appName) — \(title)", or just `appName` when the title is empty.
  - `enum CaptureTargetGeometry` with:
    - `static let minimumWindowSide: CGFloat = 40`
    - `static func candidates(fromWindowInfo info: [[String: Any]]) -> [CaptureWindowCandidate]`: parses `kCGWindowNumber`, `kCGWindowOwnerPID`, `kCGWindowOwnerName`, `kCGWindowName`, `kCGWindowBounds` (via `CGRect(dictionaryRepresentation:)`) and `kCGWindowLayer`; skips entries missing number, pid or bounds; keeps the order.
    - `static func selectableWindows(_ frontToBack: [CaptureWindowCandidate], excludingPID: pid_t) -> [CaptureWindowCandidate]`: keeps `layer == 0`, both sides ≥ `minimumWindowSide`, and `ownerPID != excludingPID`, in the original order.
    - `static func window(at point: CGPoint, in selectable: [CaptureWindowCandidate]) -> CaptureWindowCandidate?`: the first candidate whose frame contains the point.
    - `static func cycledIndex(from current: Int?, count: Int, forward: Bool) -> Int?`: nil when `count == 0`; nil `current` gives 0 (forward) or `count - 1` (backward); wraps around.
    - `static func appKitRect(fromGlobalTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect`: `y = primaryScreenHeight - rect.maxY`; x, width and height unchanged.

- [ ] **Step 1: Write the failing tests**, appended to `main()`:

```swift
let poach: pid_t = 99
let front = CaptureWindowCandidate(windowID: 1, ownerPID: 10, appName: "Safari", title: "Apple", frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0)
let back = CaptureWindowCandidate(windowID: 2, ownerPID: 11, appName: "Xcode", title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0)
let menu = CaptureWindowCandidate(windowID: 3, ownerPID: 12, appName: "Menu", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 33), layer: 24)
let tiny = CaptureWindowCandidate(windowID: 4, ownerPID: 13, appName: "Tiny", title: "", frame: CGRect(x: 0, y: 0, width: 20, height: 20), layer: 0)
let mine = CaptureWindowCandidate(windowID: 5, ownerPID: poach, appName: "Poach", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 956), layer: 0)
let selectable = CaptureTargetGeometry.selectableWindows([mine, menu, tiny, front, back], excludingPID: poach)
precondition(selectable == [front, back])
precondition(CaptureTargetGeometry.window(at: CGPoint(x: 150, y: 150), in: selectable) == front)
precondition(CaptureTargetGeometry.window(at: CGPoint(x: 700, y: 500), in: selectable) == back)
precondition(CaptureTargetGeometry.window(at: CGPoint(x: 1400, y: 900), in: selectable) == nil)
precondition(front.spokenName == "Safari — Apple" && back.spokenName == "Xcode")
precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: true) == 0)
precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: false) == 2)
precondition(CaptureTargetGeometry.cycledIndex(from: 2, count: 3, forward: true) == 0)
precondition(CaptureTargetGeometry.cycledIndex(from: 0, count: 3, forward: false) == 2)
precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 0, forward: true) == nil)
// A window on a secondary display above the primary one (negative global y).
precondition(CaptureTargetGeometry.appKitRect(fromGlobalTopLeft: CGRect(x: 10, y: -1000, width: 200, height: 100), primaryScreenHeight: 956) == CGRect(x: 10, y: 1856, width: 200, height: 100))
let parsed = CaptureTargetGeometry.candidates(fromWindowInfo: [[
    kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 10, kCGWindowOwnerName as String: "Safari",
    kCGWindowName as String: "Apple", kCGWindowLayer as String: 0,
    kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 300, height: 200).dictionaryRepresentation
], [kCGWindowOwnerPID as String: 10]])
precondition(parsed.count == 1 && parsed[0].windowID == 7 && parsed[0].frame == CGRect(x: 1, y: 2, width: 300, height: 200))
print("Capture target geometry passed.")
```

- [ ] **Step 2: Add `CaptureTargetGeometry.swift` to the script's `swiftc` line and run it.** Expected: a compile failure.
- [ ] **Step 3: Implement `CaptureTargetGeometry.swift`** with the signatures above.
- [ ] **Step 4: Run the script.** Expected: both "passed" lines.
- [ ] **Step 5: Commit:** `feat(macos): add capture target hit-testing and cycling`.

### Task 3: Click-through countdown with temporary Esc hotkey

**Files:**
- Modify: `apps/macos/Sources/App/PoachHotKey.swift`
- Create: `apps/macos/Sources/Capture/CaptureCountdown.swift`

**Interfaces:**
- Consumes: `PoachCountdown(count:)` (`Views/PoachControls.swift`), `ScreenCaptureError.selectionCancelled`.
- Produces:
  - `PoachHotKey.init(keyCode: UInt32 = UInt32(kVK_ANSI_P), modifiers: UInt32 = UInt32(cmdKey | shiftKey), id: UInt32 = 1)`. The handler matches `identifier.id == self.id` instead of the literal `1`. `register(action:)` keeps its signature.
  - `PoachHotKey.unregister()`: idempotent. Calls `UnregisterEventHotKey` and `RemoveEventHandler`, then clears the state.
  - `@MainActor final class CaptureCountdownController { static let shared; private(set) var isRunning: Bool; func run(seconds: Int, outline: CGRect, on screen: NSScreen) async throws; func cancel() }`
    - `outline` uses AppKit global coordinates. Returns immediately when `seconds == 0`.
    - When cancelled (by `cancel()`, Esc or ✕), it throws `ScreenCaptureError.selectionCancelled`.

- [ ] **Step 1: Generalize `PoachHotKey`** as in Interfaces. The existing ⌘⇧P call site `PoachHotKey()` must compile unchanged.
- [ ] **Step 2: Implement `CaptureCountdownController.run`.**
  - Create one borderless `.screenSaver` panel per countdown, covering `screen.frame`, with `ignoresMouseEvents = true`, no dimming, and `.canJoinAllSpaces, .fullScreenAuxiliary`.
  - Draw a 2-pt white outline plus an outer 1-pt dark stroke around `outline`, and `PoachCountdown(count:)` centred in it, with the number changing each second.
  - Add a second, small clickable non-activating panel holding a 32×32 ✕ button (label "Cancel countdown"), placed just below the countdown circle.
  - Register `PoachHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 2)` at the start, and unregister it and close both panels in a `defer`.
  - Check for cancellation once per second, using the existing `Task.sleep` loop pattern.
- [ ] **Step 3: Run `swift build --package-path apps/macos`.** Expected: "Build complete!" The controller is unused until Task 5.
- [ ] **Step 4: Commit:** `feat(macos): add click-through capture countdown`.

### Task 4: Poach-owned selection for area, display and window

**Files:**
- Create: `apps/macos/Sources/Capture/CaptureSelection.swift`
- Modify: `apps/macos/Sources/Capture/ScreenCaptureService.swift`. Move `RegionSelectionWindowController`, `RegionSelectionPanel`, `RegionSelectionView`, `TransparentHostingView` and `SelectedRegion` out of it into the new file. `SelectedRegion` becomes internal (it is `private` today). Keep what PR #5 added to the area view: the `screenshot` flag (camera button and copy), clamping the drag to the screen, and `TransparentHostingView`.

**Interfaces:**
- Consumes: `PoachCaptureTimerControl`, `PoachCaptureTimer.current`, `CaptureTargetGeometry` and `CaptureWindowCandidate` (Task 2).
- Produces:
  - `struct SelectedRegion { let displayID: CGDirectDisplayID; let rect: CGRect }`. `rect` is screen-local with a top-left origin, as today.
  - `enum CaptureTarget { case area(SelectedRegion); case display(CGDirectDisplayID); case window(CaptureWindowCandidate) }`
  - `@MainActor final class CaptureSelectionWindowController { static let shared; func select(mode: PoachCaptureMode, screenshot: Bool) async throws -> CaptureTarget }`. Throws `.selectionCancelled` or `.noDisplay`. It no longer runs a countdown: `confirmSelection`'s countdown branch, `countdownValue` and `countdownTask` are removed from the view.

- [ ] **Step 1: Generalize the overlay.** Keep one `.screenSaver` panel per screen, as `RegionSelectionWindowController` does today, and render a mode-specific view.
  - **Shared bottom panel:** the existing white rounded panel, with ⏱ · ● · ✕ (⏱ · 📷 · ✕ when `screenshot`) (● and ✕ hidden while the timer is expanded). ● is disabled until there is a target. Return, Space and ● all start; Space works through a zero-opacity, `accessibilityHidden` button with `.keyboardShortcut(.space, modifiers: [])`. ✕ and Esc cancel, but Esc collapses the timer first when it is expanded (the logic that already exists).
  - ● help text: "Start recording (Return)" when Off, otherwise "Start the \(timer.spokenTitle) countdown (Return)" (already in the current area view; keep it).
  - **Area:** the current drag behaviour. Copy: "Drag to select an area" / "Ready to record".
  - **Display:** the screen under the pointer is the target. It is undimmed with a white 2-pt border; the other screens stay dimmed at 0.48. Tab and Shift-Tab cycle the screens with `cycledIndex`. Copy: "Record this screen". VoiceOver value: `NSScreen.localizedName`.
  - **Window:** when the overlay opens, read `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` → `candidates` → `selectableWindows(excludingPID: getpid())`. Do this **before** the overlay panels are ordered in.
    - Hovering highlights `window(at:)`: the screen is dimmed everywhere except that frame, plus a white 2-pt border.
    - A click locks the target until another window is clicked.
    - Tab and Shift-Tab cycle through `selectable` (front to back).
    - Copy: "Click a window to record" before there is a target, then the target's `spokenName`, truncated to one line.
- [ ] **Step 2: Point Screen area at the new API** in `ScreenCaptureService.selectTarget(mode:screenshot:)`: `case .area(let region) = try await CaptureSelectionWindowController.shared.select(mode: .selectedPortion, screenshot: screenshot)`. Full screen and App window keep their current picker code until Task 5.
- [ ] **Step 3: Run `swift build --package-path apps/macos` and `bash scripts/test-capture-selection.sh`.** Expected: both pass.
- [ ] **Step 4: Manual check** with `apps/macos/.build/debug/Poach`, in Screen area (until Task 5 lands, area captures run without any countdown): the panel shows ⏱ · ● · ✕, Space starts, Esc collapses the timer and then cancels, and with Off the capture starts immediately.
- [ ] **Step 5: Commit:** `feat(macos): add poach-owned capture target selection`.

### Task 5: Wire selection and countdown into capture; remove the system picker

**Files:**
- Modify: `apps/macos/Sources/Capture/ScreenCaptureService.swift`, `apps/macos/Sources/App/PoachApp.swift`
- Delete: `apps/macos/Sources/Capture/CaptureTimerOverlay.swift`

**Interfaces:**
- Consumes: `CaptureSelectionWindowController.select(mode:)`, `CaptureCountdownController.shared`, `CaptureTargetGeometry.appKitRect`.
- Produces: `func startRecording(mode: PoachCaptureMode) async throws` (the `beforeCapture` parameter is removed) and `func captureScreenshot(mode: PoachCaptureMode) async throws -> URL` (signature unchanged). Both go through `selectTarget(mode:screenshot:)`, which now selects, runs the countdown, then builds the filter.

- [ ] **Step 1: Rewrite `selectTarget(mode:screenshot:)`** (used by both `startRecording` and `captureScreenshot`).
  1. Select the target.
  2. Compute its outline and screen:
     - area: the conversion now inlined in `pointerCaptureBounds`;
     - display: `screen.frame`;
     - window: `appKitRect(fromGlobalTopLeft:primaryScreenHeight: NSScreen.screens[0].frame.height)`, and the screen that contains its centre.
  3. Run `CaptureCountdownController.shared.run(seconds: PoachCaptureTimer.current.seconds, …)`.
  4. Only then fetch `SCShareableContent` and build the filter:
     - area and display: the existing `SCContentFilter(display:excludingApplications:exceptingWindows:)` with the Poach exclusion;
     - window: find the `SCWindow` whose `windowID` matches. If there is none, throw `ScreenCaptureError.selectionFailed("That window is no longer available.")`; otherwise use `SCContentFilter(desktopIndependentWindow:)`.
- [ ] **Step 2: Delete the picker code.** Remove `chooseContent`, the `SCContentSharingPickerObserver` conformance and its three callbacks, `resolvePicker`, `pickerContinuation`, `activePicker`, `ContentFilterBox`, `chooseDisplay`, the macOS 15.2 branch, `timerOverlay`, and `CaptureTimerOverlay.swift`.
- [ ] **Step 3: Update `PoachApp.swift`.**
  - Call `service.startRecording(mode: captureMode)` with no closure, and delete `RecordingStatusWindowController.countDown()`. `takeScreenshot()` needs no change.
  - In the ⌘⇧P hotkey action, check `CaptureCountdownController.shared.isRunning` first: if it is running, call `cancel()` and return.
- [ ] **Step 4: Run `swift build --package-path apps/macos` and `bash scripts/test-capture-selection.sh`, then do the manual Review Focus pass** on the debug binary:
  - Each mode × Record and Screenshot × Off, 3s and 10s. Screenshots never contain the outline, number or ✕.
  - During a 10s countdown, clicks reach other apps, and Esc, ✕ and ⌘⇧P each cancel.
  - After a cancel, an error, or completion, Esc closes a Finder menu normally.
  - Close the chosen window during the countdown: the alert says "That window is no longer available.".
  - If a second display is available, the outline sits on the target there.
  - Poach windows, the menu bar and the Dock are never highlighted.
- [ ] **Step 5: Commit:** `feat(macos): select full screen and window captures in poach`.

### Task 6: Space stops a focused recording

**Files:**
- Modify: `apps/macos/Sources/Views/PoachHomeView.swift` (`PoachRecordingStatusView`)

**Interfaces:**
- Consumes: `PoachRecordingStatusView(elapsedSeconds:onStop:)`, unchanged.

- [ ] **Step 1: Add the Space shortcut.** Put a zero-opacity, `accessibilityHidden` button with `.keyboardShortcut(.space, modifiers: [])` that calls `onStop`, and add "Stop (Space or Return)" as help on Stop.
- [ ] **Step 2: Build, then check manually.**
  - During a recording, typing spaces in TextEdit does not stop Poach.
  - Clicking the recording panel and pressing Space stops it.
  - ⌘⇧P still stops it from anywhere.
- [ ] **Step 3: Commit:** `feat(macos): stop a focused recording with space`.

### Task 7: Docs and handoff

**Files:**
- Modify: `README.md` (capture section near line 29), `CONTRIBUTING.md` (add `bash scripts/test-capture-selection.sh` next to the build commands near line 39), `.gitignore`
- Create: `HANDOFF.md`

- [ ] **Step 1: `.gitignore`:** add `.superpowers/`. Commit alone: `chore: ignore brainstorming companion files`.
- [ ] **Step 2: `README.md`:** describe the optional Off/3s/10s timer (default Off) for recordings and screenshots, that all three modes are chosen in Poach's own overlay, the shortcuts (Space/Return to start, Esc/✕/⌘⇧P to cancel a countdown, ⌘⇧P or Space on the focused panel to stop), and that the screen stays usable during the countdown. **`CONTRIBUTING.md`:** add the new test script.
- [ ] **Step 3: `HANDOFF.md`:** status, what this branch did, how to run (`swift build --package-path apps/macos`, `bash scripts/build-macos-app.sh`, both test scripts), and open items: a global Space stop was deferred by the user ("for now"); Esc during a countdown cancels instead of reaching other apps' menus.
- [ ] **Step 4: Commit the docs:** `docs: describe optional capture timer and poach selection`.
