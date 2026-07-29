import AVFoundation
import Combine
import Foundation

/// Playhead position only — isolated so the 10 Hz tick re-renders just the
/// TC readout and the slider, not the whole transport bar.
@MainActor
final class TransportPosition: ObservableObject {
    @Published var currentTime: Double = 0
}

/// Observing AVPlayer for the transport: time, speed, loop.
@MainActor
final class TransportModel: ObservableObject {
    let position = TransportPosition()
    var currentTime: Double { position.currentTime }
    @Published var duration: Double = 0
    /// Loop range (stuntmen watch one beat ten times in a row).
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    @Published var isPlaying = false
    @Published var desiredRate: Double = 1.0
    @Published var isLooping = true

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        // The periodic observer below only fires while time advances, so when
        // playback stopped, `isPlaying` stayed true and the transport kept
        // showing a pause button over a stopped clip. The player's own status
        // reports the stop.
        statusObservation = player.observe(\.timeControlStatus,
                                           options: [.initial, .new]) { player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.position.currentTime = time.seconds
                let playing = player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
                if let item = player.currentItem, item.duration.isNumeric,
                   self.duration != item.duration.seconds {
                    self.duration = item.duration.seconds
                }
                // loop range: jump back at the out point while playing
                if playing, self.isLooping, let out = self.outPoint,
                   time.seconds >= out {
                    self.seek(to: self.inPoint ?? 0)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player,
                      (note.object as? AVPlayerItem) === player.currentItem,
                      self.isLooping else { return }
                let start = self.inPoint ?? 0
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                player.rate = Float(self.desiredRate)
            }
        }
    }

    func detach() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if let item = player.currentItem, item.duration.isNumeric,
               item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.rate = Float(desiredRate)
        }
    }

    /// Set/clear the in or out point at the playhead (click near an existing
    /// point clears it).
    func toggleRangePoint(out: Bool) {
        let now = position.currentTime
        if out {
            if let existing = outPoint, abs(existing - now) < 0.1 {
                outPoint = nil
            } else {
                outPoint = now
                if let inP = inPoint, inP >= now { inPoint = nil }
            }
        } else {
            if let existing = inPoint, abs(existing - now) < 0.1 {
                inPoint = nil
            } else {
                inPoint = now
                if let outP = outPoint, outP <= now { outPoint = nil }
            }
        }
    }

    func setRate(_ rate: Float) {
        desiredRate = Double(rate)
        if player?.rate != 0 {
            player?.rate = rate
        }
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
