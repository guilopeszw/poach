#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-pointer-trace-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT

swiftc \
  "$repo_root/apps/macos/Sources/Capture/PointerTraceBuffer.swift" \
  "$repo_root/apps/macos/Tests/PointerTraceTests/PointerTraceBufferTests.swift" \
  -o "$binary"
"$binary"
