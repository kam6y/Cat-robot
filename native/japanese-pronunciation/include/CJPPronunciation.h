#ifndef CJP_PRONUNCIATION_H
#define CJP_PRONUNCIATION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Status: 0 success, 1 invalid input, 2 initialization/conversion error, 3 panic.
// Input pointers must reference live memory. Outputs are cleared on failure.
// The caller must serialize calls on each handle; destroy it exactly once.
int32_t cjp_create(const char *dictionary_path, void **out_handle);
// input is UTF-8, at most 32768 bytes. Output is Rust-owned, NUL-terminated UTF-8.
int32_t cjp_convert(void *handle, const uint8_t *input, size_t length, char **out_text);
void cjp_string_free(char *text);
void cjp_destroy(void *handle);
#ifdef __cplusplus
}
#endif
#endif
