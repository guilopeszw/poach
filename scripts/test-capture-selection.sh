#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-capture-selection-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT

swiftc \
  "$repo_root/apps/macos/Sources/Capture/CaptureTimer.swift" \
  "$repo_root/apps/macos/Sources/Capture/CaptureTargetGeometry.swift" \
  "$repo_root/apps/macos/Sources/Capture/CaptureGlassFrames.swift" \
  "$repo_root/apps/macos/Tests/CaptureSelectionTests/CaptureSelectionTests.swift" \
  -o "$binary"
"$binary"
