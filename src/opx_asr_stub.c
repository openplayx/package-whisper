// Built when no pinned whisper.cpp exists for the target: the ABI is present
// but reports itself unavailable, so the app builds and runs and the debug
// page / settings show the real state instead of failing to link.
#include <stdlib.h>
#include <string.h>

#include "opx_asr.h"

uint32_t opx_asr_abi_version(void) { return OPX_ASR_ABI; }
char *opx_asr_info(void) {
  const char *text = "{\"abi\":1,\"available\":false,\"engine\":\"whisper.cpp\"}";
  char *copy = malloc(strlen(text) + 1);
  if (copy) strcpy(copy, text);
  return copy;
}
void opx_asr_string_free(char *value) { free(value); }
int32_t opx_asr_model_open(const char *o, opx_asr_model **m) {
  (void)o;
  if (m) *m = NULL;
  return OPX_ASR_E_UNAVAILABLE;
}
char *opx_asr_model_info(opx_asr_model *m) { (void)m; return NULL; }
void opx_asr_model_close(opx_asr_model *m) { (void)m; }
int32_t opx_asr_job_create(opx_asr_model *m, const char *r, opx_asr_job **j) {
  (void)m; (void)r;
  if (j) *j = NULL;
  return OPX_ASR_E_UNAVAILABLE;
}
int32_t opx_asr_job_start(opx_asr_job *j) { (void)j; return OPX_ASR_E_BAD_STATE; }
int32_t opx_asr_job_poll(opx_asr_job *j, opx_asr_event *e) { (void)j; (void)e; return -1; }
int32_t opx_asr_job_cancel(opx_asr_job *j) { (void)j; return OPX_ASR_E_BAD_STATE; }
int32_t opx_asr_job_join(opx_asr_job *j) { (void)j; return OPX_ASR_E_BAD_STATE; }
int32_t opx_asr_job_result(opx_asr_job *j, char **r) {
  (void)j;
  if (r) *r = NULL;
  return OPX_ASR_E_BAD_STATE;
}
void opx_asr_job_destroy(opx_asr_job *j) { (void)j; }
