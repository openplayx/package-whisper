#!/usr/bin/env bash
# Builds the pinned whisper.cpp (and its ggml) as static libraries into
# third_party/whisper/<target>, with each platform's hardware acceleration:
#   Apple (macOS/iOS/tvOS): Metal (GPU) + Core ML (ANE encoder, falls back to
#                           ggml when no .mlmodelc sits next to the model);
#                           tvOS also Accelerate BLAS (see below)
#   Android (64-bit) / Linux / Windows: Vulkan (GPU); ggml falls back to the
#                           CPU when the device has no usable Vulkan driver
#                           (Linux/Windows only when the build machine has the
#                           Vulkan toolchain, see below)
#   Android armeabi-v7a:    CPU only (ggml-vulkan is 64-bit only)
# The CPU backend is always linked as the fallback. Writes BUILDINFO (flags +
# OPX_BUILD_REV) and LINKLIBS (static libraries in link order).
#
# Targets: macos-arm64 macos-x86_64 ios-arm64 ios-sim-arm64 ios-sim-x86_64
#          linux-x86_64 linux-arm64 android-<abi>
#          windows-x86_64 (Git Bash on Windows; MSVC via the Visual Studio generator)
set -euo pipefail
WHISPER_VERSION=1.9.5
WHISPER_SHA256=ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720
# Bump when the flags change so tool/ensure_whisper_apple.sh rebuilds stale
# libraries.
OPX_BUILD_REV=4
WHISPER_URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz"
# ggml-vulkan needs vulkan.hpp and SPIRV-Headers, which the Android NDK lacks
# (the NDK provides glslc and libvulkan.so).
VULKAN_HEADERS_URL=https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.350.tar.gz
VULKAN_HEADERS_SHA256=6dd105e5cc7ddab6e7b611ae2c1872740d1727557cc8bf9daf13d6de1e4b3999
SPIRV_HEADERS_URL=https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.350.0.tar.gz
SPIRV_HEADERS_SHA256=9905d9341f20388adb852c77dd982f2c4d539fd68e6c1f1bcebf034715f2d1d5

target="${1:?usage: build_whisper.sh <target>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/third_party/whisper"
src="$work/src/whisper.cpp-$WHISPER_VERSION"
prefix="$work/$target"
tarball="$work/src/whisper-$WHISPER_VERSION.tar.gz"
mkdir -p "$work/src"

# fetch <url> <sha256> <file>: download once, verify the checksum.
fetch() {
  if [ ! -f "$3" ]; then
    curl -fL --retry 3 -o "$3.part" "$1"
    mv "$3.part" "$3"
  fi
  local actual
  actual="$(shasum -a 256 "$3" 2>/dev/null || sha256sum "$3")"
  if [ "${actual%% *}" != "$2" ]; then
    echo "checksum mismatch: $1" >&2
    exit 1
  fi
}
fetch "$WHISPER_URL" "$WHISPER_SHA256" "$tarball"
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
    abi="${target#android-}"
    case "$abi" in
      arm64-v8a) triple=aarch64-linux-android ;;
      armeabi-v7a) triple=arm-linux-androideabi ;;
      x86_64) triple=x86_64-linux-android ;;
      x86) triple=i686-linux-android ;;
    esac
    ndk_host="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" | head -1)"
    vk="$work/src/vulkan-deps"
    mkdir -p "$vk"
    fetch "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256" "$vk/vulkan-headers.tar.gz"
    fetch "$SPIRV_HEADERS_URL" "$SPIRV_HEADERS_SHA256" "$vk/spirv-headers.tar.gz"
    # SPIRV-Headers goes into the Vulkan-Headers prefix: ggml includes
    # <spirv/unified1/spirv.hpp> from Vulkan's include dir (the SDK layout).
    if [ ! -f "$vk/vulkan/share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" ]; then
      rm -rf "$vk/x" && mkdir -p "$vk/x"
      tar -xzf "$vk/vulkan-headers.tar.gz" -C "$vk/x" && tar -xzf "$vk/spirv-headers.tar.gz" -C "$vk/x"
      rm -rf "$vk/vulkan" && mv "$vk"/x/Vulkan-Headers-* "$vk/vulkan"
      cmake -S "$vk"/x/SPIRV-Headers-* -B "$vk/x/spirv-build" -DCMAKE_INSTALL_PREFIX="$vk/vulkan" \
        -DSPIRV_HEADERS_ENABLE_TESTS=OFF >/dev/null
      cmake --install "$vk/x/spirv-build" >/dev/null
      rm -rf "$vk/x"
    fi
    args+=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
           -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-28
           -DVulkan_INCLUDE_DIR="$vk/vulkan/include"
           -DVulkan_LIBRARY="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/sysroot/usr/lib/$triple/28/libvulkan.so"
           -DVulkan_GLSLC_EXECUTABLE="$(ls "$ANDROID_NDK_HOME"/shader-tools/*/glslc | head -1)"
           -DSPIRV-Headers_DIR="$vk/vulkan/share/cmake/SPIRV-Headers") ;;
  linux-*) ;;
  windows-x86_64)
    # Static MSVC libraries matching the Flutter plugin's /MD runtime.
    args+=(-G "Visual Studio 17 2022" -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL) ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac

libs=(whisper)
case "$target" in
  tvos-*)
    args+=(-DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
           -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON)
    libs+=(whisper.coreml ggml ggml-metal ggml-blas) ;;
  macos-*|ios-*)
    # No ggml-blas: Accelerate's cblas_sgemm (new LAPACK) needs macOS 13.3 /
    # iOS 16.4, above the app's macOS 12 / iOS 15 floor, and would stop the
    # app from launching there. ggml-cpu still uses Accelerate (vDSP).
    args+=(-DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
           -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
    libs+=(whisper.coreml ggml ggml-metal) ;;
  android-armeabi-v7a|android-x86)
    # ggml-vulkan does not build for 32-bit (it streams 64-bit Vulkan handles
    # as objects); these ABIs keep the CPU backend.
    libs+=(ggml) ;;
  android-*)
    args+=(-DGGML_VULKAN=ON)
    libs+=(ggml ggml-vulkan) ;;
  linux-*|windows-*)
    # Needs the Vulkan SDK (Windows: VULKAN_SDK) or the distro's Vulkan
    # headers, SPIRV-Headers and glslc (Linux: libvulkan-dev spirv-headers
    # glslc). Without them the build stays CPU-only and says so.
    if { [[ "$target" == windows-* ]] && [ -n "${VULKAN_SDK:-}" ]; } ||
       { [[ "$target" == linux-* ]] && command -v glslc >/dev/null &&
         [ -f /usr/include/vulkan/vulkan.hpp ] && [ -f /usr/include/spirv/unified1/spirv.hpp ]; }; then
      args+=(-DGGML_VULKAN=ON)
      libs+=(ggml ggml-vulkan)
    else
      echo "WARNING: no Vulkan SDK/headers/glslc for $target; building CPU-only" >&2
      libs+=(ggml)
    fi ;;
esac
libs+=(ggml-cpu ggml-base)

build="$work/build/$target"
# A cache from another checkout path (e.g. a renamed directory) cannot be reused.
if [ -f "$build/CMakeCache.txt" ] && ! grep -qF "CMAKE_HOME_DIRECTORY:INTERNAL=$src" "$build/CMakeCache.txt"; then
  rm -rf "$build"
fi
cmake -S "$src" -B "$build" "${args[@]}" >/dev/null
cmake --build "$build" --config Release -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
cmake --install "$build" --config Release >/dev/null
# Some generators put ggml's archives only in the build tree.
mkdir -p "$prefix/lib"
find "$build" \( -name 'libggml*.a' -o -name 'ggml*.lib' -o -name 'whisper.lib' \) -exec cp -f {} "$prefix/lib/" \;
printf 'whisper.cpp %s\nOPX_BUILD_REV=%s\n%s\n' "$WHISPER_VERSION" "$OPX_BUILD_REV" "${args[*]}" > "$prefix/BUILDINFO"
printf '%s\n' "${libs[@]}" > "$prefix/LINKLIBS"
echo "$prefix"
