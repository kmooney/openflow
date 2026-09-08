import Foundation
import AVFoundation

/// Optional on-disk audio, for working out *why* a transcript came back wrong.
///
/// Off by default and deliberately so: audio is the most sensitive thing this
/// app touches, and the standing rule is transcribe-and-discard. This exists
/// because "it misheard me" is otherwise unfalsifiable.
public enum AudioStorage {
    public static func directory(under support: URL) -> URL {
        support.appendingPathComponent("audio", isDirectory: true)
    }

    @discardableResult
    public static func write(_ samples: [Float], id: String, under support: URL) throws -> URL {
        let dir = directory(under: support)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "openflow.audio", code: 1)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            buf.floatChannelData?[0].update(from: base, count: samples.count)
        }
        try file.write(from: buf)
        return url
    }

    /// Remove a clip. Called on every delete: a hard delete must take the audio
    /// with it, or "delete means delete" is a lie.
    public static func remove(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func totalBytes(under support: URL) -> Int64 {
        let dir = directory(under: support)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
