# openplayx_whisper

[English](README.md) | 简体中文

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[OpenPlayX](https://github.com/openplayx/openplayx) 的进程内语音识别：基于锁定版本 **whisper.cpp 1.9.5** 的 Flutter FFI 插件，加上一套小型 C ABI（`opx_asr_*`），Go 服务 [openplayx-asr](https://github.com/openplayx/openplayx-asr) 也链接这套 ABI。

```
Dart (WhisperEngine) → dart:ffi → opx_asr_* C ABI (src/opx_asr.c) → whisper.cpp / ggml (GPU, CPU fallback)
Go (openplayx-asr)   → cgo     ↗  same ABI, same result structure
```

不使用 `whisper-cli`、`whisper-server`、Python 运行时、子进程或命令字符串。

## 使用

以路径或 git 依赖的方式添加（未发布到 pub.dev）：

```yaml
dependencies:
  openplayx_whisper:
    git: https://github.com/openplayx/package-whisper
```

```dart
final engine = WhisperEngine();                    // 每个进程一个；任务逐个执行
engine.info();                                     // 是否可用、引擎版本（stub 构建为 false）
final model = await engine.openModel(path);        // worker isolate；多语言标志、类型
final job = engine.transcribe(model, AsrRequest(input: wav, language: 'zh'));
job.progress.listen(...);                          // waiting → running（已处理/总毫秒数）
job.cancel();                                      // 协作式取消；whisper 停止前显示 `cancelling`
final r = await job.done;                          // RawTranscript（audio_ms 窗口）或 AsrErrorCode
model.close();                                     // 任务仍在使用时也可以安全关闭（引用计数）
```

- **输入：** 只接受 16 kHz 单声道 16 位 PCM WAV，以绝对路径传入（在 OpenPlayX 中由 FFmpeg 预设 `audio.speech.wav` 生成）。其他格式返回 `inputUnsupported`，不会被重新解释。
- **分窗：** 以 30 秒窗口加 1 秒重叠从磁盘读取，并在原生层转成 float32，整个文件不会一次性放进内存。每个任务有自己的 `whisper_state`，权重（context）串行共享。
- **时间：** whisper 的 10 毫秒单位在这里转成整数毫秒。窗口偏移和裁掉的前导静音只加一次。宿主负责去掉重叠部分的重复（起点落在窗口重叠尾部的片段归下一个窗口），并把音频时间映射到媒体时间。
- **静音：** 比 `silence_dbfs`（−55 dBFS）更安静的窗口会被跳过，并报告为 `skipped`。这是静音门限，不是 VAD。
- **语言：** `auto` 或 ISO 639-1 代码。`.en` 模型拒绝非英文，不支持翻译。

## 构建

依赖：Flutter 3.24+（Dart 3.13+）、C/C++ 工具链、CMake 和 `curl`。

`tool/build_whisper.sh <target>` 下载锁定版本的 whisper.cpp 源码包（校验 sha256），把静态库构建到 `third_party/whisper/<target>`（已被 git 忽略），并打开硬件加速：

| 目标 | 加速 |
|---|---|
| macOS / iOS | Metal（GPU）+ Core ML 编码器（模型旁边有 `*-encoder.mlmodelc` 时使用）。不链接 ggml-blas：Accelerate 新版 `cblas_sgemm` 需要 macOS 13.3 / iOS 16.4，高于 App 的最低版本。 |
| tvOS | Metal + Core ML + Accelerate BLAS |
| Android arm64-v8a / x86_64 | Vulkan（需要 Vulkan 1.2 驱动；API 28+）。锁定版本的 Vulkan-Headers 和 SPIRV-Headers 会自动下载，glslc 用 NDK 自带的。 |
| Android armeabi-v7a | CPU（ggml-vulkan 只支持 64 位） |
| Linux / Windows | 构建机有 Vulkan 工具链时用 Vulkan（Linux：`libvulkan-dev spirv-headers glslc`；Windows：Vulkan SDK 并设置 `VULKAN_SDK`），否则只构建 CPU 版并给出警告 |

CPU 后端始终会链接：没有可用 GPU 时（模拟器、Android 模拟器只有 Vulkan 1.1、没有 GPU 的服务器）在 CPU 上识别。`openModel(path, gpu: false)` 强制用 CPU，`WhisperModel.backend` / `device` 说明模型实际用的设备（`MTL0` / `Vulkan0` / `CPU`）。改了构建参数要同时增加脚本里的 `OPX_BUILD_REV`，这样 Apple 构建和 `build_host_lib.sh` 会重新编译过期的库。Linux 和 Windows 上插件链接 Vulkan loader（`libvulkan.so.1` / `vulkan-1.dll`，随显卡驱动安装）；没有它时库加载失败，引擎报告不可用。

| 平台 | 链接方式 |
|---|---|
| macOS / iOS / tvOS | podspec 编译 ABI；首次构建时 `tool/ensure_whisper_apple.sh` 补齐缺失的架构。只导出 `opx_asr_*`。 |
| Android / Linux / Windows | `src/CMakeLists.txt` 链接构建产物 `LINKLIBS` 里列出的库（以及 Vulkan loader），Android / Linux 加版本脚本。没有构建产物时编译 `opx_asr_stub.c`（报告不可用）。 |

已验证：macOS arm64 走 Metal（宿主测试、App 打包集成测试和 Go 服务；base 模型在 153 秒音频上比 CPU 快约 4.7 倍，文本一致）。iOS 模拟器与 Android 模拟器（arm64-v8a）：App 的 `whisper_bridge_test` 在 CPU 回退下通过。iOS 真机与 tvOS 的库、macOS x86_64、Android armeabi-v7a / x86_64 以及 Linux arm64（Docker，已链接 Vulkan，CPU 回退）可以构建。尚未实测：iPhone / Apple TV 上的 Metal、Android 真机上的 Vulkan、Windows。

## 测试

```sh
tool/build_host_lib.sh   # build/host/libopenplayx_whisper.{dylib,so} + libopx_asr.a（供 cgo 使用）
flutter test             # 真实识别；需要 ~/.cache/openplayx-asr-models/ggml-base.bin
```

模型可从 `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin` 下载。`test/fixtures/` 中的测试音频由 macOS 文字转语音生成（英文、中文、静音，以及在 49.6 秒文件中第 41 秒出现的语音）。

## 模型

模型权重永远不提交到仓库。OpenPlayX App 的模型目录（App 仓库中的 `lib/services/subtitles/asr_model_store.dart`）锁定了多语言 ggml tiny/base/small（含 q5_1 变体）的 id、大小和 SHA-256。

## 参与贡献

欢迎提 issue 和 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。安全问题请按 [SECURITY.md](SECURITY.md)（英文）私下报告。

## 许可证

[MIT](LICENSE)。whisper.cpp 和 Whisper 模型权重由其作者以 MIT 许可证发布。

Apple TV：`tvos-arm64` 为真机目标，`tvos-sim-arm64` 为 Apple Silicon 模拟器目标；`tvos/` podspec 链接真实 whisper.cpp 引擎，不复用 iOS 二进制。
