#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-macos-app.sh
release="outputs/beta"
mkdir -p "$release"
app_archive="Poach-$(uname -m).zip"
ditto -c -k --keepParent outputs/Poach.app "$release/$app_archive"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Poach Codex"
ditto outputs/connectors/marketplace "$stage/Poach Codex/marketplace"
# The connector launches the server embedded in the installed app.
rm -f "$stage/Poach Codex/marketplace/plugins/poach/server.mjs"
cp scripts/install-codex-connector.sh "$stage/Poach Codex/Install Codex.command"
ditto -c -k --keepParent "$stage/Poach Codex" "$release/Poach-Codex.zip"
cp outputs/connectors/Poach.mcpb "$release/"
cp outputs/runtime-cache/ffmpeg-8.1.3.tar.xz "$release/"
cp scripts/bundle-runtime.sh "$release/"
assets=("$app_archive" Poach-Codex.zip Poach.mcpb ffmpeg-8.1.3.tar.xz bundle-runtime.sh)
if [[ -n "${POACH_BUN_RELINK_ARCHIVE:-}" ]]; then
  parts_dir="$stage/bun-relink"
  mkdir "$parts_dir"
  split -b 48m -a 2 "$POACH_BUN_RELINK_ARCHIVE" "$parts_dir/Bun-relink-materials.tar.part-"
  shasum -a 256 < "$POACH_BUN_RELINK_ARCHIVE" | awk '{print $1, " Bun-relink-materials.tar"}' > "$release/Bun-relink-materials.sha256"
  assets+=(Bun-relink-materials.sha256)
  for part in "$parts_dir/"*; do
    cp "$part" "$release/"
    assets+=("${part##*/}")
  done
fi
(
  cd "$release"
  shasum -a 256 "${assets[@]}" > SHA256SUMS.txt
)
