#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$repo_root/outputs/Poach.app"
node_path="$(command -v node || true)"
available_signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
signing_identity="${POACH_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' <<< "$available_signing_identities" | head -n 1)"
fi
if [[ -z "$signing_identity" ]] && grep -q '"Poach Local Development"' <<< "$available_signing_identities"; then
  signing_identity="Poach Local Development"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi

if [[ -z "$node_path" ]]; then
  echo "Node.js 20 or newer is required to build the Poach app." >&2
  exit 1
fi

pnpm --filter @poach/core build
pnpm --filter @poach/mcp-server build
node "$repo_root/scripts/build-connectors.mjs"
swift build --package-path "$repo_root/apps/macos" --configuration release
mkdir -p "$repo_root/outputs"
stage_dir="$(mktemp -d "$repo_root/outputs/.poach-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_path="$stage_dir/Poach.app"
mkdir -p "$app_path/Contents/MacOS"
engine_path="$app_path/Contents/Resources/core"
mkdir -p "$engine_path/dist"
cp "$repo_root/apps/macos/Assets/Poach.icon/Assets/Pouch.png" "$app_path/Contents/Resources/Pouch.png"
bash "$repo_root/scripts/build-app-icon.sh" "$repo_root/apps/macos/Assets/PoachIcon.png" "$app_path/Contents/Resources/Poach.icns"
cp "$repo_root/packages/core/dist/"*.js "$engine_path/dist/"
cp "$repo_root/packages/core/package.json" "$engine_path/package.json"
cp "$repo_root/apps/macos/.build/release/Poach" "$app_path/Contents/MacOS/Poach"
cp "$repo_root/apps/macos/Info.plist" "$app_path/Contents/Info.plist"
if [[ -f "$repo_root/NOTICE" ]]; then cp "$repo_root/NOTICE" "$app_path/Contents/Resources/NOTICE"; fi
cp "$repo_root/outputs/connectors/marketplace/plugins/poach/server.mjs" "$app_path/Contents/Resources/server.mjs"
chrome_path="$app_path/Contents/Resources/ChromeExtension"
mkdir -p "$chrome_path"
cp "$repo_root/apps/chrome/"{manifest.json,bridge.js,capture.js,popup.html,popup.css,popup.js,poach.png} "$chrome_path/"
icon_cache="$repo_root/outputs/compiled-icon"
icon_digest=$(cat "$repo_root/apps/macos/Assets/Poach.icon/icon.json" "$repo_root/apps/macos/Assets/Poach.icon/Assets/Pouch.png" | shasum -a 256 | cut -d' ' -f1)
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$repo_root/apps/macos/Assets/Poach.icon" --compile "$app_path/Contents/Resources" \
    --target-device mac --platform macosx --minimum-deployment-target 14.0 --app-icon Poach \
    --output-partial-info-plist "$stage_dir/icon.plist"
elif [[ -f "$icon_cache/source.sha256" && "$(cat "$icon_cache/source.sha256")" == "$icon_digest" ]]; then
  cp "$icon_cache/Assets.car" "$icon_cache/Poach.icns" "$app_path/Contents/Resources/"
fi
if [[ -s "$app_path/Contents/Resources/Assets.car" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Poach" "$app_path/Contents/Info.plist"
fi
runtime="$app_path/Contents/Resources/runtime"
bash "$repo_root/scripts/bundle-runtime.sh" "$runtime"
for tool in ffmpeg ffprobe; do
  if [[ "$signing_identity" == "Poach Local Development" || "$signing_identity" == "-" ]]; then
    codesign --force --timestamp=none --sign - "$runtime/bin/$tool"
  else
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$runtime/bin/$tool"
  fi
done
codesign --verify --strict "$runtime/bin/node"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - "$app_path"
  echo "Development build: ad-hoc signing can invalidate Screen Recording approval after rebuilding. Use an Apple Development identity from Xcode or set POACH_CODESIGN_IDENTITY explicitly." >&2
elif [[ "$signing_identity" == "Poach Local Development" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$app_path"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_path"
fi
codesign --verify --strict "$app_path"
signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature_details" | head -n 1)"
if [[ "$team_identifier" == "not set" || -z "$team_identifier" ]]; then
  echo "Warning: this build has no Apple Team ID. On macOS 26, Screen Recording approval may not persist across builds. Use an Apple Development identity from Xcode or set POACH_CODESIGN_IDENTITY explicitly." >&2
fi

# Replacing signed executable pages in place can terminate a running Poach.
if [[ -d "$destination" ]]; then
  swift - "$app_path" "$destination" <<'SWIFT'
import Darwin
let arguments = CommandLine.arguments
if renamex_np(arguments[1], arguments[2], UInt32(RENAME_SWAP)) != 0 {
    perror("Could not exchange app bundles")
    exit(1)
}
SWIFT
else
  mv "$app_path" "$destination"
fi
echo "Built $destination"
