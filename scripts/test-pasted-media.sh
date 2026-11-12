#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-pasted-media-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT

swiftc \
  "$repo_root/apps/macos/Sources/App/PoachImportMedia.swift" \
  "$repo_root/apps/macos/Tests/PastedMediaTests/PastedMediaTests.swift" \
  -o "$binary"
"$binary"
