#!/bin/bash
# Assemble redistributable arm64 runtime helpers from pinned upstream releases.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/outputs/runtime-cache"
dest="$1"
[[ "$(uname -m)" == arm64 ]] || { echo "The bundled runtime currently targets Apple silicon." >&2; exit 1; }
mkdir -p "$cache" "$dest/bin" "$dest/licenses"
fetch() {
  local url="$1" file="$2" digest="$3"
  if ! echo "$digest  $file" | shasum -a 256 --status -c - 2>/dev/null; then
    curl --fail --location --retry 2 "$url" -o "$file.part"
    echo "$digest  $file.part" | shasum -a 256 -c -
    mv "$file.part" "$file"
  fi
}
cd "$cache"
node_release=node-v22.23.4-darwin-arm64
fetch "https://nodejs.org/dist/v22.23.4/$node_release.tar.gz" node.tar.gz c9e1dbc748b33ed2d14f42445191ecaf14c56259c7a9a26d0042c49ec2b66428
tar -xzf node.tar.gz "$node_release/bin/node" "$node_release/LICENSE"
cp "$node_release/bin/node" "$dest/bin/"
cp "$node_release/LICENSE" "$dest/licenses/Node-LICENSE"
ffmpeg=ffmpeg-8.1.3
fetch "https://ffmpeg.org/releases/$ffmpeg.tar.xz" "$ffmpeg.tar.xz" 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
build="$cache/$ffmpeg-$(shasum -a 256 "$root/scripts/bundle-runtime.sh" | cut -c1-12)"
if [[ ! -f "$build/complete" ]]; then
  mkdir -p "$build"
  tar -xf "$ffmpeg.tar.xz" -C "$build" --strip-components 1
  cd "$build"
  export MACOSX_DEPLOYMENT_TARGET=14.0
  ./configure --disable-autodetect --disable-network --disable-doc --disable-debug --disable-everything \
    --enable-zlib --enable-bzlib --enable-protocol=file,pipe --enable-demuxer=mov,image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_tiff_pipe,image_bmp_pipe \
    --enable-decoder=h264,hevc,av1,vp8,vp9,mpeg4,mjpeg,png,webp,tiff,bmp,prores,rawvideo,qtrle,apng,gif,mpeg2video \
    --enable-parser=h264,hevc,av1,vp9,mpeg4video,mjpeg,png,webp --enable-encoder=mpeg4,png,pam,rawvideo \
    --enable-muxer=mp4,image2pipe,rawvideo --enable-filter=scale,fps,format,trim,setpts,null,select
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe
  touch complete
fi
cp "$build/ffmpeg" "$build/ffprobe" "$dest/bin/"
cp "$build/COPYING.LGPLv2.1" "$dest/licenses/FFmpeg-LGPL-2.1"
