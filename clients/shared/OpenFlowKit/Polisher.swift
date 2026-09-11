#if canImport(CLlamaShim)
import Foundation
import CLlamaShim
import COpenFlow

/// The polish stage: a small language model repairs what whisper misheard,
/// before the deterministic formatter runs.
///
/// The same shape as `Transcriber`, and thin for the same reason — inference is
/// the one part that genuinely differs per platform, so the prompt and the
/// reply handling live in `openflow-core` where all three clients share them.
///
/// It talks to `CLlamaShim` rather than to llama.cpp directly. whisper.cpp and
/// llama.cpp vendor different versions of ggml, and exposing both to Swift
/// makes Clang refuse the build outright — "'ggml_prec' has different
/// definitions in different modules", because the two really are different
/// types sharing a name. The shim is the one file that sees `llama.h`, and no
/// ggml type crosses into Swift.
public final class Polisher {
    private let handle: OpaquePointer
    public let modelPath: String
    public let usesGPU: Bool

    /// Tokens per second on the last run. Measured, not estimated, and
    /// published because the whole reason the model is the user's choice is
    /// that this number differs wildly by device.
    public private(set) var lastTokensPerSecond: Double = 0
    /// Tokens produced on the last run.
    public private(set) var lastTokenCount: Int = 0

    public init?(modelPath: String, useGPU: Bool = true, contextTokens: Int = 2048) {
        // All layers on the GPU or none. The caller decides, because only the
        // caller knows where it is running: iOS refuses GPU work from a
        // backgrounded app, and the keyboard path is always backgrounded — see
        // `AudioRecorder` for the measurement.
        let layers = useGPU ? 99 : 0
        let threads = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount)))
        // `ofl_ctx` is only forward-declared in the header, so Swift imports it
        // as an `OpaquePointer` already — no casting required, and none wanted.
        guard let h = ofl_open(modelPath, Int32(layers), Int32(contextTokens), threads) else {
            return nil
        }
        self.handle = h
        self.modelPath = modelPath
        self.usesGPU = layers > 0
    }

    deinit { ofl_close(handle) }

    /// Repair one transcript, or return nil if the model produced nothing
    /// usable — so the caller keeps what the user said rather than pasting an
    /// empty string.
    ///
    /// `maxTokens` is a hard stop, not a target. A small model asked to repair
    /// a sentence sometimes writes an essay instead, and that is paid for in
    /// seconds the user spends waiting.
    public func polish(_ transcript: String, vocabulary: [String] = [],
                       maxTokens: Int = 256) -> String? {
        let prompt = sharedPrompt(transcript, vocabulary)
        #if DEBUG
        NSLog("openflow: polish prompt is %d chars", prompt.count)
        #endif
        guard !prompt.isEmpty else {
            NSLog("openflow: polish aborted — of_polish_prompt returned nothing")
            return nil
        }

        var buffer = [CChar](repeating: 0, count: 8192)
        var seconds: Double = 0
        let produced = ofl_generate(handle, prompt, Int32(maxTokens),
                                    &buffer, buffer.count, &seconds)
        #if DEBUG
        // The reply verbatim, before cleanup. Without it, "the model changed
        // nothing" and "the model said something cleanup threw away" look the
        // same, and they are opposite problems.
        NSLog("openflow: llama produced %d tokens in %.2fs |%@|",
              produced, seconds, String(cString: buffer))
        #endif
        guard produced > 0 else { return nil }

        lastTokenCount = Int(produced)
        lastTokensPerSecond = seconds > 0 ? Double(produced) / seconds : 0

        let reply = String(cString: buffer)
        let cleaned = sharedClean(reply, transcript)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - the shared half
    //
    // Both of these are `openflow-core`, through the same C ABI the formatter
    // already uses. The point is that Windows asks the model the same question.

    private func sharedPrompt(_ transcript: String, _ vocabulary: [String]) -> String {
        let vocab = vocabulary.joined(separator: "\n")
        return transcript.withCString { t in
            vocab.withCString { v in
                guard let p = of_polish_prompt(t, v) else { return "" }
                defer { of_string_free(p) }
                return String(cString: p)
            }
        }
    }

    private func sharedClean(_ reply: String, _ transcript: String) -> String {
        reply.withCString { r in
            transcript.withCString { t in
                guard let p = of_polish_clean(r, t) else { return "" }
                defer { of_string_free(p) }
                return String(cString: p)
            }
        }
    }
}
#endif
