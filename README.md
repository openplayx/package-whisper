# openplayx_whisper

English | [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

In-process speech recognition for [OpenPlayX](https://github.com/openplayx/openplayx):
a Flutter FFI plugin over the pinned **whisper.cpp 1.9.5**, plus a small C ABI
(`opx_asr_*`) that the Go service [openplayx-asr](https://github.com/openplayx/openplayx-asr)
links as well.

```
Dart (WhisperEngine) → dart:ffi → opx_asr_* C ABI (src/opx_asr.c) → whisper.cpp / ggml (GPU, CPU fallback)
Go (openplayx-asr)   → cgo     ↗  same ABI, same result structure
```

No `whisper-cli`, `whisper-server`, Python runtime, child process or command
string is used.

## Usage

Add it as a path or git dependency (it is not published on pub.dev):

```yaml
dependencies:
  openplayx_whisper:
    git: https://github.com/openplayx/package-whisper
```

```dart
final engine = WhisperEngine();                    // one per process; jobs run one at a time
engine.info();                                     // available? engine version (stub builds: false)
final model = await engine.openModel(path);        // worker isolate; multilingual flag, type
final job = engine.transcribe(model, AsrRequest(input: wav, language: 'zh'));
job.progress.listen(...);                          // waiting → running (processed/total ms)
job.cancel();                                      // cooperative; `cancelling` until whisper stops
final r = await job.done;                          // RawTranscript (audio_ms windows) or AsrErrorCode
model.close();                                     // safe while a job still uses it (refcounted)
```

- **Input:** only a 16 kHz mono 16-bit PCM WAV, given as an absolute path (in
  OpenPlayX, the FFmpeg preset `audio.speech.wav` produces it). Anything else
  returns `inputUnsupported`; it is never reinterpreted.
- **Windows:** 30 s windows plus 1 s overlap are read from disk and converted to
  float32 natively, so the whole file is never held in memory. Each job gets its
  own `whisper_state`, while the weights (context) are shared serially.
- **Time:** whisper's 10 ms units become integer ms here. The window offset and
  any trimmed leading silence are added exactly once. The host de-duplicates
  overlap (segments starting in a window's overlap tail belong to the next
  window) and maps audio time to media time.
- **Silence:** windows quieter than `silence_dbfs` (−55 dBFS) are skipped and
  reported as `skipped`. This is a silence gate, not VAD.
- **Language:** `auto` or an ISO 639-1 code. `.en` models reject non-English,
  and translation is refused.

## Building

Requirements: Flutter 3.24+ (Dart 3.13+), a C/C++ toolchain, CMake and `curl`.

`tool/build_whisper.sh <target>` downloads the pinned whisper.cpp tarball
(sha256 checked) and builds static libraries into
`third_party/whisper/<target>` (git-ignored), with hardware acceleration:

| Target | Acceleration |
|---|---|
| macOS / iOS | Metal (GPU) + Core ML encoder (used when a `*-encoder.mlmodelc` sits next to the model). No ggml-blas: Accelerate's new `cblas_sgemm` needs macOS 13.3 / iOS 16.4, above the app's floor. |
| tvOS | Metal + Core ML + Accelerate BLAS |
| Android arm64-v8a / x86_64 | Vulkan (needs a Vulkan 1.2 driver; API 28+). The pinned Vulkan-Headers and SPIRV-Headers are downloaded, glslc comes from the NDK. |
| Android armeabi-v7a | CPU (ggml-vulkan is 64-bit only) |
| Linux / Windows | Vulkan when the build machine has the toolchain (Linux: `libvulkan-dev spirv-headers glslc`; Windows: the Vulkan SDK with `VULKAN_SDK` set), otherwise CPU-only with a warning |

The CPU backend is always linked: without a usable GPU (simulators, the
Android emulator's Vulkan 1.1, a server without a GPU) recognition runs on the
CPU. `openModel(path, gpu: false)` forces the CPU, and `WhisperModel.backend` /
`device` tell which device a model got (`MTL0` / `Vulkan0` / `CPU`). Bump
`OPX_BUILD_REV` in the script when the flags change, so Apple builds and
`build_host_lib.sh` rebuild stale libraries. On Linux and Windows the plugin
links the Vulkan loader (`libvulkan.so.1` / `vulkan-1.dll`, installed with GPU
drivers); without it the library does not load and the engine reports
unavailable.

| Platform | How it links |
|---|---|
| macOS / iOS / tvOS | The podspec compiles the ABI; `tool/ensure_whisper_apple.sh` builds missing arches on first build. Only `opx_asr_*` is exported. |
| Android / Linux / Windows | `src/CMakeLists.txt` links the libraries listed in the build's `LINKLIBS` (plus the Vulkan loader), with a version script on Android / Linux. Without a build it compiles `opx_asr_stub.c` (reports unavailable). |

Verified: macOS arm64 on Metal (host tests, the app bundle integration test and
the Go service; base model about 4.7x faster than the CPU on a 153 s clip, same
text). iOS simulator and Android emulator (arm64-v8a): the app's
`whisper_bridge_test` passes on the CPU fallback. iOS device and tvOS
libraries, macOS x86_64, Android armeabi-v7a / x86_64 and Linux arm64 (Docker,
Vulkan linked, CPU fallback) build. Not yet run: Metal on an iPhone / Apple
TV, Vulkan on a real Android phone, Windows.

## Tests

```sh
tool/build_host_lib.sh   # build/host/libopenplayx_whisper.{dylib,so} + libopx_asr.a (for cgo)
flutter test             # real recognition; needs ~/.cache/openplayx-asr-models/ggml-base.bin
```

Get the model from
`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin`.
The fixtures in `test/fixtures/` were generated with macOS text-to-speech
(English, Chinese, silence, and speech at 41 s inside a 49.6 s file).

## Models

Model weights are never committed. The OpenPlayX app's catalogue
(`lib/services/subtitles/asr_model_store.dart` in the app repository) pins id,
size and SHA-256 for multilingual ggml tiny/base/small, including q5_1 variants.

## Contributing

Issues and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).
Report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). whisper.cpp and the Whisper model weights are MIT licensed by
their authors.

Apple TV: `tvos-arm64` builds for hardware and `tvos-sim-arm64` for the Apple Silicon simulator. The dedicated `tvos/` podspec links the real engine through the FlutterTV embedder; iOS binaries are never reused for tvOS.
