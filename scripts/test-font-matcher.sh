#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/poach-font-matcher-tests.XXXXXX")"
trap 'rm -f "$binary"' EXIT

swiftc -O \
  "$repo_root/apps/macos/Sources/App/PoachFontMatcher.swift" \
  "$repo_root/apps/macos/Tests/FontMatcherTests/FontMatcherTests.swift" \
  -o "$binary"
"$binary"
