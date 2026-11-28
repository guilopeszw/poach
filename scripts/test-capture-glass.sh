#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-glass-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc "$repo_root/apps/macos/Tests/CaptureGlassTests/CaptureGlassTests.swift" -o "$binary"
"$binary" "$repo_root/apps/macos/Sources/Views/CaptureLiquidGlass.swift"
