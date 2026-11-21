#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-storage-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc \
 "$root/apps/macos/Sources/App/PoachInspectionRunner.swift" \
 "$root/apps/macos/Sources/App/PoachBrowserEvidence.swift" \
 "$root/apps/macos/Sources/App/PoachFavoriteStore.swift" \
 "$root/apps/macos/Sources/App/PoachHandoff.swift" \
 "$root/apps/macos/Sources/App/PoachFontMatcher.swift" \
 "$root/apps/macos/Sources/App/CaptureStorage.swift" \
 "$root/apps/macos/Sources/Capture/PointerTrace.swift" \
 "$root/apps/macos/Sources/Capture/PointerTraceBuffer.swift" \
 "$root/apps/macos/Sources/Views/InspectionStatus.swift" \
 "$root/apps/macos/Tests/EvidenceStorageTests/EvidenceStorageTests.swift" -o "$binary"
"$binary"
