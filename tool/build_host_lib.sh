#!/usr/bin/env bash
# Builds the bridge as a plain shared library for `flutter test` on the
# development machine, plus a static archive the HTTP service links with cgo.
# Output: build/host/libopenplayx_whisper.{dylib,so}, libopx_asr.a and
# ldflags.txt (the full static link line for cgo, in link order).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=macos-arm64 ;;
  Darwin-x86_64) target=macos-x86_64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  Linux-aarch64) target=linux-arm64 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac
prefix="$root/third_party/whisper/$target"
rev="$(sed -n 's/^OPX_BUILD_REV=//p' "$root/tool/build_whisper.sh")"
if [ ! -f "$prefix/lib/libwhisper.a" ] || ! grep -qx "OPX_BUILD_REV=$rev" "$prefix/BUILDINFO" 2>/dev/null; then
  "$root/tool/build_whisper.sh" "$target" >/dev/null
fi
out="$root/build/host"
mkdir -p "$out"
libs="-L$prefix/lib $(sed 's/^/-l/' "$prefix/LINKLIBS" | tr '\n' ' ')"
if [ "$(uname -s)" = Darwin ]; then
  sys="-framework Accelerate -framework Foundation -framework Metal -framework MetalKit -framework CoreML"
else
  sys="-lvulkan -lstdc++ -lm -lpthread"
fi
cc -O2 -Wall -fPIC -fvisibility=hidden -I"$prefix/include" -c "$root/src/opx_asr.c" -o "$out/opx_asr.o"
rm -f "$out/libopx_asr.a" && ar rcs "$out/libopx_asr.a" "$out/opx_asr.o"
echo "-L$out -lopx_asr $libs $sys" > "$out/ldflags.txt"
if [ "$(uname -s)" = Darwin ]; then
  clang++ -shared "$out/opx_asr.o" $libs $sys \
    -Wl,-exported_symbols_list,"$root/src/exports.txt" -o "$out/libopenplayx_whisper.dylib"
  echo "$out/libopenplayx_whisper.dylib"
else
  c++ -shared "$out/opx_asr.o" $libs $sys \
    -Wl,--version-script="$root/src/exports.map" -Wl,-Bsymbolic -o "$out/libopenplayx_whisper.so"
  echo "$out/libopenplayx_whisper.so"
fi
