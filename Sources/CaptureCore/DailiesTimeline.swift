@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// The timecode of every frame of one clip: a list of anchors (movie time →
/// timecode) and the frame rate that runs between them.
///
/// More than one anchor is not hypothetical — `TakeWriter` writes an extra
/// tc32 sample when the camera's Rec Run started mid-take, and a dailies
/// burn-in that only read the first sample would drift against the camera
/// original from that frame on. This is the piece the running-TC burn-in is
/// unit-tested against: pure frame math, no media.
public struct DailiesTimeline: Sendable, Equatable {
    public struct Anchor: Sendable, Equatable {
        /// Position on the movie timeline, seconds.
        public var seconds: Double
        public var timecode: Timecode

        public init(seconds: Double, timecode: Timecode) {
            self.seconds = seconds
            self.timecode = timecode
        }
    }

    /// Sorted by `seconds`; never empty (the engine builds a zero anchor when
    /// the file offers nothing).
    public var anchors: [Anchor]
    /// The VIDEO rate frames tick at (23.976, 25, 29.97…). The timecode's own
    /// nominal fps lives inside each anchor's `Timecode`.
    public var frameRate: Double

    public init(anchors: [Anchor], frameRate: Double) {
        self.anchors = anchors.sorted { $0.seconds < $1.seconds }
        self.frameRate = max(1, frameRate)
    }

    /// The timecode of the frame presented at `seconds` on the movie timeline:
    /// the covering anchor advanced by the real frames elapsed since it.
    /// `advanced(by:)` does the drop-frame labelling, so a 29.97 DF daily
    /// crosses minute boundaries exactly like the camera did.
    public func timecode(atSeconds seconds: Double) -> Timecode {
        // Half a frame of tolerance both ways: presentation times come out of
        // rational CMTime math and land a hair off the ideal grid, and a frame
        // that reads as "one tick before its own anchor" would burn in the
        // previous anchor's timecode.
        let halfFrame = 0.5 / frameRate
        let anchor = anchors.last { $0.seconds <= seconds + halfFrame }
            ?? anchors.first
            ?? Anchor(seconds: 0, timecode: Timecode(
                frameNumber: 0, fps: Int(frameRate.rounded())))
        let elapsed = Int(((seconds - anchor.seconds) * frameRate).rounded())
        return anchor.timecode.advanced(by: max(0, elapsed))
    }

    /// The burned-in text for the frame at `seconds` ("10:00:04:12", ";" before
    /// FF for drop-frame — `Timecode`'s own spelling).
    public func text(atSeconds seconds: Double) -> String {
        timecode(atSeconds: seconds).description
    }
}

public extension TimecodeReader {
    /// EVERY timecode sample of the file's tc32 track, as timeline anchors —
    /// the multi-sample counterpart of `startTimecode(of:)`, which stops at
    /// the first. Empty when there is no track or nothing in it parses.
    static func timelineAnchors(of asset: AVAsset) async -> [DailiesTimeline.Anchor] {
        guard let track = try? await asset.tracks(ofType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var anchors: [DailiesTimeline.Anchor] = []
        while let sample = output.copyNextSampleBuffer() {
            // Empty marker buffers (numSamples == 0) are normal at the head of
            // the track; anchors only come from samples that carry data.
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let timecode = Self.timecode(from: sample) else { continue }
            anchors.append(DailiesTimeline.Anchor(
                seconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                timecode: timecode))
        }
        return anchors
    }

    /// One tc32 sample → the timecode it starts at. The same four big-endian
    /// bytes `startTimecode(of:)` decodes, shared so the two readers cannot
    /// drift apart in how they read the flags.
    private static func timecode(from sample: CMSampleBuffer) -> Timecode? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample)
        else { return nil }
        var raw: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4,
                                         destination: &raw) == noErr
        else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(description))
        guard quanta > 0 else { return nil }
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(description)
        return Timecode(frameNumber: Int(UInt32(bigEndian: raw)), fps: quanta,
                        isDropFrame: flags & kCMTimeCodeFlag_DropFrame != 0)
    }
}
