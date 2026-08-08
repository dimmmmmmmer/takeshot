import AVFoundation
import Combine
import Foundation

/// Playhead position only — isolated so the 10 Hz tick re-renders just the
/// TC readout and the slider, not the whole transport bar.
@MainActor
final class TransportPosition: ObservableObject {
    @Published var currentTime: Double = 0
}

/// Attaching the transport to an AVPlayer, and letting go of it again.
///
/// Split out of `TransportModel`: three observers with three different
/// lifetimes is a job of its own, and the reason each of them exists is written
/// here rather than among the controls that read what they publish.
extension TransportModel {
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
            // Only WHICH item ended crosses to the main actor, never the
            // notification: it belongs to the thread that posted it, and the
            // check needs an identity, which is a value. `===` on the far side
            // asked the same question of the same two pointers.
            let ended = note.object.map { ObjectIdentifier($0 as AnyObject) }
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, let ended,
                      player.currentItem.map(ObjectIdentifier.init) == ended,
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
}
