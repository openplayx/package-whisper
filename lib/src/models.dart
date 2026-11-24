/// Error categories surfaced to hosts; no raw native log or path attached.
enum AsrErrorCode {
  invalidArgument(false),
  inputUnavailable(true),
  inputUnsupported(false),
  modelUnavailable(false),
  language(false),
  nativeFailure(true),
  cancelled(true),
  noMemory(true),
  badState(false),
  unavailable(false);

  const AsrErrorCode(this.retryable);
  final bool retryable;

  static AsrErrorCode fromNative(int code) => switch (code) {
    1 => invalidArgument,
    2 => inputUnavailable,
    3 => inputUnsupported,
    4 => modelUnavailable,
    5 => language,
    9 => cancelled,
    11 => badState,
    12 => noMemory,
    13 => unavailable,
    _ => nativeFailure,
  };
}

class AsrException implements Exception {
  const AsrException(this.code, [this.reason]);
  final AsrErrorCode code;
  final String? reason;
  @override
  String toString() =>
      'AsrException(${code.name}${reason == null ? '' : ': $reason'})';
}

class AsrEngineInfo {
  AsrEngineInfo.fromJson(Map<String, dynamic> j)
    : available = j['available'] as bool? ?? false,
      engine = j['engine'] as String? ?? 'whisper.cpp',
      engineVersion = j['engine_version'] as String? ?? '',
      systemInfo = j['system'] as String? ?? '';
  const AsrEngineInfo.unavailable()
    : available = false,
      engine = 'whisper.cpp',
      engineVersion = '',
      systemInfo = '';
  final bool available;
  final String engine;
  final String engineVersion;
  /// Deprecated: no longer reported (gathering it initialized every compute
  /// backend, which blocked the calling thread for seconds). Always ''.
  final String systemInfo;
}

/// One recognition request on a normalised 16 kHz mono s16 WAV.
class AsrRequest {
  const AsrRequest({
    required this.input,
    this.language = 'auto',
    this.threads = 4,
    this.windowMs = 30000,
    this.overlapMs = 1000,
    this.silenceDbfs = -55,
  });
  final String input;

  /// ISO 639-1 code (`zh`, `en`, …) or `auto`.
  final String language;
  final int threads;
  final int windowMs;
  final int overlapMs;
  final int silenceDbfs;

  Map<String, Object> toJson() => {
    'input': input,
    'language': language,
    'threads': threads,
    'window_ms': windowMs,
    'overlap_ms': overlapMs,
    'silence_dbfs': silenceDbfs,
    'translate': false,
  };
}

class RawSegment {
  RawSegment.fromJson(Map<String, dynamic> j)
    : startMs = j['start_ms'] as int,
      endMs = j['end_ms'] as int,
      text = j['text'] as String? ?? '',
      noSpeechProb = (j['no_speech_prob'] as num?)?.toDouble() ?? 0;
  const RawSegment(
    this.startMs,
    this.endMs,
    this.text, [
    this.noSpeechProb = 0,
  ]);

  /// Milliseconds relative to the start of the recognised audio.
  final int startMs, endMs;
  final String text;
  final double noSpeechProb;
}

class RawWindow {
  RawWindow.fromJson(Map<String, dynamic> j)
    : offsetMs = j['offset_ms'] as int,
      durationMs = j['duration_ms'] as int,
      skipped = j['skipped'] as bool? ?? false,
      segments = [
        for (final s in j['segments'] as List? ?? const [])
          RawSegment.fromJson(s as Map<String, dynamic>),
      ];
  const RawWindow(
    this.offsetMs,
    this.durationMs,
    this.segments, {
    this.skipped = false,
  });
  final int offsetMs, durationMs;
  final bool skipped;
  final List<RawSegment> segments;
}

/// Per-window output in audio-local time (`audio_ms`). Overlap merging and
/// the media time mapping are host responsibilities.
class RawTranscript {
  RawTranscript.fromJson(Map<String, dynamic> j)
    : language = j['language'] as String? ?? 'auto',
      audioMs = j['audio_ms'] as int? ?? 0,
      windowMs = j['window_ms'] as int? ?? 30000,
      overlapMs = j['overlap_ms'] as int? ?? 0,
      windows = [
        for (final w in j['windows'] as List? ?? const [])
          RawWindow.fromJson(w as Map<String, dynamic>),
      ];
  const RawTranscript({
    required this.language,
    required this.audioMs,
    required this.windowMs,
    required this.overlapMs,
    required this.windows,
  });
  final String language;
  final int audioMs, windowMs, overlapMs;
  final List<RawWindow> windows;
}

enum AsrJobState {
  queued,
  waiting,
  running,
  succeeded,
  failed,
  cancelling,
  cancelled;

  bool get terminal => this == succeeded || this == failed || this == cancelled;

  static AsrJobState fromNative(int s) => switch (s) {
    1 => waiting,
    2 => running,
    4 => succeeded,
    5 => failed,
    6 => cancelled,
    _ => queued,
  };
}

class AsrProgress {
  const AsrProgress(this.state, {this.processedMs = 0, this.totalMs});
  final AsrJobState state;
  final int processedMs;
  final int? totalMs;
}

class AsrJobResult {
  const AsrJobResult(this.state, {this.transcript, this.error});
  final AsrJobState state;
  final RawTranscript? transcript;
  final AsrErrorCode? error;
  bool get succeeded => state == AsrJobState.succeeded;
}
