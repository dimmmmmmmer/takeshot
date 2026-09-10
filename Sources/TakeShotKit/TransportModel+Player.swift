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
        applyPlaybackEnd()
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
                // The out point, in BOTH loop states: wrap to the in point
                // when looping, stop there when not. It used to act only while
                // looping, so with the loop off playback ran straight past the
                // mark to the end of the clip — the RAW engine has always done
                // both (`RawPlayback+PlayLoop`), and these are two statements
                // of one rule that had come apart.
                switch self.rangeAction(atTime: time.seconds, playing: playing) {
                case .carryOn:
                    break
                case .wrap(let start):
                    self.seek(to: start)
                case .stop(let mark):
                    // **A safety net, not the trigger.** The player is told
                    // where the range ends (`applyPlaybackEnd`) and stops
                    // there itself, frame-exact; this arm only runs if that
                    // end time was missed — after a seek, or on an item that
                    // refused it. It still lands on the mark, and the seek
                    // that does so is the visible backwards jump the owner
                    // reported ("в конце прыгает на 1 фрейм") — which is why
                    // it must not be the ordinary path.
                    player.pause()
                    self.isPlaying = false
                    if abs(player.currentTime().seconds - mark) > 0.001 {
                        self.seek(to: mark)
                    }
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

    /// **Tell the PLAYER where the range ends.**
    ///
    /// The out point used to be enforced by sampling the playhead at 10 Hz and
    /// then seeking BACKWARDS onto the mark. 100 ms is two to three frames, so
    /// playback always ran past the mark — those frames genuinely reach the
    /// screen, the tap pulls the picture every 16 ms — and then froze and
    /// snapped back. That snap is the report (owner: "если в плейбэке
    /// поставить точки ин и аут у клипа и запустить плейбэк без лупа в конце
    /// прыгает на 1 фрейм"). With the loop ON the same late detection is
    /// swallowed by the wrap, which is a jump the operator expects — and that
    /// asymmetry is the whole reason the report is loop-off only.
    ///
    /// `forwardPlaybackEndTime` is AVFoundation's own answer: the player stops
    /// AT that time and posts `didPlayToEndTime`, so there is nothing to
    /// correct afterwards. Playing past a mark is then impossible, which is
    /// what an out point means; SEEKING past it still is, and the next press
    /// of play restarts the range (`rangeStart(forPlayheadAt:)`).
    ///
    /// The RAW engine has always been frame-accurate here for the same reason
    /// — its out point is a FRAME NUMBER inside the decode loop, with no seek
    /// afterwards (`RawPlayback+PlayLoop`).
    func applyPlaybackEnd() {
        guard let item = player?.currentItem else { return }
        guard let out = outPoint else {
            item.forwardPlaybackEndTime = .invalid
            return
        }
        // The item's own timescale, not 600: 600 cannot represent an NTSC
        // frame boundary, and this is the one number the picture comes to rest
        // on.
        let scale = item.duration.isNumeric ? item.duration.timescale : 600
        item.forwardPlaybackEndTime = CMTime(seconds: out,
                                             preferredTimescale: scale)
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
