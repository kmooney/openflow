import Foundation
import CWhisper

/// whisper.cpp, wrapped. Shared by macOS and iOS -- the only difference
/// between them is which model size they can afford to load.
public final class Transcriber {
    private let ctx: OpaquePointer
    public let modelPath: String

    public init?(modelPath: String, useGPU: Bool = true) {
        var cp = whisper_context_default_params()
        cp.use_gpu = useGPU
        #if targetEnvironment(simulator)
        // The simulator's Metal support is not what ggml expects; asking for
        // the GPU there fails or falls back unpredictably. CPU is slower but
        // it actually runs, and the simulator is for checking behaviour rather
        // than measuring speed.
        cp.use_gpu = false
        #endif
        guard let c = whisper_init_from_file_with_params(modelPath, cp) else { return nil }
        self.ctx = c
        self.modelPath = modelPath
    }

    deinit { whisper_free(ctx) }

    /// Transcribe 16 kHz mono float samples.
    ///
    /// `vocabulary` biases decoding toward names whisper won't know. It is
    /// phrased as a punctuated sentence deliberately: a bare comma list makes
    /// the model imitate that style and drop punctuation from the whole
    /// transcript. Measured in M0; see notes/spec.md §5.2.
    public func transcribe(samples: [Float], vocabulary: [String] = [],
                           threads: Int32 = 8) -> String {
        guard !samples.isEmpty else { return "" }
        let prompt = vocabulary.isEmpty ? "" :
            "The following names may appear in this recording: "
            + vocabulary.joined(separator: ", ") + "."

        var result = ""
        prompt.withCString { pptr in
            "en".withCString { lptr in
                var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                p.n_threads = threads
                p.print_progress = false
                p.print_realtime = false
                p.print_timestamps = false
                p.no_timestamps = true
                p.translate = false
                p.language = lptr
                p.suppress_blank = true
                if !prompt.isEmpty { p.initial_prompt = pptr }

                samples.withUnsafeBufferPointer { buf in
                    guard whisper_full(ctx, p, buf.baseAddress, Int32(buf.count)) == 0 else { return }
                    for i in 0..<whisper_full_n_segments(ctx) {
                        if let t = whisper_full_get_segment_text(ctx, i) {
                            result += String(cString: t)
                        }
                    }
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
