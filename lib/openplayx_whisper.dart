/// In-process whisper.cpp speech recognition for OpenPlayX.
///
/// Dart → FFI → the package's own `opx_asr_*` C ABI → whisper.cpp / ggml.
/// No whisper-cli, whisper-server, child process or command string is used.
library;

export 'src/engine.dart' show WhisperEngine, WhisperModel, AsrJob;
export 'src/models.dart';
