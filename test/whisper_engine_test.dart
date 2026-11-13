// Real native tests. Needs `tool/build_host_lib.sh` and a multilingual ggml
// model (OPX_WHISPER_MODEL, default ~/.cache/openplayx-asr-models/ggml-base.bin).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openplayx_whisper/openplayx_whisper.dart';

void main() {
  final root = Directory.current.path;
  final lib = [
    '$root/build/host/libopenplayx_whisper.dylib',
    '$root/build/host/libopenplayx_whisper.so',
  ].where((p) => File(p).existsSync()).firstOrNull;
  final model =
      Platform.environment['OPX_WHISPER_MODEL'] ??
      '${Platform.environment['HOME']}/.cache/openplayx-asr-models/ggml-base.bin';
  final skip = lib == null
      ? 'run tool/build_host_lib.sh'
      : !File(model).existsSync()
      ? 'no model at $model'
      : false;
  String fixture(String name) => '$root/test/fixtures/$name';

  late WhisperEngine engine;
  late WhisperModel loaded;
  setUpAll(() async {
    if (skip != false) return;
    engine = WhisperEngine(
      libraryPath: lib,
      pollInterval: const Duration(milliseconds: 20),
    );
    loaded = await engine.openModel(model);
  });
  tearDownAll(() {
    if (skip != false) return;
    loaded.close();
    engine.dispose();
  });

  test('engine reports the pinned whisper.cpp', () {
    final info = engine.info();
    expect(info.available, isTrue);
    expect(info.engineVersion, startsWith(WhisperEngine.pinnedVersion));
    expect(loaded.multilingual, isTrue);
  }, skip: skip);

  test('English speech gives timed text', () async {
    final r = await engine
        .transcribe(
          loaded,
          AsrRequest(input: fixture('en.wav'), language: 'en'),
        )
        .done;
    expect(r.succeeded, isTrue);
    final text = r.transcript!.windows
        .expand((w) => w.segments)
        .map((s) => s.text)
        .join();
    expect(text.toLowerCase(), contains('quick brown fox'));
    expect(r.transcript!.audioMs, inInclusiveRange(5600, 5700));
  }, skip: skip);

  test(
    'Chinese with a multilingual model keeps Chinese (no translation)',
    () async {
      final r = await engine
          .transcribe(
            loaded,
            AsrRequest(input: fixture('zh.wav'), language: 'zh'),
          )
          .done;
      expect(r.succeeded, isTrue);
      final text = r.transcript!.windows
          .expand((w) => w.segments)
          .map((s) => s.text)
          .join();
      expect(text, contains('公'));
      expect(r.transcript!.language, 'zh');
    },
    skip: skip,
  );

  test('silence returns no segments instead of inventing text', () async {
    final r = await engine
        .transcribe(loaded, AsrRequest(input: fixture('silence.wav')))
        .done;
    expect(r.succeeded, isTrue);
    expect(r.transcript!.windows.expand((w) => w.segments), isEmpty);
  }, skip: skip);

  test('second window keeps the absolute audio offset', () async {
    final r = await engine
        .transcribe(
          loaded,
          AsrRequest(input: fixture('long.wav'), language: 'en'),
        )
        .done;
    expect(r.succeeded, isTrue);
    final w = r.transcript!.windows;
    expect(w.map((x) => x.offsetMs), [0, 30000]);
    expect(w.first.skipped, isTrue);
    final first = w[1].segments.first;
    // Speech starts at 41.0 s; 200 ms of context is kept before it.
    expect(first.startMs, inInclusiveRange(40500, 41500));
  }, skip: skip);

  test('wrong audio format is refused, not reinterpreted', () async {
    final tmp = File('${Directory.systemTemp.path}/opx-asr-bad.wav')
      ..writeAsBytesSync(List.filled(64, 1));
    final r = await engine.transcribe(loaded, AsrRequest(input: tmp.path)).done;
    expect(r.error, AsrErrorCode.inputUnsupported);
    tmp.deleteSync();
  }, skip: skip);

  test('unknown language and translate are rejected', () async {
    final r = await engine
        .transcribe(
          loaded,
          AsrRequest(input: fixture('en.wav'), language: 'xx'),
        )
        .done;
    expect(r.error, AsrErrorCode.language);
  }, skip: skip);

  test('cancel stops a running job and reports cancelled', () async {
    final job = engine.transcribe(
      loaded,
      AsrRequest(input: fixture('long.wav'), language: 'en'),
    );
    await job.progress.firstWhere((p) => p.state == AsrJobState.running);
    job.cancel();
    expect(job.current.state, AsrJobState.cancelling);
    final r = await job.done;
    expect(r.state, AsrJobState.cancelled);
    // The engine stays usable afterwards.
    final again = await engine
        .transcribe(
          loaded,
          AsrRequest(input: fixture('en.wav'), language: 'en'),
        )
        .done;
    expect(again.succeeded, isTrue);
  }, skip: skip);

  test('missing model is a model error', () async {
    expect(
      () => engine.openModel('/nonexistent/model.bin'),
      throwsA(
        isA<AsrException>().having(
          (e) => e.code,
          'code',
          AsrErrorCode.modelUnavailable,
        ),
      ),
    );
  }, skip: skip);
}
