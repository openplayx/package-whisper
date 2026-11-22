#!/usr/bin/env bash
# Builds the pinned whisper.cpp (and its ggml) as static CPU libraries into
# third_party/whisper/<target>. Metal / Core ML / CUDA / OpenMP stay off:
# CPU is the baseline path; accelerators are enabled only after they are
# verified for a chosen build, model and device.
#
# Targets: macos-arm64 macos-x86_64 ios-arm64 ios-sim-arm64 ios-sim-x86_64
#          linux-x86_64 linux-arm64 android-<abi>
#          windows-x86_64 (Git Bash on Windows; MSVC via the Visual Studio generator)
set -euo pipefail
WHISPER_VERSION=1.9.5
WHISPER_SHA256=ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz"

target="${1:?usage: build_whisper.sh <target>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/third_party/whisper"
src="$work/src/whisper.cpp-$WHISPER_VERSION"
prefix="$work/$target"
tarball="$work/src/whisper-$WHISPER_VERSION.tar.gz"
mkdir -p "$work/src"

if [ ! -f "$tarball" ]; then
  curl -fL --retry 3 -o "$tarball.part" "$WHISPER_URL"
  mv "$tarball.part" "$tarball"
fi
actual="$(shasum -a 256 "$tarball" 2>/dev/null || sha256sum "$tarball")"
if [ "${actual%% *}" != "$WHISPER_SHA256" ]; then
  echo "whisper.cpp tarball checksum mismatch" >&2
  exit 1
fi
[ -d "$src" ] || tar -xzf "$tarball" -C "$work/src"

args=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$prefix"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF
  -DWHISPER_CURL=OFF -DWHISPER_SDL2=OFF -DWHISPER_COREML=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF
  -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_BACKEND_DL=OFF
)
case "$target" in
  macos-*) args+=(-DCMAKE_OSX_ARCHITECTURES="${target#macos-}" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0) ;;
  tvos-sim-*) args+=(-DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvsimulator
                    -DCMAKE_OSX_ARCHITECTURES="${target#tvos-sim-}" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0) ;;
  tvos-*) args+=(-DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos
                -DCMAKE_OSX_ARCHITECTURES="${target#tvos-}" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0) ;;
  ios-sim-*) args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator
                    -DCMAKE_OSX_ARCHITECTURES="${target#ios-sim-}" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0) ;;
  ios-*) args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
                -DCMAKE_OSX_ARCHITECTURES="${target#ios-}" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0) ;;
  android-*)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    args+=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
           -DANDROID_ABI="${target#android-}" -DANDROID_PLATFORM=android-24) ;;
  linux-*) ;;
  windows-x86_64)
    # Static MSVC libraries matching the Flutter plugin's /MD runtime.
    args+=(-G "Visual Studio 17 2022" -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL) ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac

# Enable the Apple acceleration paths for the dedicated Apple TV target.
if [[ "$target" == tvos-* ]]; then
  args+=(-DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
         -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON)
fi
build="$work/build/$target"
cmake -S "$src" -B "$build" "${args[@]}" >/dev/null
cmake --build "$build" --config Release -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
cmake --install "$build" --config Release >/dev/null
# Some generators put ggml's archives only in the build tree.
mkdir -p "$prefix/lib"
find "$build" \( -name 'libggml*.a' -o -name 'ggml*.lib' -o -name 'whisper.lib' \) -exec cp -f {} "$prefix/lib/" \;
printf 'whisper.cpp %s\n%s\n' "$WHISPER_VERSION" "${args[*]}" > "$prefix/BUILDINFO"
echo "$prefix"
