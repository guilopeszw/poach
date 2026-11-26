#!/bin/bash
# Assemble redistributable arm64 runtime helpers from pinned upstream releases.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/outputs/runtime-cache"
dest="$1"
[[ "$(uname -m)" == arm64 ]] || { echo "The bundled runtime currently targets Apple silicon." >&2; exit 1; }
mkdir -p "$cache" "$dest/bin" "$dest/lib" "$dest/licenses"
fetch() {
  local url="$1" file="$2" digest="$3"
  if ! echo "$digest  $file" | shasum -a 256 --status -c - 2>/dev/null; then
    curl --fail --location --retry 2 "$url" -o "$file.part"
    echo "$digest  $file.part" | shasum -a 256 -c -
    mv "$file.part" "$file"
  fi
}
cd "$cache"
bun_tag=bun-v1.4.0
bun_platform=bun-darwin-aarch64
fetch "https://github.com/oven-sh/bun/releases/download/$bun_tag/$bun_platform.zip" "$bun_tag-$bun_platform.zip" c669e97f6164e1c96e0701748db98dfa77492908cbd8394c7557134a735de381
fetch "https://raw.githubusercontent.com/oven-sh/bun/34cbb9a40b4bd1bd767d134a7065e66c2432a676/LICENSE.md" "$bun_tag-LICENSE.md" b9caf52728691b4057e371232c221a132883198be2f3d2ddf92c90404c984b1a
unzip -o -q "$bun_tag-$bun_platform.zip" "$bun_platform/bun"
install -m 755 "$bun_platform/bun" "$dest/bin/bun"
cp "$bun_tag-LICENSE.md" "$dest/licenses/Bun-LICENSE"
webkit_licenses=https://raw.githubusercontent.com/oven-sh/WebKit/0f966e81b78c84bb23213e391bc679c4ef83e56b/Source/WebCore
fetch "$webkit_licenses/LICENSE-LGPL-2" WebKit-LGPL-2 7555fa34bc131a75ca56d65c40cc1ea8f9515d23e353d4c15d58573a042f7805
fetch "$webkit_licenses/LICENSE-LGPL-2.1" WebKit-LGPL-2.1 f2b3bd09663381deb99721109d22b47af1213bb43007a8b56a06c6375c8050ce
cp WebKit-LGPL-2 WebKit-LGPL-2.1 "$dest/licenses/"
# Use a bundled config so project settings cannot change Poach's runtime.
printf '%s\n' '# Poach uses Bun defaults.' > "$dest/bunfig.toml"
# Keep existing connector paths while letting Bun process arguments under its own name.
cat > "$dest/bin/node" <<'SHIM'
#!/bin/sh
exec "${0%/*}/bun" --config="${0%/*}/../bunfig.toml" --no-install --no-env-file "$@"
SHIM
chmod 755 "$dest/bin/node"
ffmpeg=ffmpeg-8.1.3
fetch "https://ffmpeg.org/releases/$ffmpeg.tar.xz" "$ffmpeg.tar.xz" 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
build="$cache/$ffmpeg-$(shasum -a 256 "$root/scripts/bundle-runtime.sh" | cut -c1-12)"
if [[ ! -f "$build/complete" ]]; then
  mkdir -p "$build"
  tar -xf "$ffmpeg.tar.xz" -C "$build" --strip-components 1
  cd "$build"
  export MACOSX_DEPLOYMENT_TARGET=14.0
  ./configure --disable-autodetect --disable-network --disable-doc --disable-debug --disable-everything \
    --enable-shared --disable-static --install-name-dir='@loader_path/../lib' \
    --enable-zlib --enable-bzlib --enable-protocol=file,pipe --enable-demuxer=mov,image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_tiff_pipe,image_bmp_pipe \
    --enable-decoder=h264,hevc,av1,vp8,vp9,mpeg4,mjpeg,png,webp,tiff,bmp,prores,rawvideo,qtrle,apng,gif,mpeg2video \
    --enable-parser=h264,hevc,av1,vp9,mpeg4video,mjpeg,png,webp --enable-encoder=mpeg4,png,pam,rawvideo \
    --enable-muxer=mp4,image2pipe,rawvideo --enable-filter=scale,fps,format,trim,setpts,null,select,crop
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe
  touch complete
fi
cp "$build/ffmpeg" "$build/ffprobe" "$dest/bin/"
cp "$build"/lib*/*.[0-9]*.dylib "$dest/lib/"
cp "$build/COPYING.LGPLv2.1" "$dest/licenses/FFmpeg-LGPL-2.1"
