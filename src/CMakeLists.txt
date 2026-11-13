# Shared by Android, Linux and Windows. Links the pinned whisper.cpp static
# libraries from tool/build_whisper.sh when present; otherwise builds the
# stub so the host app still builds and reports recognition as unavailable.
cmake_minimum_required(VERSION 3.10)
project(openplayx_whisper_library VERSION 0.1.0 LANGUAGES C CXX)

if(ANDROID)
  set(OPX_WHISPER_TARGET "android-${ANDROID_ABI}")
elseif(WIN32)
  set(OPX_WHISPER_TARGET "windows-x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(OPX_WHISPER_TARGET "linux-arm64")
else()
  set(OPX_WHISPER_TARGET "linux-x86_64")
endif()
set(OPX_WHISPER_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/whisper/${OPX_WHISPER_TARGET}"
    CACHE PATH "Pinned whisper.cpp install prefix")

if(NOT WIN32 AND EXISTS "${OPX_WHISPER_PREFIX}/lib/libwhisper.a")
  add_library(openplayx_whisper SHARED "opx_asr.c")
  target_include_directories(openplayx_whisper PRIVATE "${OPX_WHISPER_PREFIX}/include")
  foreach(lib whisper ggml ggml-cpu ggml-base)
    target_link_libraries(openplayx_whisper PRIVATE "${OPX_WHISPER_PREFIX}/lib/lib${lib}.a")
  endforeach()
  target_link_libraries(openplayx_whisper PRIVATE m)
  if(ANDROID)
    target_link_libraries(openplayx_whisper PRIVATE log c++_static)
    target_link_options(openplayx_whisper PRIVATE "-Wl,-z,max-page-size=16384")
  else()
    target_link_libraries(openplayx_whisper PRIVATE pthread stdc++)
  endif()
  # Keep whisper/ggml symbols private (no clash with other native modules).
  target_link_options(openplayx_whisper PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map"
    "-Wl,-Bsymbolic")
else()
  message(WARNING "openplayx_whisper: no whisper.cpp at ${OPX_WHISPER_PREFIX}; building unavailable stub")
  add_library(openplayx_whisper SHARED "opx_asr_stub.c")
endif()
set_target_properties(openplayx_whisper PROPERTIES
  OUTPUT_NAME "openplayx_whisper" C_VISIBILITY_PRESET hidden)
target_compile_definitions(openplayx_whisper PUBLIC DART_SHARED_LIB)
