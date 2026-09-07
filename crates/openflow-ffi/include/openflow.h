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

#ifdef __cplusplus
}
#endif
#endif
