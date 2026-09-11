// C ABI over openflow-core. Shared by the macOS and iOS clients.
#ifndef OPENFLOW_H
#include <stddef.h>
#define OPENFLOW_H
#ifdef __cplusplus
extern "C" {
#endif

/// tone: 0 = formal, 1 = casual, 2 = very casual.
/// Returns owned JSON; free with of_string_free. Never null.
char *of_format(const char *input, unsigned int tone);
void  of_string_free(char *p);
const char *of_version(void);

/// Build the polish prompt. `vocabulary` is newline-separated and may be NULL.
/// Returns owned UTF-8; free with of_string_free. Never null.
/// `simple` non-zero asks for the narrower two-job instructions, for models
/// too small to follow the full repair.
char *of_polish_prompt(const char *transcript, const char *vocabulary, unsigned int simple);

/// Salvage usable text from a model reply, falling back to the transcript when
/// the reply is empty, a refusal, or obviously not a repair.
/// Returns owned UTF-8; free with of_string_free. Never null.
char *of_polish_clean(const char *reply, const char *transcript);

/// Where this speaker's paragraph breaks fall, derived from the gaps between
/// their own spoken segments. `gaps` is `count` values in milliseconds; null or
/// too few yields a fixed default.
long long of_paragraph_threshold_ms(const long long *gaps, size_t count);

#ifdef __cplusplus
}
#endif
#endif
