import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'models.dart';

/// `opx_asr_event` in opx_asr.h.
final class OpxAsrEvent extends Struct {
  @Int32()
  external int state;
  @Int32()
  external int error;
  @Int64()
  external int processedMs;
  @Int64()
  external int totalMs;
  @Int64()
  external int sequence;
}

final class OpxAsrModel extends Opaque {}

final class OpxAsrJob extends Opaque {}

const supportedAsrAbi = 1;

typedef PtrOut<T extends NativeType> = Pointer<Pointer<T>>;

/// Hand-written bindings for the package's own C ABI (whisper types never
/// appear here). One instance per isolate.
class AsrNative {
  AsrNative._(DynamicLibrary lib)
    : abiVersion = lib.lookupFunction<Uint32 Function(), int Function()>(
        'opx_asr_abi_version',
      ),
      info = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'opx_asr_info',
          ),
      stringFree = lib
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('opx_asr_string_free'),
      modelOpen = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, PtrOut<OpxAsrModel>),
            int Function(Pointer<Utf8>, PtrOut<OpxAsrModel>)
          >('opx_asr_model_open'),
      modelInfo = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<OpxAsrModel>),
            Pointer<Utf8> Function(Pointer<OpxAsrModel>)
          >('opx_asr_model_info'),
      modelClose = lib
          .lookupFunction<
            Void Function(Pointer<OpxAsrModel>),
            void Function(Pointer<OpxAsrModel>)
          >('opx_asr_model_close'),
      jobCreate = lib
          .lookupFunction<
            Int32 Function(
              Pointer<OpxAsrModel>,
              Pointer<Utf8>,
              PtrOut<OpxAsrJob>,
            ),
            int Function(Pointer<OpxAsrModel>, Pointer<Utf8>, PtrOut<OpxAsrJob>)
          >('opx_asr_job_create'),
      jobStart = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxAsrJob>),
            int Function(Pointer<OpxAsrJob>)
          >('opx_asr_job_start'),
      jobPoll = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxAsrJob>, Pointer<OpxAsrEvent>),
            int Function(Pointer<OpxAsrJob>, Pointer<OpxAsrEvent>)
          >('opx_asr_job_poll'),
      jobCancel = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxAsrJob>),
            int Function(Pointer<OpxAsrJob>)
          >('opx_asr_job_cancel'),
      jobJoin = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxAsrJob>),
            int Function(Pointer<OpxAsrJob>)
          >('opx_asr_job_join'),
      jobResult = lib
          .lookupFunction<
            Int32 Function(Pointer<OpxAsrJob>, PtrOut<Utf8>),
            int Function(Pointer<OpxAsrJob>, PtrOut<Utf8>)
          >('opx_asr_job_result'),
      jobDestroy = lib
          .lookupFunction<
            Void Function(Pointer<OpxAsrJob>),
            void Function(Pointer<OpxAsrJob>)
          >('opx_asr_job_destroy');

  final int Function() abiVersion;
  final Pointer<Utf8> Function() info;
  final void Function(Pointer<Utf8>) stringFree;
  final int Function(Pointer<Utf8>, PtrOut<OpxAsrModel>) modelOpen;
  final Pointer<Utf8> Function(Pointer<OpxAsrModel>) modelInfo;
  final void Function(Pointer<OpxAsrModel>) modelClose;
  final int Function(Pointer<OpxAsrModel>, Pointer<Utf8>, PtrOut<OpxAsrJob>)
  jobCreate;
  final int Function(Pointer<OpxAsrJob>) jobStart;
  final int Function(Pointer<OpxAsrJob>, Pointer<OpxAsrEvent>) jobPoll;
  final int Function(Pointer<OpxAsrJob>) jobCancel;
  final int Function(Pointer<OpxAsrJob>) jobJoin;
  final int Function(Pointer<OpxAsrJob>, PtrOut<Utf8>) jobResult;
  final void Function(Pointer<OpxAsrJob>) jobDestroy;

  /// Overrides the library location (host tests load a locally built one).
  static String? libraryPath = Platform.environment['OPX_WHISPER_LIBRARY'];

  static AsrNative? _instance;
  static Object? _loadError;

  static AsrNative load({String? path}) {
    final cached = _instance;
    if (cached != null) return cached;
    if (_loadError != null) throw const AsrException(AsrErrorCode.unavailable);
    try {
      final native = AsrNative._(_open(path ?? libraryPath));
      if (native.abiVersion() != supportedAsrAbi) {
        throw const AsrException(AsrErrorCode.unavailable);
      }
      return _instance = native;
    } catch (e) {
      _loadError = e;
      throw const AsrException(AsrErrorCode.unavailable);
    }
  }

  static DynamicLibrary _open(String? path) {
    if (path != null && path.isNotEmpty) return DynamicLibrary.open(path);
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.open(
        'openplayx_whisper.framework/openplayx_whisper',
      );
    }
    if (Platform.isWindows) return DynamicLibrary.open('openplayx_whisper.dll');
    return DynamicLibrary.open('libopenplayx_whisper.so');
  }

  String? takeString(Pointer<Utf8> value) {
    if (value == nullptr) return null;
    try {
      return value.toDartString();
    } finally {
      stringFree(value);
    }
  }

  Map<String, dynamic> infoSync() {
    final text = takeString(info());
    if (text == null) throw const AsrException(AsrErrorCode.nativeFailure);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Blocking model load; returns the handle address (valid process-wide)
  /// and the model description. Call from a worker isolate.
  (int, Map<String, dynamic>) openModelSync(String path, {bool gpu = true}) {
    final options = jsonEncode({'path': path, 'gpu': gpu}).toNativeUtf8();
    final out = calloc<Pointer<OpxAsrModel>>();
    try {
      final code = modelOpen(options, out);
      if (code != 0) throw AsrException(AsrErrorCode.fromNative(code));
      final text = takeString(modelInfo(out.value));
      return (
        out.value.address,
        text == null ? const {} : jsonDecode(text) as Map<String, dynamic>,
      );
    } finally {
      calloc.free(options);
      calloc.free(out);
    }
  }
}
