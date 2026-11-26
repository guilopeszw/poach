#!/bin/bash
# Build the Linux client's .rpm and .deb as release assets kept apart from the
# macOS downloads: own file names and their own checksum manifest.
set -euo pipefail
cd "$(dirname "$0")/.."
pnpm --filter @poach/linux app:build --bundles rpm,deb
bundle="apps/linux/src-tauri/target/release/bundle"
release="outputs/linux"
rm -rf "$release"
mkdir -p "$release"
rpm=("$bundle"/rpm/Poach-*.x86_64.rpm)
deb=("$bundle"/deb/Poach_*_amd64.deb)
if [ "${#rpm[@]}" -ne 1 ] || [ "${#deb[@]}" -ne 1 ] || [ ! -f "${rpm[0]}" ] || [ ! -f "${deb[0]}" ]; then
  echo "Expected exactly one .rpm and one .deb in $bundle" >&2
  exit 1
fi
cp "${rpm[0]}" "$release/Poach-x86_64.rpm"
cp "${deb[0]}" "$release/Poach-amd64.deb"
(
  cd "$release"
  sha256sum Poach-x86_64.rpm Poach-amd64.deb > SHA256SUMS-linux.txt
)
echo "Linux release assets in $release:"
ls -1 "$release"
