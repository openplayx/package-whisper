import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'native.dart';

/// A loaded whisper.cpp model. Weights are shared serially by jobs; closing
/// while a job still runs is safe (the native side keeps a reference).
class WhisperModel {
  WhisperModel._(
    this._engine,
    this._handle,
    this.path,
    Map<String, dynamic> info,
  ) : type = info['type'] as String? ?? 'unknown',
      multilingual = info['multilingual'] as bool? ?? false;
  final WhisperEngine _engine;
  Pointer<OpxAsrModel>? _handle;
  final String path;
  final String type;

  /// English-only (`.en`) models cannot transcribe e.g. Chinese.
  final bool multilingual;
  bool get closed => _handle == null;

  void close() {
    final h = _handle;
    if (h == null) return;
    _handle = null;
    _engine._native.modelClose(h);
  }
}

/// App-facing entry point: load models and run recognition jobs through the
/// in-process whisper.cpp bridge. Jobs run one at a time on native worker
/// threads; the calling isolate only performs non-blocking polls.
class WhisperEngine {
  WhisperEngine({
    String? libraryPath,
    this.pollInterval = const Duration(milliseconds: 200),
  }) : _libraryPath = libraryPath ?? AsrNative.libraryPath;

  /// The pinned whisper.cpp release linked by tool/build_whisper.sh.
  static const pinnedVersion = '1.9.5';

  final String? _libraryPath;
  final Duration pollInterval;
  final _queue = Queue<AsrJob>();
  AsrJob? _running;
  bool _disposed = false;

  AsrNative get _native => AsrNative.load(path: _libraryPath);

  bool get libraryLoads {
    try {
      _native;
      return true;
    } on AsrException {
      return false;
    }
  }

  AsrEngineInfo? _info;

  /// Whether this build carries a working (non-stub) recognizer.
  AsrEngineInfo info() {
    final cached = _info;
    if (cached != null) return cached;
    if (!libraryLoads) return _info = const AsrEngineInfo.unavailable();
    try {
      return _info = AsrEngineInfo.fromJson(_native.infoSync());
    } catch (_) {
      return _info = const AsrEngineInfo.unavailable();
    }
  }

  bool get available => info().available;

  /// Loads a model file on a worker isolate (it reads hundreds of MB).
  Future<WhisperModel> openModel(String path) async {
    if (!available) throw const AsrException(AsrErrorCode.unavailable);
    final lib = _libraryPath;
    try {
      final (address, info) = await Isolate.run(
        () => AsrNative.load(path: lib).openModelSync(path),
      );
      return WhisperModel._(
        this,
        Pointer<OpxAsrModel>.fromAddress(address),
        path,
        info,
      );
    } on AsrException {
      rethrow;
    } on RemoteError {
      throw const AsrException(AsrErrorCode.nativeFailure);
    }
  }

  /// Queues a job; it starts when earlier jobs finished.
  AsrJob transcribe(WhisperModel model, AsrRequest request) {
    if (_disposed) throw StateError('disposed');
    if (model.closed) throw const AsrException(AsrErrorCode.badState);
    final job = AsrJob._(this, model, request);
    _queue.add(job);
    _pump();
    return job;
  }

  void _pump() {
    if (_running != null || _queue.isEmpty || _disposed) return;
    final job = _running = _queue.removeFirst();
    unawaited(
      job._run().whenComplete(() {
        _running = null;
        _pump();
      }),
    );
  }

  void dispose() {
    _disposed = true;
    for (final job in [..._queue]) {
      job.cancel();
    }
    _running?.cancel();
  }
}

class AsrJob {
  AsrJob._(this._engine, this._model, this.request);
  final WhisperEngine _engine;
  final WhisperModel _model;
  final AsrRequest request;
  final _progress = StreamController<AsrProgress>.broadcast();
  final _done = Completer<AsrJobResult>();
  AsrProgress _last = const AsrProgress(AsrJobState.queued);
  bool _cancelRequested = false;
  Pointer<OpxAsrJob>? _handle;

  Stream<AsrProgress> get progress => _progress.stream;
  AsrProgress get current => _last;
  Future<AsrJobResult> get done => _done.future;

  /// Cooperative: reports `cancelling` until native work really stops.
  void cancel() {
    if (_cancelRequested || _last.state.terminal) return;
    _cancelRequested = true;
    final handle = _handle;
    if (handle == null) {
      _engine._queue.remove(this);
      _finish(
        const AsrJobResult(
          AsrJobState.cancelled,
          error: AsrErrorCode.cancelled,
        ),
      );
      return;
    }
    _engine._native.jobCancel(handle);
    _emit(
      AsrProgress(
        AsrJobState.cancelling,
        processedMs: _last.processedMs,
        totalMs: _last.totalMs,
      ),
    );
  }

  void _emit(AsrProgress p) {
    _last = p;
    if (!_progress.isClosed) _progress.add(p);
  }

  void _finish(AsrJobResult r) {
    if (_done.isCompleted) return;
    _emit(
      AsrProgress(
        r.state,
        processedMs: _last.processedMs,
        totalMs: _last.totalMs,
      ),
    );
    _done.complete(r);
    unawaited(_progress.close());
  }

  Future<void> _run() async {
    if (_done.isCompleted) return;
    final model = _model._handle;
    if (model == null) {
      return _finish(
        const AsrJobResult(AsrJobState.failed, error: AsrErrorCode.badState),
      );
    }
    final native = _engine._native;
    final json = jsonEncode(request.toJson()).toNativeUtf8();
    final out = calloc<Pointer<OpxAsrJob>>();
    final event = calloc<OpxAsrEvent>();
    final text = calloc<Pointer<Utf8>>();
    Pointer<OpxAsrJob>? handle;
    try {
      final created = native.jobCreate(model, json, out);
      if (created != 0) {
        return _finish(
          AsrJobResult(
            AsrJobState.failed,
            error: AsrErrorCode.fromNative(created),
          ),
        );
      }
      handle = _handle = out.value;
      if (native.jobStart(handle) != 0) {
        return _finish(
          const AsrJobResult(
            AsrJobState.failed,
            error: AsrErrorCode.nativeFailure,
          ),
        );
      }
      if (_cancelRequested) native.jobCancel(handle);
      var state = AsrJobState.queued;
      while (true) {
        if (native.jobPoll(handle, event) > 0) {
          state = AsrJobState.fromNative(event.ref.state);
          final total = event.ref.totalMs;
          final p = AsrProgress(
            _cancelRequested && !state.terminal
                ? AsrJobState.cancelling
                : state,
            processedMs: event.ref.processedMs,
            totalMs: total > 0 ? total : null,
          );
          if (state.terminal) {
            _last = p;
            break;
          }
          _emit(p);
        }
        await Future<void>.delayed(_engine.pollInterval);
      }
      native.jobJoin(handle);
      if (state != AsrJobState.succeeded) {
        return _finish(
          AsrJobResult(state, error: AsrErrorCode.fromNative(event.ref.error)),
        );
      }
      final code = native.jobResult(handle, text);
      final body = native.takeString(text.value);
      if (code != 0 || body == null) {
        return _finish(
          const AsrJobResult(
            AsrJobState.failed,
            error: AsrErrorCode.nativeFailure,
          ),
        );
      }
      _finish(
        AsrJobResult(
          AsrJobState.succeeded,
          transcript: RawTranscript.fromJson(
            jsonDecode(body) as Map<String, dynamic>,
          ),
        ),
      );
    } catch (_) {
      final h = handle;
      if (h != null) native.jobCancel(h);
      _finish(
        const AsrJobResult(
          AsrJobState.failed,
          error: AsrErrorCode.nativeFailure,
        ),
      );
    } finally {
      if (handle != null) {
        native.jobJoin(handle);
        native.jobDestroy(handle);
      }
      _handle = null;
      calloc.free(json);
      calloc.free(out);
      calloc.free(event);
      calloc.free(text);
    }
  }
}
