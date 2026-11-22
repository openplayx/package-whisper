#!/usr/bin/env bash
# Xcode build phase: builds the pinned whisper.cpp for each arch being linked,
# only when its static libraries are missing.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${PLATFORM_NAME:-macosx}" in
  macosx) prefix=macos ;;
  iphoneos) prefix=ios ;;
  iphonesimulator) prefix=ios-sim ;;
  appletvos) prefix=tvos ;;
  appletvsimulator) prefix=tvos-sim ;;
  *) echo "unsupported platform $PLATFORM_NAME" >&2; exit 1 ;;
esac
for arch in ${ARCHS:-arm64}; do
  target="$prefix-$arch"
  if [ ! -f "$root/third_party/whisper/$target/lib/libwhisper.a" ]; then
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
      HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
      bash "$root/tool/build_whisper.sh" "$target"
  fi
done
