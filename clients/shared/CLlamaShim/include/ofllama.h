// A deliberately tiny C surface over llama.cpp.
//
// `llama.h` includes `ggml.h`, and whisper.cpp vendors a *different* version of
// ggml. Exposing both to Swift as modules makes Clang reject the build --
// "'ggml_prec' has different definitions in different modules" -- because the
// two really are different types with the same name.
//
// So llama.h is never shown to Swift. It is included privately by ofllama.c,
// and nothing in this header mentions a ggml type. Each framework keeps its own
// ggml at runtime, which is what a dynamic framework is for.
#ifndef OFLLAMA_H
#define OFLLAMA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ofl_ctx ofl_ctx;

/// Load a GGUF model. `gpu_layers` 0 means CPU only, which is what iOS gets in
/// the background. Returns NULL if the model will not load.
ofl_ctx *ofl_open(const char *model_path, int gpu_layers, int n_ctx, int n_threads);

void ofl_close(ofl_ctx *c);

/// Generate a completion for `prompt`, applying the model's own chat template
/// when it ships one.
///
/// Writes at most `out_len - 1` bytes plus a terminator. Returns the number of
/// tokens produced, or -1 on failure. `seconds` receives the generation time,
/// so the caller can report a rate it measured rather than one it estimated.
int ofl_generate(ofl_ctx *c, const char *prompt, int max_tokens,
                 char *out, size_t out_len, double *seconds);

#ifdef __cplusplus
}
#endif
#endif
