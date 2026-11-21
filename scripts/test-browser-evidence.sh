#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-browser-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc "$root/apps/macos/Sources/App/PoachBrowserEvidence.swift" "$root/apps/macos/Tests/BrowserEvidenceTests/BrowserEvidenceTests.swift" -o "$binary"
"$binary"
