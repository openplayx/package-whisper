// OpenPlayX speech recognition bridge over whisper.cpp's public C API.
//
// - Input is a 16 kHz mono 16-bit PCM WAV produced by the host's controlled
//   FFmpeg preset (`audio.speech.wav`). It is read window by window and
//   converted to float32 here; the whole file is never held in memory.
// - Each window of window_ms (+ overlap_ms read-ahead) runs whisper_full on a
//   per-job whisper_state; the context (weights) is shared serially, one job
//   at a time (model mutex).
// - whisper reports segment times in 10 ms units relative to the window;
//   they are converted to integer milliseconds relative to the input start
//   exactly once (window offset added here). Overlap de-duplication happens
//   in the host where the media time mapping is also applied.
// - A per-window RMS gate skips windows quieter than silence_dbfs. This is
//   a silence gate, not voice activity detection.
#include "opx_asr.h"

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
// Minimal pthread subset on Win32 (MSVC has no pthreads).
#include <windows.h>
#include <process.h>
typedef CRITICAL_SECTION pthread_mutex_t;
typedef HANDLE pthread_t;
static int pthread_mutex_init(pthread_mutex_t *m, const void *attr) {
  (void)attr;
  InitializeCriticalSection(m);
  return 0;
}
#define pthread_mutex_lock(m) (EnterCriticalSection(m), 0)
#define pthread_mutex_unlock(m) (LeaveCriticalSection(m), 0)
#define pthread_mutex_destroy(m) (DeleteCriticalSection(m), 0)
typedef struct {
  void *(*fn)(void *);
  void *arg;
} opx_thread_start;
static unsigned __stdcall opx_thread_trampoline(void *p) {
  opx_thread_start s = *(opx_thread_start *)p;
  free(p);
  s.fn(s.arg);
  return 0;
}
static int pthread_create(pthread_t *t, const void *attr, void *(*fn)(void *), void *arg) {
  (void)attr;
  opx_thread_start *s = (opx_thread_start *)malloc(sizeof *s);
  if (!s) return -1;
  s->fn = fn;
  s->arg = arg;
  uintptr_t h = _beginthreadex(NULL, 0, opx_thread_trampoline, s, 0, NULL);
  if (h == 0) {
    free(s);
    return -1;
  }
  *t = (HANDLE)h;
  return 0;
}
static int pthread_join(pthread_t t, void **ret) {
  (void)ret;
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
  return 0;
}
#else
#include <pthread.h>
#endif

#include "whisper.h"

#define OPX_ASR_MAX_TEXT 4096
#define OPX_ASR_MAX_REQUEST (16 * 1024)

// ------------------------------------------------------------------ strings

typedef struct {
  char *data;
  size_t len, cap;
  int failed;
} sbuf;

static void sb_put(sbuf *b, const char *s, size_t n) {
  if (b->failed) return;
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 1024;
    while (cap < b->len + n + 1) cap *= 2;
    char *next = realloc(b->data, cap);
    if (!next) {
      b->failed = 1;
      return;
    }
    b->data = next;
    b->cap = cap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void sb_printf(sbuf *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  sb_put(b, tmp, (size_t)(n < (int)sizeof tmp ? n : (int)sizeof tmp - 1));
}

// Length of a valid UTF-8 sequence at p, or 0 when invalid.
static int utf8_len(const unsigned char *p) {
  if (p[0] < 0x80) return 1;
  int n = (p[0] & 0xE0) == 0xC0 ? 2 : (p[0] & 0xF0) == 0xE0 ? 3
          : (p[0] & 0xF8) == 0xF0 ? 4 : 0;
  if (n == 0 || (n == 2 && p[0] < 0xC2)) return 0;
  for (int i = 1; i < n; i++) {
    if ((p[i] & 0xC0) != 0x80) return 0;
  }
  return n;
}

// JSON string; control characters escaped, invalid UTF-8 (whisper tokens can
// split a multi-byte character) replaced by U+FFFD, length bounded.
static void sb_json(sbuf *b, const char *s, size_t max_bytes) {
  sb_put(b, "\"", 1);
  const unsigned char *p = (const unsigned char *)(s ? s : "");
  size_t used = 0;
  while (*p && used < max_bytes) {
    if (*p == '"' || *p == '\\') {
      char esc[2] = {'\\', (char)*p};
      sb_put(b, esc, 2);
      p++;
      used++;
    } else if (*p < 0x20) {
      sb_printf(b, "\\u%04x", *p);
      p++;
      used++;
    } else {
      int n = utf8_len(p);
      if (n == 0) {
        sb_put(b, "\xEF\xBF\xBD", 3);
        p++;
        used++;
      } else {
        sb_put(b, (const char *)p, (size_t)n);
        p += n;
        used += (size_t)n;
      }
    }
  }
  sb_put(b, "\"", 1);
}

static char *sb_take(sbuf *b) {
  if (b->failed) {
    free(b->data);
    return NULL;
  }
  return b->data;
}

static char *dup_text(const char *s) {
  size_t n = strlen(s);
  char *copy = malloc(n + 1);
  if (copy) memcpy(copy, s, n + 1);
  return copy;
}

// ---------------------------------------------------- flat JSON object reader

static const char *skip_ws(const char *p) {
  while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
  return p;
}

static int hexval(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static const char *parse_string(const char *p, char *out, size_t cap,
                                int *ok) {
  size_t n = 0;
  *ok = 0;
  if (*p != '"') return p;
  p++;
  while (*p && *p != '"') {
    unsigned code = (unsigned char)*p++;
    if (code == '\\') {
      char e = *p++;
      switch (e) {
        case 'n': code = '\n'; break;
        case 't': code = '\t'; break;
        case 'r': code = '\r'; break;
        case 'b': code = '\b'; break;
        case 'f': code = '\f'; break;
        case 'u': {
          code = 0;
          for (int i = 0; i < 4; i++) {
            int h = hexval(*p++);
            if (h < 0) return p;
            code = code * 16 + (unsigned)h;
          }
          if (code >= 0xD800 && code <= 0xDBFF && p[0] == '\\' &&
              p[1] == 'u') {
            unsigned low = 0;
            for (int i = 0; i < 4; i++) {
              int h = hexval(p[2 + i]);
              if (h < 0) return p;
              low = low * 16 + (unsigned)h;
            }
            if (low >= 0xDC00 && low <= 0xDFFF) {
              code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
              p += 6;
            }
          }
          break;
        }
        case 0: return p;
        default: code = (unsigned char)e;
      }
    }
    char enc[4];
    size_t len;
    if (code < 0x80) {
      enc[0] = (char)code;
      len = 1;
    } else if (code < 0x800) {
      enc[0] = (char)(0xC0 | (code >> 6));
      enc[1] = (char)(0x80 | (code & 0x3F));
      len = 2;
    } else if (code < 0x10000) {
      enc[0] = (char)(0xE0 | (code >> 12));
      enc[1] = (char)(0x80 | ((code >> 6) & 0x3F));
      enc[2] = (char)(0x80 | (code & 0x3F));
      len = 3;
    } else {
      enc[0] = (char)(0xF0 | (code >> 18));
      enc[1] = (char)(0x80 | ((code >> 12) & 0x3F));
      enc[2] = (char)(0x80 | ((code >> 6) & 0x3F));
      enc[3] = (char)(0x80 | (code & 0x3F));
      len = 4;
    }
    if (n + len >= cap) return p;
    memcpy(out + n, enc, len);
    n += len;
  }
  if (*p != '"') return p;
  out[n] = 0;
  *ok = 1;
  return p + 1;
}

// Top-level key lookup; 1 for strings, 2 for other scalars, 0 otherwise.
static int json_find(const char *json, const char *key, char *out,
                     size_t cap) {
  char name[128];
  int ok;
  const char *p = skip_ws(json);
  if (*p++ != '{') return 0;
  for (;;) {
    p = skip_ws(p);
    if (*p == '}') return 0;
    p = parse_string(p, name, sizeof name, &ok);
    if (!ok) return 0;
    p = skip_ws(p);
    if (*p++ != ':') return 0;
    p = skip_ws(p);
    int match = strcmp(name, key) == 0;
    if (*p == '"') {
      char scratch[OPX_ASR_MAX_TEXT];
      p = parse_string(p, match ? out : scratch, match ? cap : sizeof scratch,
                       &ok);
      if (!ok) return 0;
      if (match) return 1;
    } else {
      const char *start = p;
      while (*p && *p != ',' && *p != '}' && *p != ' ' && *p != '\n') p++;
      if (p == start || *start == '{' || *start == '[') return 0;
      if (match) {
        size_t n = (size_t)(p - start);
        if (n >= cap) return 0;
        memcpy(out, start, n);
        out[n] = 0;
        return 2;
      }
    }
    p = skip_ws(p);
    if (*p == ',') {
      p++;
      continue;
    }
    return 0;
  }
}

static int64_t json_i64(const char *json, const char *key, int64_t fallback) {
  char v[64];
  if (json_find(json, key, v, sizeof v) != 2) return fallback;
  char *end;
  errno = 0;
  long long n = strtoll(v, &end, 10);
  if (errno || *end) return fallback;
  return n;
}

static int json_str(const char *json, const char *key, char *out,
                    size_t cap) {
  out[0] = 0;
  return json_find(json, key, out, cap) == 1;
}

static int is_absolute_path(const char *path) {
  return path[0] == '/' && !strstr(path, "://");
}

// --------------------------------------------------------------------- WAV

typedef struct {
  FILE *f;
  long data_offset;
  int64_t samples;
} wav_input;

static uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
static uint16_t le16(const unsigned char *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

// Accepts only the normalised speech format; anything else is refused so a
// wrong sample rate or channel count can never be "fixed" by a header.
static int wav_open(const char *path, wav_input *w) {
  memset(w, 0, sizeof *w);
  FILE *f = fopen(path, "rb");
  if (!f) return OPX_ASR_E_INPUT_UNAVAILABLE;
  unsigned char hdr[12];
  if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) ||
      memcmp(hdr + 8, "WAVE", 4)) {
    fclose(f);
    return OPX_ASR_E_INPUT_UNSUPPORTED;
  }
  int fmt_ok = 0;
  for (;;) {
    unsigned char ch[8];
    if (fread(ch, 1, 8, f) != 8) break;
    uint32_t size = le32(ch + 4);
    if (!memcmp(ch, "fmt ", 4)) {
      unsigned char fmt[16];
      if (size < 16 || fread(fmt, 1, 16, f) != 16) break;
      uint16_t format = le16(fmt), channels = le16(fmt + 2), bits = le16(fmt + 14);
      uint32_t rate = le32(fmt + 4);
      if (format != 1 || channels != 1 || bits != 16 || rate != 16000) {
        fclose(f);
        return OPX_ASR_E_INPUT_UNSUPPORTED;
      }
      fmt_ok = 1;
      if (fseek(f, (long)(size - 16 + (size & 1)), SEEK_CUR)) break;
    } else if (!memcmp(ch, "data", 4)) {
      if (!fmt_ok) break;
      w->f = f;
      w->data_offset = ftell(f);
      // Streamed WAVs may carry 0 / 0xFFFFFFFF: fall back to the file size.
      fseek(f, 0, SEEK_END);
      long end = ftell(f);
      int64_t avail = (end - w->data_offset) / 2;
      int64_t declared = size / 2;
      w->samples = (size == 0 || size == 0xFFFFFFFFu || declared > avail)
                       ? avail
                       : declared;
      return OPX_ASR_OK;
    } else {
      if (fseek(f, (long)(size + (size & 1)), SEEK_CUR)) break;
    }
  }
  fclose(f);
  return OPX_ASR_E_INPUT_UNSUPPORTED;
}

static int wav_read(wav_input *w, int64_t first, int64_t count, float *out) {
  if (fseek(w->f, w->data_offset + (long)(first * 2), SEEK_SET)) return -1;
  int16_t buf[4096];
  int64_t done = 0;
  while (done < count) {
    size_t want = (size_t)((count - done) < 4096 ? (count - done) : 4096);
    size_t got = fread(buf, 2, want, w->f);
    for (size_t i = 0; i < got; i++) {
      const unsigned char *b = (const unsigned char *)&buf[i];
      int16_t v = (int16_t)(b[0] | (b[1] << 8));  // little-endian on disk
      out[done + (int64_t)i] = (float)v / 32768.0f;
    }
    done += (int64_t)got;
    if (got < want) break;
  }
  return (int)(done == count ? 0 : -1);
}

// ------------------------------------------------------------------- model

struct opx_asr_model {
  struct whisper_context *ctx;
  pthread_mutex_t lock;      // one recognition at a time per context
  pthread_mutex_t ref_lock;
  int refs;
};

static void model_release(opx_asr_model *m) {
  pthread_mutex_lock(&m->ref_lock);
  int left = --m->refs;
  pthread_mutex_unlock(&m->ref_lock);
  if (left > 0) return;
  whisper_free(m->ctx);
  pthread_mutex_destroy(&m->lock);
  pthread_mutex_destroy(&m->ref_lock);
  free(m);
}

static void quiet_log(enum ggml_log_level level, const char *text, void *ud) {
  (void)level; (void)text; (void)ud;  // never surface raw native logs
}

uint32_t opx_asr_abi_version(void) { return OPX_ASR_ABI; }

char *opx_asr_info(void) {
  sbuf b = {0};
  sb_printf(&b, "{\"abi\":1,\"available\":true,\"engine\":\"whisper.cpp\",\"engine_version\":");
  sb_json(&b, whisper_version(), 64);
  sb_printf(&b, ",\"system\":");
  sb_json(&b, whisper_print_system_info(), 400);
  sb_put(&b, "}", 1);
  return sb_take(&b);
}

void opx_asr_string_free(char *value) { free(value); }

int32_t opx_asr_model_open(const char *options_json, opx_asr_model **model) {
  if (!options_json || !model) return OPX_ASR_E_INVALID_ARGUMENT;
  *model = NULL;
  if (strlen(options_json) > OPX_ASR_MAX_REQUEST) return OPX_ASR_E_INVALID_ARGUMENT;
  char path[OPX_ASR_MAX_TEXT];
  if (!json_str(options_json, "path", path, sizeof path) ||
      !is_absolute_path(path)) {
    return OPX_ASR_E_INVALID_ARGUMENT;
  }
  FILE *probe = fopen(path, "rb");
  if (!probe) return OPX_ASR_E_MODEL_UNAVAILABLE;
  fclose(probe);
  whisper_log_set(quiet_log, NULL);
  struct whisper_context_params cp = whisper_context_default_params();
  cp.use_gpu = false;  // CPU baseline; accelerators need separate validation
  cp.flash_attn = false;
  struct whisper_context *ctx =
      whisper_init_from_file_with_params_no_state(path, cp);
  if (!ctx) return OPX_ASR_E_MODEL_UNAVAILABLE;
  opx_asr_model *m = calloc(1, sizeof *m);
  if (!m) {
    whisper_free(ctx);
    return OPX_ASR_E_NO_MEMORY;
  }
  m->ctx = ctx;
  m->refs = 1;
  pthread_mutex_init(&m->lock, NULL);
  pthread_mutex_init(&m->ref_lock, NULL);
  *model = m;
  return OPX_ASR_OK;
}

char *opx_asr_model_info(opx_asr_model *model) {
  if (!model) return NULL;
  sbuf b = {0};
  sb_put(&b, "{\"type\":", 8);
  sb_json(&b, whisper_model_type_readable(model->ctx), 32);
  sb_printf(&b, ",\"multilingual\":%s}",
            whisper_is_multilingual(model->ctx) ? "true" : "false");
  return sb_take(&b);
}

void opx_asr_model_close(opx_asr_model *model) {
  if (model) model_release(model);
}

// --------------------------------------------------------------------- job

struct opx_asr_job {
  opx_asr_model *model;
  char input[OPX_ASR_MAX_TEXT];
  char language[16];
  int threads;
  int64_t window_ms, overlap_ms;
  double silence_dbfs;

  pthread_t thread;
  int started, joined;
  volatile int cancel;

  pthread_mutex_t lock;
  opx_asr_event event;
  int64_t polled_sequence;
  char *result;
};

static void job_set(opx_asr_job *j, int state, int error, int64_t processed,
                    int64_t total) {
  pthread_mutex_lock(&j->lock);
  j->event.state = state;
  j->event.error = error;
  if (processed >= 0) j->event.processed_ms = processed;
  if (total >= 0) j->event.total_ms = total;
  j->event.sequence++;
  pthread_mutex_unlock(&j->lock);
}

static bool abort_cb(void *user_data) {
  return ((opx_asr_job *)user_data)->cancel != 0;
}

static double rms_dbfs(const float *x, int64_t n) {
  if (n <= 0) return -120.0;
  double sum = 0;
  for (int64_t i = 0; i < n; i++) sum += (double)x[i] * x[i];
  double rms = sqrt(sum / (double)n);
  return rms <= 1e-9 ? -120.0 : 20.0 * log10(rms);
}

// First 20 ms frame at or above the gate, minus 200 ms of context. whisper
// tends to stretch the first segment back to the start of its input when it
// begins with a long silence, so leading silence is cut and its length added
// to the window offset explicitly.
static int64_t leading_silence(const float *x, int64_t n, double gate_dbfs) {
  const int64_t frame = 320, pad = 3200;
  for (int64_t i = 0; i + frame <= n; i += frame) {
    if (rms_dbfs(x + i, frame) >= gate_dbfs) return i > pad ? i - pad : 0;
  }
  return 0;
}

static void *job_main(void *arg) {
  opx_asr_job *j = arg;
  wav_input wav;
  int err = wav_open(j->input, &wav);
  if (err) {
    job_set(j, OPX_ASR_STATE_FAILED, err, -1, -1);
    return NULL;
  }
  const int64_t rate = 16000;
  int64_t total_ms = wav.samples * 1000 / rate;
  job_set(j, OPX_ASR_STATE_WAITING, 0, 0, total_ms);

  pthread_mutex_lock(&j->model->lock);
  struct whisper_state *state = NULL;
  float *pcm = NULL;
  sbuf out = {0};
  int result_err = OPX_ASR_OK;
  char detected[16] = "";

  if (j->cancel) {
    result_err = OPX_ASR_E_CANCELLED;
    goto done;
  }
  state = whisper_init_state(j->model->ctx);
  if (!state) {
    result_err = OPX_ASR_E_NO_MEMORY;
    goto done;
  }
  int64_t win = j->window_ms * rate / 1000;
  int64_t lap = j->overlap_ms * rate / 1000;
  pcm = malloc((size_t)(win + lap) * sizeof(float));
  if (!pcm) {
    result_err = OPX_ASR_E_NO_MEMORY;
    goto done;
  }
  job_set(j, OPX_ASR_STATE_RUNNING, 0, 0, -1);
  sb_printf(&out, "{\"audio_ms\":%lld,\"window_ms\":%lld,\"overlap_ms\":%lld,\"windows\":[",
            (long long)total_ms, (long long)j->window_ms, (long long)j->overlap_ms);
  int first_window = 1;
  for (int64_t start = 0; start < wav.samples; start += win) {
    if (j->cancel) {
      result_err = OPX_ASR_E_CANCELLED;
      goto done;
    }
    int64_t count = win + lap;
    if (start + count > wav.samples) count = wav.samples - start;
    if (wav_read(&wav, start, count, pcm) != 0) {
      result_err = OPX_ASR_E_INPUT_UNAVAILABLE;
      goto done;
    }
    int64_t offset_ms = start * 1000 / rate;
    int64_t dur_ms = count * 1000 / rate;
    // whisper needs at least ~100 ms; the silence gate also skips tails.
    int skipped = count < rate / 10 || rms_dbfs(pcm, count) < j->silence_dbfs;
    sb_printf(&out, "%s{\"offset_ms\":%lld,\"duration_ms\":%lld,\"skipped\":%s,\"segments\":[",
              first_window ? "" : ",", (long long)offset_ms, (long long)dur_ms,
              skipped ? "true" : "false");
    first_window = 0;
    if (!skipped) {
      struct whisper_full_params p =
          whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
      p.n_threads = j->threads;
      p.translate = false;  // transcription only, never translation
      p.no_context = true;  // windows are independent (bounded memory)
      p.print_special = p.print_progress = p.print_realtime =
          p.print_timestamps = false;
      p.suppress_nst = true;
      p.language = detected[0] ? detected : j->language;
      p.detect_language = false;
      p.abort_callback = abort_cb;
      p.abort_callback_user_data = j;
      int64_t lead = leading_silence(pcm, count, j->silence_dbfs);
      int64_t lead_ms = lead * 1000 / rate;
      int rc = whisper_full_with_state(j->model->ctx, state, p, pcm + lead,
                                       (int)(count - lead));
      if (j->cancel) {
        result_err = OPX_ASR_E_CANCELLED;
        goto done;
      }
      if (rc != 0) {
        result_err = OPX_ASR_E_NATIVE_FAILURE;
        goto done;
      }
      if (!detected[0] && strcmp(j->language, "auto") == 0) {
        // Keep one language for the whole job instead of re-guessing per window.
        const char *lang = whisper_lang_str(whisper_full_lang_id_from_state(state));
        if (lang) snprintf(detected, sizeof detected, "%s", lang);
      }
      int n = whisper_full_n_segments_from_state(state);
      int first_seg = 1;
      for (int i = 0; i < n; i++) {
        int64_t t0 = whisper_full_get_segment_t0_from_state(state, i) * 10 + lead_ms;
        int64_t t1 = whisper_full_get_segment_t1_from_state(state, i) * 10 + lead_ms;
        if (t0 < 0) t0 = 0;
        if (t1 > dur_ms) t1 = dur_ms;
        if (t1 < t0) t1 = t0;
        const char *text = whisper_full_get_segment_text_from_state(state, i);
        float nsp = whisper_full_get_segment_no_speech_prob_from_state(state, i);
        if (!(nsp >= 0 && nsp <= 1)) nsp = 0;  // NaN guard
        sb_printf(&out, "%s{\"start_ms\":%lld,\"end_ms\":%lld,\"no_speech_prob\":%.3f,\"text\":",
                  first_seg ? "" : ",", (long long)(offset_ms + t0),
                  (long long)(offset_ms + t1), nsp);
        sb_json(&out, text, 2000);
        sb_put(&out, "}", 1);
        first_seg = 0;
      }
    }
    sb_put(&out, "]}", 2);
    int64_t done_ms = (start + win) * 1000 / rate;
    job_set(j, OPX_ASR_STATE_RUNNING, 0, done_ms < total_ms ? done_ms : total_ms, -1);
  }
  sb_put(&out, "],\"language\":", 13);
  sb_json(&out, detected[0] ? detected : j->language, 15);
  sb_put(&out, "}", 1);
  if (out.failed) result_err = OPX_ASR_E_NO_MEMORY;

done:
  if (state) whisper_free_state(state);
  pthread_mutex_unlock(&j->model->lock);
  free(pcm);
  fclose(wav.f);
  if (result_err == OPX_ASR_OK) {
    pthread_mutex_lock(&j->lock);
    j->result = sb_take(&out);
    pthread_mutex_unlock(&j->lock);
    job_set(j, OPX_ASR_STATE_SUCCEEDED, 0, total_ms, -1);
  } else {
    free(out.data);
    job_set(j,
            result_err == OPX_ASR_E_CANCELLED ? OPX_ASR_STATE_CANCELLED
                                              : OPX_ASR_STATE_FAILED,
            result_err, -1, -1);
  }
  return NULL;
}

int32_t opx_asr_job_create(opx_asr_model *model, const char *request_json,
                           opx_asr_job **job) {
  if (!model || !request_json || !job) return OPX_ASR_E_INVALID_ARGUMENT;
  *job = NULL;
  if (strlen(request_json) > OPX_ASR_MAX_REQUEST) return OPX_ASR_E_INVALID_ARGUMENT;
  opx_asr_job *j = calloc(1, sizeof *j);
  if (!j) return OPX_ASR_E_NO_MEMORY;
  if (!json_str(request_json, "input", j->input, sizeof j->input) ||
      !is_absolute_path(j->input)) {
    free(j);
    return OPX_ASR_E_INVALID_ARGUMENT;
  }
  char translate[16];
  if (json_find(request_json, "translate", translate, sizeof translate) == 2 &&
      strcmp(translate, "false") != 0) {
    free(j);
    return OPX_ASR_E_INVALID_ARGUMENT;
  }
  if (!json_str(request_json, "language", j->language, sizeof j->language) ||
      !j->language[0]) {
    snprintf(j->language, sizeof j->language, "auto");
  }
  if (strcmp(j->language, "auto") != 0) {
    if (whisper_lang_id(j->language) < 0) {
      free(j);
      return OPX_ASR_E_LANGUAGE;
    }
    if (!whisper_is_multilingual(model->ctx) && strcmp(j->language, "en") != 0) {
      free(j);
      return OPX_ASR_E_LANGUAGE;  // `.en` models cannot transcribe e.g. zh
    }
  }
  j->threads = (int)json_i64(request_json, "threads", 4);
  if (j->threads < 1) j->threads = 1;
  if (j->threads > 16) j->threads = 16;
  j->window_ms = json_i64(request_json, "window_ms", 30000);
  j->overlap_ms = json_i64(request_json, "overlap_ms", 1000);
  if (j->window_ms < 5000 || j->window_ms > 30000 || j->overlap_ms < 0 ||
      j->overlap_ms > 5000) {
    free(j);
    return OPX_ASR_E_INVALID_ARGUMENT;
  }
  j->silence_dbfs = (double)json_i64(request_json, "silence_dbfs", -55);
  pthread_mutex_init(&j->lock, NULL);
  pthread_mutex_lock(&model->ref_lock);
  model->refs++;
  pthread_mutex_unlock(&model->ref_lock);
  j->model = model;
  *job = j;
  return OPX_ASR_OK;
}

int32_t opx_asr_job_start(opx_asr_job *job) {
  if (!job || job->started) return OPX_ASR_E_BAD_STATE;
  job->started = 1;
  if (pthread_create(&job->thread, NULL, job_main, job) != 0) {
    job->started = 0;
    return OPX_ASR_E_NATIVE_FAILURE;
  }
  return OPX_ASR_OK;
}

int32_t opx_asr_job_poll(opx_asr_job *job, opx_asr_event *event) {
  if (!job || !event) return -1;
  pthread_mutex_lock(&job->lock);
  *event = job->event;
  int changed = job->event.sequence != job->polled_sequence;
  job->polled_sequence = job->event.sequence;
  pthread_mutex_unlock(&job->lock);
  return changed;
}

int32_t opx_asr_job_cancel(opx_asr_job *job) {
  if (!job) return OPX_ASR_E_INVALID_ARGUMENT;
  job->cancel = 1;
  return OPX_ASR_OK;
}

int32_t opx_asr_job_join(opx_asr_job *job) {
  if (!job || !job->started) return OPX_ASR_E_BAD_STATE;
  if (!job->joined) {
    pthread_join(job->thread, NULL);
    job->joined = 1;
  }
  return OPX_ASR_OK;
}

int32_t opx_asr_job_result(opx_asr_job *job, char **result_json) {
  if (!job || !result_json) return OPX_ASR_E_INVALID_ARGUMENT;
  *result_json = NULL;
  if (!job->joined || job->event.state != OPX_ASR_STATE_SUCCEEDED ||
      !job->result) {
    return OPX_ASR_E_BAD_STATE;
  }
  *result_json = dup_text(job->result);
  return *result_json ? OPX_ASR_OK : OPX_ASR_E_NO_MEMORY;
}

void opx_asr_job_destroy(opx_asr_job *job) {
  if (!job) return;
  if (job->started && !job->joined) return;  // misuse: leak rather than crash
  free(job->result);
  pthread_mutex_destroy(&job->lock);
  model_release(job->model);
  free(job);
}
