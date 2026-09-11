// The only file in this project that includes llama.h.
//
// Keeping it to one translation unit is the entire point: whisper.cpp and
// llama.cpp vendor different versions of ggml, and letting both reach Swift as
// modules makes Clang reject the build outright. Here, ggml's types never leave
// the file.

#include "include/ofllama.h"

#include "llama.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

struct ofl_ctx {
    struct llama_model *model;
    struct llama_context *ctx;
    const struct llama_vocab *vocab;
    struct llama_sampler *sampler;
};

static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

ofl_ctx *ofl_open(const char *model_path, int gpu_layers, int n_ctx, int n_threads) {
    if (!model_path) return NULL;

    // Once per process. llama.cpp tolerates repeats but narrates them into the
    // system log, and a dictation app has no business doing that.
    static int backend_ready = 0;
    if (!backend_ready) {
        llama_backend_init();
        backend_ready = 1;
    }

    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpu_layers;

    struct llama_model *model = llama_model_load_from_file(model_path, mp);
    if (!model) return NULL;

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)n_ctx;
    // A dictated line is short; a larger batch would only cost memory.
    cp.n_batch = (uint32_t)n_ctx;
    cp.n_threads = n_threads;
    cp.n_threads_batch = n_threads;

    struct llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        return NULL;
    }

    const struct llama_vocab *vocab = llama_model_get_vocab(model);
    if (!vocab) {
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }

    // Greedy, deliberately. This is a repair task with a right answer;
    // temperature buys variety, and variety in a transcription is an error.
    struct llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    sp.no_perf = true;
    struct llama_sampler *sampler = llama_sampler_chain_init(sp);
    if (!sampler) {
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    ofl_ctx *c = calloc(1, sizeof(ofl_ctx));
    if (!c) {
        llama_sampler_free(sampler);
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }
    c->model = model;
    c->ctx = ctx;
    c->vocab = vocab;
    c->sampler = sampler;
    return c;
}

void ofl_close(ofl_ctx *c) {
    if (!c) return;
    llama_sampler_free(c->sampler);
    llama_free(c->ctx);
    llama_model_free(c->model);
    free(c);
}

/// Wrap the prompt the way the model was trained to expect. An instruct model
/// handed a bare string answers a different question than the same string in
/// its own chat format -- often the difference between a repair and an essay.
///
/// Returns a malloc'd string the caller frees, or NULL to send the prompt as-is.
static char *chat_wrapped(struct llama_model *model, const char *prompt) {
    const char *tmpl = llama_model_chat_template(model, NULL);
    // Visible, because falling back to a bare prompt is not a detail: an
    // instruct model handed raw instructions *continues* them instead of
    // following them, and the reply comes back as a copy of the prompt.
    fprintf(stderr, "openflow: chat template %s\n", tmpl ? "found" : "MISSING");
    if (!tmpl) return NULL;

    struct llama_chat_message msg = { .role = "user", .content = prompt };
    size_t cap = strlen(prompt) * 2 + 2048;
    char *buf = malloc(cap);
    if (!buf) return NULL;

    int32_t n = llama_chat_apply_template(tmpl, &msg, 1, true, buf, (int32_t)cap);
    if (n <= 0 || (size_t)n >= cap) {
        fprintf(stderr, "openflow: chat template failed to apply (%d)\n", n);
        free(buf);
        return NULL;
    }
    buf[n] = '\0';
    return buf;
}

int ofl_generate(ofl_ctx *c, const char *prompt, int max_tokens,
                 char *out, size_t out_len, double *seconds) {
    if (!c || !prompt || !out || out_len == 0) return -1;
    out[0] = '\0';

    char *wrapped = chat_wrapped(c->model, prompt);
    const char *text = wrapped ? wrapped : prompt;
    const int32_t text_len = (int32_t)strlen(text);

    // Upper bound: never more tokens than bytes, plus room for specials.
    int32_t cap = text_len + 8;
    llama_token *tokens = malloc((size_t)cap * sizeof(llama_token));
    if (!tokens) {
        free(wrapped);
        return -1;
    }
    // `add_special` only when the template did not run. A chat template
    // already emits the model's opening special tokens, so asking for them
    // again prepends a second BOS -- a sequence the model never saw in
    // training, and one that degrades instruction-following exactly the way a
    // reply echoing the prompt looks.
    const bool add_special = (wrapped == NULL);
    int32_t n_prompt = llama_tokenize(c->vocab, text, text_len, tokens, cap,
                                      add_special, true);
    fprintf(stderr, "openflow: prompt tokenised to %d tokens (bos=%s)\n",
            n_prompt, add_special ? "added" : "from template");
    free(wrapped);
    if (n_prompt <= 0) {
        free(tokens);
        return -1;
    }

    // Each utterance starts clean. Leftover state from the previous one would
    // let a model answer the wrong question entirely.
    llama_memory_clear(llama_get_memory(c->ctx), true);

    if (llama_decode(c->ctx, llama_batch_get_one(tokens, n_prompt)) != 0) {
        free(tokens);
        return -1;
    }
    free(tokens);

    const double started = now_seconds();
    size_t written = 0;
    int produced = 0;
    char piece[256];

    while (produced < max_tokens) {
        llama_token tok = llama_sampler_sample(c->sampler, c->ctx, -1);
        if (llama_vocab_is_eog(c->vocab, tok)) break;

        int32_t n = llama_token_to_piece(c->vocab, tok, piece, (int32_t)sizeof(piece), 0, false);
        if (n > 0) {
            // Stop at the buffer rather than truncating mid-UTF-8 and handing
            // Swift bytes it cannot decode.
            if (written + (size_t)n >= out_len) break;
            memcpy(out + written, piece, (size_t)n);
            written += (size_t)n;
        }
        produced++;

        if (llama_decode(c->ctx, llama_batch_get_one(&tok, 1)) != 0) break;
    }

    out[written] = '\0';
    if (seconds) *seconds = now_seconds() - started;
    return produced;
}
