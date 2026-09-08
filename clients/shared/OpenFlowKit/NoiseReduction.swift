import Foundation
import Accelerate

/// Spectral-subtraction noise reduction.
///
/// Written because Apple's voice-processing unit could not be made to work
/// here: three attempts at the AVAudioEngine graph produced either digital
/// silence or `-10875`, and each failure broke dictation entirely. This runs on
/// a plain array of samples after capture, so the worst it can do is sound bad
/// — it cannot take the microphone down with it. It is also testable, which
/// VPIO was not.
///
/// The method suits the problem: aircraft, HVAC and fan noise are close to
/// stationary, and stationary noise is precisely what spectral subtraction
/// removes well. It estimates a per-frequency noise floor from the quietest
/// frames — no separate "silence sample" needed, because a dictated utterance
/// always contains pauses.
public enum NoiseReduction {

    /// How aggressively to subtract the estimated noise. Above ~2.5 speech
    /// starts to sound watery.
    public static var overSubtraction: Float = 2.0
    /// Never attenuate a bin below this fraction of its original magnitude.
    /// Zeroing bins outright is what makes spectral subtraction sound like
    /// bubbling ("musical noise"); leaving a floor avoids it.
    public static var spectralFloor: Float = 0.08
    /// Percentile of frame magnitudes taken as the noise estimate, per bin.
    /// Per-bin magnitudes of broadband noise are Rayleigh-distributed, so a low
    /// percentile sits well under the mean and subtracting it barely dents the
    /// noise. A quarter is high enough to bite and still below the level speech
    /// reaches in any bin it occupies.
    public static var noisePercentile: Float = 0.25
    /// Below this noise-to-signal ratio the recording is already clean and is
    /// returned untouched. Denoising clean audio only removes speech: the
    /// per-bin "noise" estimate of a quiet recording is mostly quiet speech.
    public static var minNoiseRatio: Float = 0.18

    private static let frameSize = 512
    private static let hop = 256          // 50% overlap, Hann: sums to constant

    public static func reduce(_ samples: [Float]) -> [Float] {
        let n = frameSize
        guard samples.count >= n * 4 else { return samples }

        let log2n = vDSP_Length(log2(Float(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return samples }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        let half = n / 2
        let frameCount = (samples.count - n) / hop + 1

        // --- analysis: FFT every frame, keep the spectra
        var reals = [[Float]](repeating: [Float](repeating: 0, count: half), count: frameCount)
        var imags = reals
        var mags = reals

        for f in 0..<frameCount {
            var windowed = [Float](repeating: 0, count: n)
            let start = f * hop
            vDSP_vmul(Array(samples[start..<(start + n)]), 1, window, 1, &windowed, 1, vDSP_Length(n))

            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            var m = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_zvabs(&split, 1, &m, 1, vDSP_Length(half))
                }
            }
            reals[f] = re; imags[f] = im; mags[f] = m
        }

        // --- noise estimate: a low percentile per bin, across time.
        // A dictated utterance always has pauses, so the quiet end of each
        // bin's history is the noise floor. No calibration step required.
        var noise = [Float](repeating: 0, count: half)
        let idx = max(0, min(frameCount - 1, Int(Float(frameCount) * noisePercentile)))
        for b in 0..<half {
            var column = [Float](repeating: 0, count: frameCount)
            for f in 0..<frameCount { column[f] = mags[f][b] }
            column.sort()
            noise[b] = column[idx]
        }

        // Is there enough noise to be worth removing? Comparing the estimated
        // floor against the overall level answers it. On a clean recording the
        // "noise" estimate is largely quiet speech, and subtracting it costs
        // half the signal for no benefit.
        let noiseMean = noise.reduce(0, +) / Float(half)
        var overallMean: Float = 0
        for f in 0..<frameCount { overallMean += mags[f].reduce(0, +) }
        overallMean /= Float(frameCount * half)
        guard overallMean > 1e-9, noiseMean / overallMean >= minNoiseRatio else {
            return samples
        }

        // --- gain per bin, applied to the complex spectrum so phase is kept
        for f in 0..<frameCount {
            for b in 0..<half {
                let m = mags[f][b]
                guard m > 1e-9 else { continue }
                let cleaned = m - overSubtraction * noise[b]
                let gain = max(spectralFloor, cleaned / m)
                reals[f][b] *= gain
                imags[f][b] *= gain
            }
        }

        // --- synthesis: inverse FFT and overlap-add
        var out = [Float](repeating: 0, count: samples.count)
        var norm = [Float](repeating: 0, count: samples.count)
        // vDSP_fft_zrip's forward pass carries a factor of 2, so the round
        // trip needs 1/(2n). Using 1/(4n) reconstructs at half amplitude --
        // which reads as "the denoiser eats speech" and is really just a
        // scaling bug.
        let scale = 1.0 / Float(2 * n)

        for f in 0..<frameCount {
            var re = reals[f], im = imags[f]
            var time = [Float](repeating: 0, count: n)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    time.withUnsafeMutableBufferPointer { tp in
                        tp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            var s = scale
            vDSP_vsmul(time, 1, &s, &time, 1, vDSP_Length(n))

            let start = f * hop
            for i in 0..<n {
                out[start + i] += time[i] * window[i]
                norm[start + i] += window[i] * window[i]
            }
        }

        for i in 0..<out.count where norm[i] > 1e-6 {
            out[i] /= norm[i]
        }
        return out
    }
}
