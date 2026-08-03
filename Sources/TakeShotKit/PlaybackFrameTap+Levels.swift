import AVFoundation
import CaptureCore
import CoreVideo
import Foundation

/// What the player has to do to a take's code values before they are a picture.
///
/// A TakeShot recording carries the camera's wire codes — studio swing, nominal
/// black at 64 and white at 940, with the footroom and headroom the camera sent
/// still in it. That is what makes the file worth keeping, and it is also why
/// the decoder cannot hand it straight to the screen: a studio-swing frame
/// displayed without expansion is the washed black this app has been bitten by
/// before. The live path expands the wire on its way to the monitor; this is the
/// same operation, on the same table, so a take under review looks exactly like
/// the monitor looked while it was recording.
///
/// A foreign clip, a still, or a take from before the record path carried wire
/// codes is left alone: those already hold display values, and expanding them a
/// second time would crush their shadows.
extension PlaybackFrameTap {
    /// Ask the file what its codes mean, then act on the answer. Loading the
    /// metadata is asynchronous, so the first frames of a clip can reach the
    /// screen unexpanded — the same race the baked-LUT tag has always run, and
    /// the same resolution: the clip is checked for identity before the answer
    /// is applied, so a fast switch cannot leave the previous clip's decision
    /// behind.
    func detectLevels(of item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak self, weak item] in
            let metadata = (try? await asset.load(.metadata)) ?? []
            let wire = await TakeWriter.carriesWireCodes(metadata)
            guard let self, let item else { return }
            self.queue.async {
                guard self.item === item else { return }
                self.sourceCarriesWireCodes = wire
                self.idleDelivered = false
                // a paused clip pushes nothing: re-deliver so the answer lands
                if let buffer = self.lastBuffer, wire {
                    self.deliver(self.displayReady(buffer, wireCodes: true),
                                 analyzed: self.scopesEnabled)
                }
            }
        }
    }

    /// The same question for the compare clip, which arrives as a URL rather
    /// than as a player item.
    func detectCompareLevels(of url: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.metadata)) ?? []
            let wire = await TakeWriter.carriesWireCodes(metadata)
            guard let self else { return }
            self.queue.async {
                guard self.compareURL == url else { return }
                self.compareCarriesWireCodes = wire
            }
        }
    }

    /// Whether the clip on screen is being expanded — the answer arrives from a
    /// metadata load, so anything waiting on it has to be able to ask.
    /// Queue-synchronous, like `currentBuffer()`.
    var carriesWireCodes: Bool {
        var result = false
        queue.sync { result = sourceCarriesWireCodes }
        return result
    }

    /// A decoded frame as the screen should see it. The expansion goes into a
    /// pooled copy — never in place — because the buffer a video output hands
    /// over can share its IOSurface with the decoder's own frame; and the
    /// copy inherits the source's attachments, so the colorimetry the layer and
    /// the compositor read is the file's, unchanged.
    ///
    /// Falls back to the untouched frame whenever the copy cannot be made: a
    /// slightly washed picture is a bad frame, no picture at all is a bug.
    func displayReady(_ buffer: CVPixelBuffer, wireCodes: Bool) -> CVPixelBuffer {
        guard wireCodes else { return buffer }
        guard let expanded = levelsPool.buffer(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)),
              StudioSwing.expand(buffer, into: expanded)
        else { return buffer }
        CVBufferPropagateAttachments(buffer, expanded)
        return expanded
    }
}
