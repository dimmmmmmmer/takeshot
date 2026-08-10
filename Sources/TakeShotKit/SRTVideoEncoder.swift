import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import VideoToolbox

/// The display frame, encoded, because SRT carries a byte stream and not frames.
///
/// **Where this sits, and why that is the whole design question.** The display
/// stage produces one 8-bit BGRA buffer per frame and hands it to the preview,
/// the playout, the multiview and this. NDI cost 0.114 ms of the app's time
/// because there was nothing to do — its uncompressed RGB IS that buffer, so the
/// sender got the base address and the pass was an identity. An H.264 encode is
/// not that, and no amount of care makes it that. So it is arranged so that its
/// cost cannot reach the frame path AT ALL, rather than being kept small:
///
/// - It runs on `SRTVideoMirror`'s queue. The display queue's whole involvement
///   is a pixel-format check and one `dispatch_async`.
/// - Latest-wins upstream: at most one frame is submitted per pass, so a slow
///   encode makes the feed *fewer frames* and never makes it *later ones*.
/// - `RealTime` is on, which is what tells VideoToolbox to drop quality rather
///   than to take longer.
///
/// **H.264 High, hardware if there is any, and not HEVC.** Every SRT receiver a
/// set has decodes H.264 — VLC, OBS, Resolve, a monitor bridge, a cloud gateway.
/// HEVC over MPEG-TS is stream type 0x24 and is a coin toss on the same list, and
/// halving the bitrate is not worth a picture that does not come up on the
/// director's laptop. The bitrate is the operator's dial instead.
///
/// **Frame reordering is OFF**, which buys two things at once. A monitoring feed
/// is one frame behind the monitor rather than a GOP behind it; and presentation
/// order is coding order, so there is no decode timestamp for the muxer to carry
/// and no way for the two to disagree.
///
/// **The colour is declared, not converted.** The display buffer holds full-range
/// BGRA whose codes are Rec.709-encoded (the contract stated at
/// `MetalPreviewLayer`), and VideoToolbox's own BGRA-to-YCbCr pass is asked for
/// Rec.709 primaries, transfer and matrix. That pass also lands the result in
/// VIDEO range, which is what a receiver decoding a 709-tagged stream expects —
/// nominal black on 16, nominal white on 235 — so there is no swing decision to
/// get wrong here. `SRTEncodeTests` measures it through a real encode and decode
/// rather than asserting it.
///
/// Confined to `SRTVideoMirror`'s queue.
final class SRTVideoEncoder {
    /// What the session is built for. A change to any of it is a new session,
    /// which is why the mirror holds this and compares it per frame.
    struct Configuration: Equatable, Sendable {
        var width: Int
        var height: Int
        /// Frames per second, rounded — it sets the keyframe interval and the
        /// rate controller's expectation, and neither wants three decimals.
        var framesPerSecond: Int
        var bitsPerSecond: Int

        /// A keyframe a second.
        ///
        /// Short, and that is the point on an SRT feed: it is how long a receiver
        /// waits to join, how long a picture takes to come back after the link
        /// recovers, and how long a director staring at a frozen frame has to
        /// wait. A ten-second GOP would save bitrate nobody asked to save.
        var keyframeInterval: Int { max(1, framesPerSecond) }
    }

    /// Whether this machine can encode H.264 at all.
    ///
    /// Probed rather than assumed: it gates the suites that measure a real
    /// encode, and a headless runner is not a thing to guess about. One session
    /// built and thrown away, once.
    static let isSupported: Bool = {
        var probe: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &probe)
        if let probe { VTCompressionSessionInvalidate(probe) }
        return status == noErr && probe != nil
    }()

    let configuration: Configuration
    /// Property keys the session REFUSED, empty when it took them all.
    ///
    /// `VTSessionSetProperty` returns a status, and discarding it is exactly how a
    /// stream silently ends up at VideoToolbox's defaults: a key a future macOS
    /// drops, or one this file spells wrong, leaves the bitrate and the keyframe
    /// interval unset — and nothing downstream can tell, because the stream still
    /// decodes. So the refusals are collected, the mirror logs them, and
    /// `SRTEncodeTests` requires the list to be empty.
    let refusedProperties: [String]
    private let session: VTCompressionSession

    /// The session is created with NO output callback, deliberately: that is what
    /// lets each `encode` carry its own handler, so the closure's lifetime is
    /// VideoToolbox's problem rather than a retained refcon this file would have
    /// to release in the right order.
    ///
    /// `sink` receives the SAMPLE and not an access unit. That is the seam the
    /// muxer's input adapter sits on (`MPEGTSMuxer.accessUnit(from:)`), and it is
    /// also what lets a test decode what this produced — a sample carries its
    /// format description and an access unit has already dropped it.
    init(configuration: Configuration,
         sink: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        self.configuration = configuration
        self.sink = sink
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            // Asked for, not required: a machine with no hardware encoder gets
            // the software one rather than no feature.
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:
                    kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            throw SRTStreamError.configuration(
                "the H.264 encoder could not be created (\(status))")
        }
        session = created
        refusedProperties = Self.apply(configuration, to: created)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    private let sink: @Sendable (CMSampleBuffer) -> Void

    /// Everything the session is told, in one place.
    ///
    /// Deliberately short. Each of these is a departure from a default that would
    /// be wrong for a monitoring feed over a lossy link; anything not here is
    /// VideoToolbox's own choice, on purpose.
    @discardableResult
    private static func apply(_ configuration: Configuration,
                              to session: VTCompressionSession) -> [String] {
        // A ceiling on top of the average, over one second. Without it a keyframe
        // is free to burst past whatever the link can carry, and on an SRT link a
        // burst is exactly what fills the send buffer and drops the frames behind
        // it.
        let burst = [
            NSNumber(value: configuration.bitsPerSecond / 8 * 3 / 2),
            NSNumber(value: 1.0),
        ] as CFArray
        let properties: [CFString: CFTypeRef] = [
            // Drop quality rather than take longer. The frame path cannot wait.
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_ProfileLevel:
                kVTProfileLevel_H264_High_AutoLevel,
            // See the type comment: one frame of latency, and one timestamp.
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_AverageBitRate:
                NSNumber(value: configuration.bitsPerSecond),
            kVTCompressionPropertyKey_DataRateLimits: burst,
            kVTCompressionPropertyKey_MaxKeyFrameInterval:
                NSNumber(value: configuration.keyframeInterval),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:
                NSNumber(value: 1.0),
            kVTCompressionPropertyKey_ExpectedFrameRate:
                NSNumber(value: configuration.framesPerSecond),
            // The colour the display buffer is already in. See the type comment.
            kVTCompressionPropertyKey_ColorPrimaries:
                kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction:
                kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix:
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        return properties.compactMap { key, value in
            VTSessionSetProperty(session, key: key, value: value) == noErr
                ? nil : key as String
        }
    }

    /// Submit one frame.
    ///
    /// `ticks` is on the muxer's 90 kHz clock and must increase. It comes from the
    /// mirror's own monotonic clock rather than from anything on the frame: a
    /// monitoring feed's timing is when it was SENT, and the camera's timecode
    /// belongs to the file.
    func encode(_ buffer: CVPixelBuffer, ticks: Int64) {
        let scale = Int32(MPEGTSMuxer.clockHz)
        let time = CMTime(value: ticks, timescale: scale)
        let step = MPEGTSMuxer.clockHz
            / Int64(max(1, configuration.framesPerSecond))
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time,
            duration: CMTime(value: step, timescale: scale),
            frameProperties: nil, infoFlagsOut: nil
        ) { [sink] status, _, sample in
            guard status == noErr, let sample else { return }
            sink(sample)
        }
    }

    /// Finish and tear down. Called before the object is released: a session that
    /// is merely dropped can still call back into a sink whose owner has gone.
    func invalidate() {
        VTCompressionSessionCompleteFrames(session,
                                           untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }
}
