import Foundation
import CWhisper
import COpenFlow

/// whisper.cpp, wrapped. Shared by macOS and iOS -- the only difference
/// between them is which model size they can afford to load.
public final class Transcriber {
    private let ctx: OpaquePointer
    public let modelPath: String
    /// Whether this context was built against Metal. Kept because a GPU
    /// failure is recoverable and a CPU one is not, so the caller has to know
    /// which it just had.
    public let usesGPU: Bool
    /// What was *asked* for, as opposed to what was built. The simulator is
    /// forced to the CPU regardless, so comparing the actual value against a
    /// caller's preference would rebuild the context forever there.
    public let requestedGPU: Bool

    /// The return code from the last `whisper_full`. Non-zero with an empty
    /// transcript means the run *failed*; zero with an empty transcript means
    /// it ran and heard nothing. Those are opposite problems, and for a long
    /// time both arrived as the same empty string — the failure was swallowed
    /// by a bare `guard ... else { return }` and surfaced to the user as "no
    /// words recognised", which sent every investigation at the microphone.
    public private(set) var lastStatus: Int32 = 0

    /// The pause length that counted as a paragraph on the last transcription,
    /// derived from the speaker's own gaps. Exposed for the console, because a
    /// threshold nobody can see is one nobody can tune.
    public private(set) var lastParagraphThresholdMS: Int64 = 0

    /// When each paragraph break fell, in seconds from the start of the
    /// recording. Kept beside the text rather than written into it: the
    /// transcript is what gets pasted, and a timestamp in someone's email is
    /// not a feature.
    public private(set) var lastParagraphBreaks: [Double] = []

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
        self.usesGPU = cp.use_gpu
        self.requestedGPU = useGPU
    }

    deinit { whisper_free(ctx) }

    /// Transcribe 16 kHz mono float samples.
    ///
    /// `vocabulary` biases decoding toward names whisper won't know. It is
    /// phrased as a punctuated sentence deliberately: a bare comma list makes
    /// the model imitate that style and drop punctuation from the whole
    /// transcript. Measured in M0; see notes/spec.md §5.2.
    /// One thread per core, capped. Eight was hardcoded, which oversubscribes
    /// every iPhone ever made — and a backgrounded app is confined to the
    /// efficiency cores, where oversubscription costs most.
    public static var defaultThreads: Int32 {
        Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount)))
    }

    public func transcribe(samples: [Float], vocabulary: [String] = [],
                           threads: Int32 = Transcriber.defaultThreads) -> String {
        lastStatus = 0
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
                // Timestamps on, because the gaps between segments are the
                // paragraph breaks. whisper already knows when the speaker
                // paused; this used to throw that away and then ask a language
                // model to guess it back.
                p.no_timestamps = false
                p.translate = false
                p.language = lptr
                p.suppress_blank = true
                if !prompt.isEmpty { p.initial_prompt = pptr }

                samples.withUnsafeBufferPointer { buf in
                    let status = whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
                    lastStatus = status
                    guard status == 0 else {
                        NSLog("openflow: whisper_full failed with %d (gpu=%@, %d samples)",
                              status, usesGPU ? "yes" : "no", buf.count)
                        return
                    }

                    // Segment text plus the silence before it. whisper reports
                    // times in centiseconds.
                    var pieces: [String] = []
                    var gaps: [Int64] = []
                    var previousEnd: Int64 = -1
                    for i in 0..<whisper_full_n_segments(ctx) {
                        guard let t = whisper_full_get_segment_text(ctx, i) else { continue }
                        let start = whisper_full_get_segment_t0(ctx, i) * 10
                        if previousEnd >= 0 { gaps.append(max(0, start - previousEnd)) }
                        previousEnd = whisper_full_get_segment_t1(ctx, i) * 10
                        pieces.append(String(cString: t))
                    }

                    // The threshold comes from this speaker's own pauses: a
                    // brisk talker's new-thought gap is shorter than a slow
                    // talker's comma, so any constant is wrong for someone.
                    let threshold = gaps.withUnsafeBufferPointer {
                        of_paragraph_threshold_ms($0.baseAddress, $0.count)
                    }
                    lastParagraphThresholdMS = threshold
                    #if DEBUG
                    if !gaps.isEmpty {
                        NSLog("openflow: segment gaps %@ → paragraph at %lld ms",
                              gaps.map(String.init).joined(separator: ","), threshold)
                    }
                    #endif

                    var breaks: [Double] = []
                    var starts: [Int64] = []
                    for i in 0..<whisper_full_n_segments(ctx) {
                        starts.append(whisper_full_get_segment_t0(ctx, i) * 10)
                    }
                    for (i, piece) in pieces.enumerated() {
                        if i > 0, gaps[i - 1] >= threshold {
                            result += "\n\n"
                            breaks.append(Double(starts[i]) / 1000)
                        }
                        result += piece
                    }
                    lastParagraphBreaks = breaks
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
