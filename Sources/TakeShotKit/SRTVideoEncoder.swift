import CaptureCore
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
/// - It runs on `SRTMirror`'s queue. The display queue's whole involvement
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
/// **The colour is declared, not converted — and the declaration is READ off
/// the buffer.** The display buffer holds full-range BGRA, and VideoToolbox's
/// own BGRA-to-YCbCr pass is asked for the primaries, transfer and matrix that
/// buffer is tagged with. That pass also lands the result in VIDEO range, which
/// is what a receiver decoding the stream expects — nominal black on 16,
/// nominal white on 235 — so there is no swing decision to get wrong here.
/// `SRTEncodeTests` measures it through a real encode and decode rather than
/// asserting it.
///
/// It used to say Rec.709 and mean it as a constant. On an SDR day that is
/// right and is what `ColorTags` answers anyway. On an HDR day it was a lie the
/// app told about its own buffer: `CapturePipeline` tone maps a PQ or HLG frame
/// into a Rec.709 CURVE and tags it Rec.2020 PRIMARIES, because tone mapping is
/// per channel and cannot move the primaries. Declaring 709 over that handed
/// the director a desaturated picture beside a correct one on the cart — and
/// colour accuracy is not a nicety on this cart, it is the reason the operator
/// is looking at the monitor at all.
///
/// Confined to `SRTMirror`'s queue.
final class SRTVideoEncoder {
    /// What the session is built for. A change to any of it is a new session,
    /// which is why the mirror holds this and compares it per frame.
    /// **The five the operator chose**, apart from the raster and the rate the
    /// signal decides. Its own type so the settings can be read once, on the
    /// main actor, and handed to an encoder that is not on it.
    struct Dials: Equatable, Sendable {
        var codec: SRTVideoCodec = .h264
        var profile: SRTEncoderProfile = .high
        var rateControl: SRTRateControl = .average
        var keyframeSeconds: Int = 1
        var allowBFrames = false

        /// What the settings say.
        init(_ settings: SRTSettings) {
            codec = settings.codecEffective
            profile = settings.profileEffective
            rateControl = settings.rateControlEffective
            keyframeSeconds = settings.keyframeSecondsEffective
            allowBFrames = settings.bFramesEffective
        }

        /// What this encoder has always done.
        init() {}
    }

    struct Configuration: Equatable, Sendable {
        var width: Int
        var height: Int
        /// Frames per second, rounded — it sets the keyframe interval and the
        /// rate controller's expectation, and neither wants three decimals.
        var framesPerSecond: Int
        var bitsPerSecond: Int
        /// The colour the display buffer says it is in, as a `ColorTags`
        /// preset — nil for Rec.709, which is every SDR signal and therefore
        /// almost every day.
        ///
        /// Part of the session's identity, so an HDR camera swapped for an SDR
        /// one mid-day rebuilds rather than going on declaring the old colour.
        /// A rebuild is a keyframe and the parameter sets, which is exactly
        /// what a receiver needs in order to follow the change.
        var colorPreset: String?
        /// The five dials the operator can move (`SRTSettings`), each
        /// defaulted to what this encoder has always done — so a caller that
        /// does not care gets the stream it had.
        var codec: SRTVideoCodec = .h264
        var profile: SRTEncoderProfile = .high
        var rateControl: SRTRateControl = .average
        /// Seconds between keyframes.
        ///
        /// One by default, and that is the point on an SRT feed: it is how
        /// long a receiver waits to join, how long a picture takes to come
        /// back after the link recovers, and how long a director staring at a
        /// frozen frame has to wait. Longer saves bitrate — a trade the
        /// operator can now make and the app no longer makes for them.
        var keyframeSeconds: Int = 1
        /// Let the encoder reorder frames. Off: one frame of latency, and one
        /// timestamp — see the type comment.
        var allowBFrames = false

        /// Frames between keyframes, which is what VideoToolbox is told.
        var keyframeInterval: Int {
            max(1, framesPerSecond) * max(1, keyframeSeconds)
        }
    }

    /// Whether this machine can encode H.264 **and hand the sample back**.
    ///
    /// Probed by doing it, because creating a session and encoding a frame are
    /// two different claims and a virtualised runner is exactly where they come
    /// apart. It used to create a 64×64 session, throw it away, and call that
    /// support — and on CI `VTCompressionSessionCreate` succeeds on a machine
    /// whose paravirtualised GPU does not even match a driver
    /// (`IOServiceMatching failed for: AppleM2ScalerParavirtDriver` is in the
    /// log). Every suite gated on this then drove a real encode, waited out its
    /// budget and failed — six of them in one run, and the comment above those
    /// suites already promised they would report the code rather than the
    /// machine. This is what makes that promise true.
    ///
    /// Only tests read it, so it can afford to be thorough. The wait is bounded
    /// because the failure mode is not an error: the callback simply never
    /// comes, and an unbounded wait would hang the suite it exists to skip.
    static let isSupported: Bool = {
        let arrived = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            var probe: VTCompressionSession?
            let created = VTCompressionSessionCreate(
                allocator: nil, width: 64, height: 64,
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &probe)
            guard created == noErr, let session = probe else { return }
            defer { VTCompressionSessionInvalidate(session) }
            VTSessionSetProperty(session,
                                 key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue)
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                kCVPixelFormatType_32BGRA, nil, &pixels)
            guard let frame = pixels else { return }
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: frame,
                presentationTimeStamp: CMTime(value: 0, timescale: 600),
                duration: CMTime(value: 1, timescale: 600),
                frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, sample != nil { arrived.signal() }
            }
            guard status == noErr else { return }
            VTCompressionSessionCompleteFrames(
                session, untilPresentationTimeStamp: .invalid)
        }
        // Ten seconds is not a performance budget — a machine that encodes at
        // all answers in milliseconds. It is the line between slow and never.
        let answered = arrived.wait(timeout: .now() + 10) == .success
        _ = finished.wait(timeout: .now() + 1)
        return answered
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
        let colour = ColorTags.values(for: configuration.colorPreset)
        // A ceiling on top of the average, over one second. Without it a keyframe
        // is free to burst past whatever the link can carry, and on an SRT link a
        // burst is exactly what fills the send buffer and drops the frames behind
        // it.
        let properties: [CFString: CFTypeRef] = Self.properties(configuration)
        return properties.compactMap { key, value in
            VTSessionSetProperty(session, key: key, value: value) == noErr
                ? nil : key as String
        } + applyRate(configuration.bitsPerSecond, to: session,
                      constant: configuration.rateControl == .constant)
    }

    /// **Everything the session is told, as a value.**
    ///
    /// A dictionary rather than a sequence of `VTSessionSetProperty` calls, for
    /// one reason: the profile the operator picks was HARD-CODED here for the
    /// life of the feature. `profileLevel(_:)` was written, and tested, and
    /// never called — the suite exercised the helper and nothing exercised the
    /// call site, so a picker with five rows moved nothing at all and every
    /// HEVC session was asked for an H.264 level. Read back as a value, the
    /// properties are what a test can hold the dials against.
    static func properties(_ configuration: Configuration) -> [CFString: CFTypeRef] {
        let colour = ColorTags.values(for: configuration.colorPreset)
        return [
            // Drop quality rather than take longer. The frame path cannot wait.
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_ProfileLevel: profileLevel(configuration),
            // See the type comment: one frame of latency, and one timestamp.
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_MaxKeyFrameInterval:
                NSNumber(value: configuration.keyframeInterval),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:
                NSNumber(value: 1.0),
            kVTCompressionPropertyKey_ExpectedFrameRate:
                NSNumber(value: configuration.framesPerSecond),
            // The colour the display buffer is already in, out of the one table
            // that decides what any tag in this app says. See the type comment.
            kVTCompressionPropertyKey_ColorPrimaries: colour.cvPrimaries,
            kVTCompressionPropertyKey_TransferFunction: colour.cvTransfer,
            kVTCompressionPropertyKey_YCbCrMatrix: colour.cvMatrix,
        ]
    }

    /// The profile the session is asked for, per codec.
    ///
    /// The two are different families — H.264 is Baseline/Main/High, HEVC is
    /// Main/Main 10/Main 4:2:2 10 — so a profile from the wrong family is
    /// resolved to that codec's own default rather than refused
    /// (`SRTEncoderProfile.resolved(for:)`): the pickers are independent, and
    /// an operator who changes the codec has not asked to break the profile.
    static func profileLevel(_ configuration: Configuration) -> CFString {
        let profile = configuration.profile.resolved(for: configuration.codec)
        guard configuration.codec == .h264 else {
            switch profile {
            case .main10: return kVTProfileLevel_HEVC_Main10_AutoLevel
            case .main422Ten: return kVTProfileLevel_HEVC_Main42210_AutoLevel
            default: return kVTProfileLevel_HEVC_Main_AutoLevel
            }
        }
        switch profile {
        case .baseline: return kVTProfileLevel_H264_Baseline_AutoLevel
        case .main: return kVTProfileLevel_H264_Main_AutoLevel
        default: return kVTProfileLevel_H264_High_AutoLevel
        }
    }

    /// The average and its one-second burst ceiling, which are one decision and
    /// are therefore set in one place — by the initial configuration and by
    /// every later change alike.
    ///
    /// Without a ceiling a keyframe is free to burst past whatever the link can
    /// carry, and on an SRT link a burst is exactly what fills the send buffer
    /// and drops the frames behind it.
    private static func applyRate(_ rate: Int, to session: VTCompressionSession,
                                  constant: Bool = false) -> [String] {
        // **Constant is asked for, never assumed.** Not every encoder on every
        // machine takes `ConstantBitRate`, and a refusal is collected like any
        // other rather than failing the stream: the average and the ceiling
        // are set either way, so a session that refused CBR is still a session
        // with a rate limit — which is the property this link needs.
        var pairs: [(CFString, CFTypeRef)] = []
        if constant {
            pairs.append((kVTCompressionPropertyKey_ConstantBitRate,
                          NSNumber(value: rate)))
        }
        pairs += [
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
