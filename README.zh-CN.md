# openplayx_whisper

[English](README.md) | 简体中文

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[OpenPlayX](https://github.com/openplayx/openplayx) 的进程内语音识别：基于锁定版本 **whisper.cpp 1.9.5** 的 Flutter FFI 插件，加上一套小型 C ABI（`opx_asr_*`），Go 服务 [openplayx-asr](https://github.com/openplayx/openplayx-asr) 也链接这套 ABI。

```
Dart (WhisperEngine) → dart:ffi → opx_asr_* C ABI (src/opx_asr.c) → whisper.cpp / ggml (CPU)
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

`tool/build_whisper.sh <target>` 下载锁定版本的 whisper.cpp 源码包（校验 sha256），把静态 CPU 库构建到 `third_party/whisper/<target>`（已被 git 忽略）。Metal、Core ML、CUDA、OpenMP 和 BLAS 默认关闭，要针对具体构建/模型/设备验证后才启用。

| 平台 | 链接方式 |
|---|---|
| macOS / iOS | podspec 编译 ABI；首次构建时 `tool/ensure_whisper_apple.sh` 补齐缺失的架构。只导出 `opx_asr_*`。 |
| Android / Linux | `src/CMakeLists.txt` 加版本脚本。没有构建产物时编译 `opx_asr_stub.c`（报告不可用）。 |
| Windows | 在加入 Windows 构建之前是 stub。 |

已验证：macOS arm64（宿主测试、App 打包集成测试和 Go 服务）。iOS 模拟器与 Android 模拟器（arm64-v8a，API 37）：App 的 `whisper_bridge_test` 集成测试通过；armeabi-v7a 与 x86_64 可链接并打包。Linux 脚本已有，但尚未验证。

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
