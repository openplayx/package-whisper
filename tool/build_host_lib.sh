#!/usr/bin/env bash
# Builds the bridge as a plain shared library for `flutter test` on the
# development machine, plus a static archive the HTTP service links with cgo.
# Output: build/host/libopenplayx_whisper.{dylib,so} and libopx_asr.a
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
[ -f "$prefix/lib/libwhisper.a" ] || "$root/tool/build_whisper.sh" "$target" >/dev/null
out="$root/build/host"
mkdir -p "$out"
libs="-L$prefix/lib -lwhisper -lggml -lggml-cpu -lggml-base"
cc -O2 -Wall -fPIC -fvisibility=hidden -I"$prefix/include" -c "$root/src/opx_asr.c" -o "$out/opx_asr.o"
rm -f "$out/libopx_asr.a" && ar rcs "$out/libopx_asr.a" "$out/opx_asr.o"
if [ "$(uname -s)" = Darwin ]; then
  clang++ -shared "$out/opx_asr.o" $libs -framework Accelerate -framework Foundation \
    -Wl,-exported_symbols_list,"$root/src/exports.txt" -o "$out/libopenplayx_whisper.dylib"
  echo "$out/libopenplayx_whisper.dylib"
else
  c++ -shared "$out/opx_asr.o" $libs -lm -lpthread \
    -Wl,--version-script="$root/src/exports.map" -Wl,-Bsymbolic -o "$out/libopenplayx_whisper.so"
  echo "$out/libopenplayx_whisper.so"
fi
