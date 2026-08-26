import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import os
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

    /// The two things a running encoder is asked to change, and the reason it
    /// can be asked at all.
    ///
    /// A monitoring feed has viewers who arrive in the middle of it. One that
    /// has just joined sees nothing until the next keyframe — up to a whole
    /// GOP of black — and a link that has narrowed needs fewer bits NOW, not
    /// after a reconnect. Both are properties VideoToolbox takes while the
    /// session runs, so neither costs a rebuild, and a rebuild is exactly what
    /// the viewer would see as a gap.
    ///
    /// Held under a lock because the asking and the encoding are on different
    /// queues by construction: frames arrive on the mirror's queue, and a
    /// viewer joins on the server's.
    private struct Live {
        var bitsPerSecond: Int
        var keyframeWanted = false
    }

    private let live: OSAllocatedUnfairLock<Live>

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
        live = OSAllocatedUnfairLock(
            initialState: Live(bitsPerSecond: configuration.bitsPerSecond))
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
        let properties: [CFString: CFTypeRef] = [
            // Drop quality rather than take longer. The frame path cannot wait.
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_ProfileLevel:
                kVTProfileLevel_H264_High_AutoLevel,
            // See the type comment: one frame of latency, and one timestamp.
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
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
        } + applyRate(configuration.bitsPerSecond, to: session)
    }

    /// The average and its one-second burst ceiling, which are one decision and
    /// are therefore set in one place — by the initial configuration and by
    /// every later change alike.
    ///
    /// Without a ceiling a keyframe is free to burst past whatever the link can
    /// carry, and on an SRT link a burst is exactly what fills the send buffer
    /// and drops the frames behind it.
    private static func applyRate(_ rate: Int,
                                  to session: VTCompressionSession) -> [String] {
        let pairs: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: rate)),
            (kVTCompressionPropertyKey_DataRateLimits,
             [NSNumber(value: rate / 8 * 3 / 2), NSNumber(value: 1.0)] as CFArray),
        ]
        return pairs.compactMap { key, value in
            VTSessionSetProperty(session, key: key, value: value) == noErr
                ? nil : key as String
        }
    }

    /// The bitrate the session is running at, which is not necessarily the one
    /// it was built with.
    var bitsPerSecond: Int { live.withLock { $0.bitsPerSecond } }

    /// Move the bitrate on a running session.
    ///
    /// The average and the one-second burst ceiling move TOGETHER, because they
    /// are one decision: leaving the old ceiling behind a lowered average lets
    /// a keyframe burst at the rate the link has just told us it cannot carry,
    /// which is the failure the ceiling exists to prevent. Returns the keys the
    /// session refused — empty when it took them — for the same reason
    /// `refusedProperties` exists: a discarded status is how a stream silently
    /// keeps running at a rate nobody chose.
    @discardableResult
    func setBitsPerSecond(_ rate: Int) -> [String] {
        let rate = max(64_000, rate)
        let refused = Self.applyRate(rate, to: session)
        if refused.isEmpty { live.withLock { $0.bitsPerSecond = rate } }
        return refused
    }

    /// What the SESSION says it is running at, read back out of it rather than
    /// remembered here.
    ///
    /// `refusedProperties` proves a property was ACCEPTED; this proves what it
    /// was accepted as, which is the difference between a dial that moved and
    /// one that only looks like it did. nil when the session will not say.
    var appliedRate: (average: Int, burstBytesPerSecond: Int)? {
        guard let average = Self.property(
                kVTCompressionPropertyKey_AverageBitRate, of: session)
                as? NSNumber,
              let limits = Self.property(
                kVTCompressionPropertyKey_DataRateLimits, of: session)
                as? [NSNumber],
              let bytes = limits.first
        else { return nil }
        return (average.intValue, bytes.intValue)
    }

    /// One property, read back. Through `Unmanaged` rather than a `CFTypeRef?`:
    /// the out parameter is a raw pointer, and forming one to an optional
    /// object reference is a warning this build does not carry.
    private static func property(_ key: CFString,
                                 of session: VTCompressionSession) -> Any? {
        var box: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: key, allocator: nil,
                                    valueOut: &box) == noErr,
              let value = box?.takeRetainedValue() else { return nil }
        return value
    }

    /// Ask for a keyframe on the next frame submitted.
    ///
    /// A request rather than a command: it is answered by the next `encode`,
    /// which is where VideoToolbox will take it. Repeated calls before that
    /// frame collapse into one — a room of viewers joining at once wants one
    /// keyframe between them, not one each.
    func requestKeyframe() {
        live.withLock { $0.keyframeWanted = true }
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
        let forced = live.withLock { state -> Bool in
            defer { state.keyframeWanted = false }
            return state.keyframeWanted
        }
        let frameProperties = forced
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time,
            duration: CMTime(value: step, timescale: scale),
            frameProperties: frameProperties, infoFlagsOut: nil
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
