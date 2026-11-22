// OpenPlayX in-process speech recognition bridge: a small, versioned C ABI
// owned by this package over the pinned whisper.cpp library. whisper/ggml
// structures never cross this boundary; callers see opaque handles, UTF-8
// JSON documents and the fixed event struct below.
//
// No function here starts a process, a shell, whisper-cli or whisper-server.
// The same ABI is linked by the App (Dart FFI) and by the standalone HTTP
// recognition service (cgo), so both report identical result structures.
#ifndef OPX_ASR_H
#define OPX_ASR_H

#include <stdint.h>

#if defined(_WIN32)
#define OPX_ASR_API __declspec(dllexport)
#else
#define OPX_ASR_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define OPX_ASR_ABI 1

// Result / error codes (stable across ABI 1).
enum {
  OPX_ASR_OK = 0,
  OPX_ASR_E_INVALID_ARGUMENT = 1,
  OPX_ASR_E_INPUT_UNAVAILABLE = 2,
  OPX_ASR_E_INPUT_UNSUPPORTED = 3,  // not 16 kHz mono s16 PCM WAV
  OPX_ASR_E_MODEL_UNAVAILABLE = 4,  // missing / unreadable / invalid model
  OPX_ASR_E_LANGUAGE = 5,           // language unknown or model is English-only
  OPX_ASR_E_NATIVE_FAILURE = 7,
  OPX_ASR_E_CANCELLED = 9,
  OPX_ASR_E_BAD_STATE = 11,
  OPX_ASR_E_NO_MEMORY = 12,
  OPX_ASR_E_UNAVAILABLE = 13,       // built without whisper.cpp (stub)
};

// Job states reported by opx_asr_job_poll.
enum {
  OPX_ASR_STATE_CREATED = 0,
  OPX_ASR_STATE_WAITING = 1,   // waiting for the model (one job at a time)
  OPX_ASR_STATE_RUNNING = 2,
  OPX_ASR_STATE_SUCCEEDED = 4,
  OPX_ASR_STATE_FAILED = 5,
  OPX_ASR_STATE_CANCELLED = 6,
};

typedef struct opx_asr_model opx_asr_model;
typedef struct opx_asr_job opx_asr_job;

// Newest state replaces older progress; the worker never blocks on it.
typedef struct {
  int32_t state;
  int32_t error;
  int64_t processed_ms;  // audio handled so far (input-local time)
  int64_t total_ms;      // input duration, <= 0 when unknown
  int64_t sequence;      // increments on each change
} opx_asr_event;

OPX_ASR_API uint32_t opx_asr_abi_version(void);

// {"abi":1,"available":true,"engine":"whisper.cpp","engine_version":"1.9.5",
//  "system":"..."}. Free with opx_asr_string_free.
OPX_ASR_API char *opx_asr_info(void);
OPX_ASR_API void opx_asr_string_free(char *value);

// Blocking (reads the whole model): call from a worker thread/isolate.
// options_json: {"path":"/abs/model.bin","gpu":true}. "gpu" (default true)
// uses the build's GPU backend (Metal / Vulkan) when a device is available;
// false forces the CPU. Apple simulators always use the CPU.
OPX_ASR_API int32_t opx_asr_model_open(const char *options_json,
                                       opx_asr_model **model);
// {"type":"base","multilingual":true,"backend":"MTL0","device":"Apple M4 Max"}
// ("backend":"CPU","device":"" without a GPU). Free with opx_asr_string_free.
OPX_ASR_API char *opx_asr_model_info(opx_asr_model *model);
// Releases the caller's reference. The model is freed once no job uses it,
// so closing while a job still runs is safe.
OPX_ASR_API void opx_asr_model_close(opx_asr_model *model);

// request_json (deep-copied):
//   {"input":"/abs/audio.wav",          16 kHz mono 16-bit PCM WAV only
//    "language":"zh" | "auto",
//    "threads":4, "window_ms":30000, "overlap_ms":1000,
//    "silence_dbfs":-55}                windows quieter than this are skipped
// Translation is not offered: the bridge only transcribes.
OPX_ASR_API int32_t opx_asr_job_create(opx_asr_model *model,
                                       const char *request_json,
                                       opx_asr_job **job);
OPX_ASR_API int32_t opx_asr_job_start(opx_asr_job *job);
// Non-blocking. 1 when changed since the previous poll, 0 when unchanged,
// negative on invalid arguments.
OPX_ASR_API int32_t opx_asr_job_poll(opx_asr_job *job, opx_asr_event *event);
// Cooperative: whisper's abort callback and the window loop observe it.
OPX_ASR_API int32_t opx_asr_job_cancel(opx_asr_job *job);
// Waits for the worker thread. Immediate after a terminal poll.
OPX_ASR_API int32_t opx_asr_job_join(opx_asr_job *job);
// Only after SUCCEEDED and join. Times are integer milliseconds relative to
// the start of the input audio (whisper's 10 ms units are converted here):
//   {"language":"zh","audio_ms":60000,"window_ms":30000,"overlap_ms":1000,
//    "windows":[{"offset_ms":0,"duration_ms":31000,"skipped":false,
//                "segments":[{"start_ms":1200,"end_ms":4800,"text":"...",
//                             "no_speech_prob":0.01}]}]}
// segment times are absolute within the input (window offset applied once).
OPX_ASR_API int32_t opx_asr_job_result(opx_asr_job *job, char **result_json);
// Only for jobs never started or already joined.
OPX_ASR_API void opx_asr_job_destroy(opx_asr_job *job);

#ifdef __cplusplus
}
#endif

#endif
