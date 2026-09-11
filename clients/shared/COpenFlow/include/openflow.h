// C ABI over openflow-core. Shared by the macOS and iOS clients.
#ifndef OPENFLOW_H
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
char *of_polish_prompt(const char *transcript, const char *vocabulary);

/// Salvage usable text from a model reply, falling back to the transcript when
/// the reply is empty, a refusal, or obviously not a repair.
/// Returns owned UTF-8; free with of_string_free. Never null.
char *of_polish_clean(const char *reply, const char *transcript);

#ifdef __cplusplus
}
#endif
#endif
