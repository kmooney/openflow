import Foundation
import AVFoundation

/// Replay a stored clip from the history list. One player, so starting a new
/// clip stops the previous one rather than layering them.
public final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var playingPath: String?
    private var player: AVAudioPlayer?

    public override init() { super.init() }

    public func toggle(_ path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        if playingPath == path { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        p.delegate = self
        player = p
        playingPath = path
        p.play()
    }

    public func stop() {
        player?.stop()
        player = nil
        playingPath = nil
    }

    public func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}
