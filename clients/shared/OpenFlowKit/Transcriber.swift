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

    /// The silence measured at each segment boundary. Kept so the app can show
    /// why a paragraph did or did not break — a detection nobody can inspect
    /// is one nobody can tune.
    public private(set) var lastSegmentGaps: [Int64] = []
    /// Whether the last utterance's token times were internally consistent.
    /// False means whisper's timing collapsed and no break was trusted.
    public private(set) var lastTimingWasSound = true

    /// Whether to act on the pauses at all.
    ///
    /// Off when a polish model is doing the layout. Two mechanisms breaking the
    /// same text fight, and the worse one wins because it runs first: the model
    /// produced "Hi, Cynthia" and a clean body while this was inserting a
    /// paragraph around a stray full stop. Pauses are the fallback for when
    /// there is no model, not a second opinion.
    public var insertParagraphBreaks = true
    /// First and last word time of each segment, in ms.
    public private(set) var lastSegmentSpans: [(Int64, Int64)] = []

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
                // Per-token times. The gap between one word ending and the
                // next beginning IS the pause, and unlike measuring silence in
                // the audio it does not care about the noise floor — which
                // automatic gain control lifts until a quiet room and a held
                // breath look the same.
                p.token_timestamps = true
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
                    // Every token, in order, with the silence before it.
                    //
                    // Not segment boundaries: whisper clamps the last token of
                    // a segment to end exactly where the next one starts, so
                    // the gap there is always zero. Measured: six segments,
                    // spans 0-8040, 8040-13430, 13480-23040 — contiguous.
                    // The pauses are *inside* the segments, and the token times
                    // there are not clamped to anything.
                    var words: [(text: String, start: Int64, end: Int64)] = []
                    for i in 0..<whisper_full_n_segments(ctx) {
                        for k in 0..<whisper_full_n_tokens(ctx, i) {
                            let d = whisper_full_get_token_data(ctx, i, k)
                            guard d.id < whisper_token_eot(ctx),
                                  let raw = whisper_full_get_token_text(ctx, i, k)
                            else { continue }
                            let text = String(cString: raw)

                            // Punctuation is its own token with its own
                            // timestamp, and the gaps around it are an artefact
                            // of tokenisation rather than anything the speaker
                            // did. Left alone it produced a paragraph
                            // containing nothing but a full stop, between two
                            // "pauses" of 1100ms and 900ms.
                            let isPunctuation = !text.trimmingCharacters(in: .whitespaces).isEmpty
                                && text.allSatisfy { $0.isPunctuation || $0.isWhitespace }
                            if isPunctuation, var last = words.popLast() {
                                last.text += text
                                last.end = max(last.end, d.t1 * 10)
                                words.append(last)
                                continue
                            }
                            words.append((text, d.t0 * 10, d.t1 * 10))
                        }
                    }

                    var gaps: [Int64] = []
                    for i in 1..<max(1, words.count) {
                        gaps.append(max(0, words[i].start - words[i - 1].end))
                    }

                    let threshold = gaps.withUnsafeBufferPointer {
                        of_paragraph_threshold_ms($0.baseAddress, $0.count)
                    }
                    lastParagraphThresholdMS = threshold
                    lastSegmentGaps = gaps.sorted(by: >).prefix(6).map { $0 }

                    // whisper's token timing is usually sound and occasionally
                    // garbage, so it is checked rather than trusted.
                    //
                    // On one email, seven consecutive words — "I", "'d", "be",
                    // "delighted" — all claimed to start at 0:24, producing
                    // "gaps" of 5840, 5700, 5420, 5140ms. Time cannot run
                    // backwards and a word cannot end before it starts, so a
                    // single monotonicity check catches that whole class
                    // without guessing at thresholds. On a good utterance the
                    // same code sees 970, 950, 830, 570, 450, 440 and breaks
                    // three times, correctly.
                    let timingIsSound = zip(words, words.dropFirst()).allSatisfy {
                        $1.start >= $0.start && $0.end >= $0.start
                    }
                    lastTimingWasSound = timingIsSound

                    var breaks: [Double] = []
                    for (i, word) in words.enumerated() {
                        if insertParagraphBreaks, timingIsSound, i > 0, gaps[i - 1] >= threshold {
                            // Trim the space whisper puts before a token, or
                            // every paragraph starts with one.
                            result = result.trimmingCharacters(in: .whitespaces)
                            result += "\n\n"
                            result += word.text.trimmingCharacters(in: .whitespaces)
                            breaks.append(Double(word.start) / 1000)
                        } else {
                            result += word.text
                        }
                    }
                    lastParagraphBreaks = breaks
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
