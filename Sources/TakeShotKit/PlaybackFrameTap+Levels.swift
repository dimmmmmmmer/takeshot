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
    ///
    /// The file is opened for its metadata rather than the player's own asset
    /// being read off the item: this runs on the tap queue and an
    /// `AVPlayerItem` is main-actor state. It is the same file and the same
    /// answer, asked the same way the compare clip below asks it.
    func detectLevels(of item: AVPlayerItem, at url: URL) {
        Task { [weak self, weak item] in
            let asset = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.metadata)) ?? []
            let wire = await TakeWriter.carriesWireCodes(metadata)
            let transfer = await Self.transfer(of: asset)
            guard let self, let item else { return }
            self.queue.async {
                guard self.item === item else { return }
                self.sourceCarriesWireCodes = wire
                self.sourceTransfer = transfer
                self.idleDelivered = false
                // a paused clip pushes nothing: re-deliver so the answer lands
                if let buffer = self.lastBuffer, wire || transfer.isHDR {
                    self.deliver(
                        self.displayReady(buffer, wireCodes: wire,
                                          transfer: transfer),
                        analyzed: self.scopesEnabled)
                }
            }
        }
    }

    /// What a file says it is encoded with, read from its video track's format
    /// description — the tag `TakeWriter` wrote for an HDR take, and the tag a
    /// foreign HDR clip dropped in the record folder carries too.
    ///
    /// Anything that is not PQ or HLG is `.sdr`, including a file that states
    /// nothing: an untagged clip is left exactly as it always was.
    static func transfer(of asset: AVAsset) async -> SignalTransfer {
        guard let track = try? await asset.loadTracks(withMediaType: .video)
            .first,
            let description = try? await track.load(.formatDescriptions).first
        else { return .sdr }
        let extensions = CMFormatDescriptionGetExtensions(description)
            as? [String: Any] ?? [:]
        let tag = extensions[
            kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        switch tag {
        case pq: return .pq
        case hlg: return .hlg
        default: return .sdr
        }
    }

    /// The same question for the compare clip, which arrives as a URL rather
    /// than as a player item.
    func detectCompareLevels(of url: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.metadata)) ?? []
            let wire = await TakeWriter.carriesWireCodes(metadata)
            let transfer = await Self.transfer(of: asset)
            guard let self else { return }
            self.queue.async {
                guard self.compareURL == url else { return }
                self.compareCarriesWireCodes = wire
                self.compareTransfer = transfer
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
    /// An HDR take needs a second operation here, and it needs it for the same
    /// reason the first one exists. Measured on this project's own files: a
    /// ProRes take tagged SMPTE ST 2084 decodes to BGRA with its codes merely
    /// video-range expanded — AVFoundation does NOT tone map on the way out,
    /// and the PQ tag changes not one pixel it returns. Left alone, a PQ take
    /// under review would show diffuse white at 149 of 255 where the live
    /// monitor showed it at 242: the same footage, a stop and a half apart,
    /// which is exactly the kind of disagreement this app exists not to have.
    /// The two operations compose into one table (`StudioSwing.playbackTable`).
    func displayReady(_ buffer: CVPixelBuffer, wireCodes: Bool,
                      transfer: SignalTransfer = .sdr) -> CVPixelBuffer {
        guard let table = StudioSwing.playbackTable(wireCodes: wireCodes,
                                                    transfer: transfer)
        else { return buffer }
        guard let expanded = levelsPool.buffer(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)),
              StudioSwing.map(buffer, into: expanded, table: table)
        else { return buffer }
        CVBufferPropagateAttachments(buffer, expanded)
        return expanded
    }
}
