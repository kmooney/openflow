//! whisper.cpp, wrapped.
//!
//! The same model files and the same decoding settings as the macOS and iOS
//! clients: the point of sharing a catalogue is that "Small (English)" means
//! the same thing wherever you run it.

use std::path::Path;

use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct Transcriber {
    ctx: WhisperContext,
    threads: i32,
}

/// whisper.cpp and ggml write progress, model details and (on a debug build) a
/// token-by-token trace to stderr. The shipping app has no console for that to
/// go to, and in a test run it buries the results.
///
/// This redirects both into the `log` crate's hooks, and since nothing here
/// installs a `log` backend, that is where they stop. Safe to call repeatedly;
/// only the first call does anything.
fn silence_whisper_logging() {
    whisper_rs::install_logging_hooks();
}

impl Transcriber {
    pub fn open(model_path: &Path) -> Option<Transcriber> {
        silence_whisper_logging();
        let mut params = WhisperContextParameters::new();
        // GPU only when the binary was built with a backend that has one.
        // The stock build is CPU: CUDA and Vulkan each need their own SDK
        // installed to compile, and a dictation app that will not build is
        // worse than one that takes another few hundred milliseconds.
        params.use_gpu(cfg!(any(feature = "cuda", feature = "vulkan")));

        let ctx = WhisperContext::new_with_params(model_path, params).ok()?;
        Some(Transcriber {
            ctx,
            threads: default_threads(),
        })
    }

    /// Transcribe 16 kHz mono float samples.
    ///
    /// `vocabulary` biases decoding toward names whisper will not know. It is
    /// phrased as a punctuated sentence deliberately: a bare comma list makes
    /// the model imitate that style and drop punctuation from the whole
    /// transcript. Measured in M0; see notes/spec.md 5.2.
    pub fn transcribe(&self, samples: &[f32], vocabulary: &[String]) -> String {
        if samples.is_empty() {
            return String::new();
        }
        let prompt = build_prompt(vocabulary);

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(self.threads);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_print_special(false);
        params.set_no_timestamps(true);
        params.set_translate(false);
        params.set_language(Some("en"));
        params.set_suppress_blank(true);
        if !prompt.is_empty() {
            params.set_initial_prompt(&prompt);
        }

        let Ok(mut state) = self.ctx.create_state() else {
            return String::new();
        };
        if state.full(params, samples).is_err() {
            return String::new();
        }

        let mut out = String::new();
        for i in 0..state.full_n_segments() {
            if let Some(segment) = state.get_segment(i) {
                if let Ok(text) = segment.to_str_lossy() {
                    out.push_str(&text);
                }
            }
        }
        out.trim().to_string()
    }
}

/// The prompt sent to whisper as a decoding hint. Public so the shape is
/// testable without a model on disk.
pub fn build_prompt(vocabulary: &[String]) -> String {
    if vocabulary.is_empty() {
        return String::new();
    }
    format!(
        "The following names may appear in this recording: {}.",
        vocabulary.join(", ")
    )
}

/// Leave a couple of cores for everything else. whisper saturates whatever it
/// is given, and a machine that goes unresponsive while you dictate is not an
/// improvement over one that takes another 200 ms.
fn default_threads() -> i32 {
    let cores = std::thread::available_parallelism()
        .map(|n| n.get() as i32)
        .unwrap_or(4);
    (cores - 2).clamp(2, 8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_vocabulary_means_no_prompt() {
        assert!(build_prompt(&[]).is_empty());
    }

    /// A bare comma list makes the model imitate that style and drop
    /// punctuation from the entire transcript, so the hint is a sentence.
    #[test]
    fn the_prompt_is_a_punctuated_sentence() {
        let p = build_prompt(&["Kubernetes".into(), "Anjali".into()]);
        assert!(p.ends_with('.'));
        assert!(p.contains("Kubernetes, Anjali"));
        assert!(p.starts_with("The following names"));
    }

    #[test]
    fn thread_count_leaves_the_machine_usable() {
        let t = default_threads();
        assert!((2..=8).contains(&t));
    }

    #[test]
    fn a_missing_model_is_none_rather_than_a_panic() {
        assert!(Transcriber::open(Path::new("C:/nope/ggml-tiny.en.bin")).is_none());
    }
}
