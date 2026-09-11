@preconcurrency import AVFoundation
import Foundation

/// **A tc32 timecode track: the format description, the input, and the four
/// bytes of a sample.**
///
/// One statement of the layout, because two writers make one now. A TAKE gets
/// a track that runs with the camera — re-anchored mid-shot, committed as the
/// recording goes, tail written at the end (`TakeWriter+Timecode`, which owns
/// all of that and none of this). A DAILY gets the source's anchors written
/// once, when its transcode finishes.
///
/// The reason they share this rather than each spelling it out: one tc32
/// sample is a big-endian frame NUMBER and a duration, and getting it wrong
/// produces a file whose timecode reads plausibly and lines up with nothing.
/// The only thing worse than one place to get that wrong is two places to get
/// it wrong differently.
enum TimecodeTrack {
    /// The tc32 format description for a track anchored at `timecode`, ticking
    /// at `frameDuration`.
    ///
    /// `frameQuanta` is the timecode's own nominal fps (30 for 29.97 DF), and
    /// the frame duration is the VIDEO rate — the two differ for every pulled
    /// rate there is, and swapping them is a clock that drifts one frame in a
    /// thousand.
    static func formatDescription(for timecode: Timecode, frameDuration: CMTime)
        -> CMTimeCodeFormatDescription? {
        var description: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: frameDuration,
            frameQuanta: UInt32(timecode.fps),
            flags: timecode.isDropFrame
                ? kCMTimeCodeFlag_DropFrame | kCMTimeCodeFlag_24HourMax
                : kCMTimeCodeFlag_24HourMax,
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr else { return nil }
        return description
    }

    /// The input such a track needs, added to the writer — or nil when the
    /// CONTAINER will not take one.
    ///
    /// **`canAdd` and not a bare `add`, because an `.mp4` refuses**: a
    /// timecode track is `tmcd`, a QuickTime media type, and adding one to an
    /// MPEG-4 writer raises an Objective-C exception that no Swift `try`
    /// catches — measured, as an aborted test process. A take is always a
    /// `.mov` and never meets this; an H.264 daily is an `.mp4` and always
    /// does, which is the same container limit the take's identity keys run
    /// into (see `DailiesSession.open`).
    ///
    /// Not real time in either caller: a take's timecode is four bytes a
    /// second beside a video input that owns the clock, and a daily's is
    /// written when its picture is already finished.
    static func input(for formatDescription: CMTimeCodeFormatDescription,
                      in writer: AVAssetWriter) -> AVAssetWriterInput? {
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    /// One tc32 sample covering `[from, until)`.
    ///
    /// tc32 is a single big-endian `UInt32`: the frame number the span STARTS
    /// at. Everything after it is counted from there by whatever reads the
    /// file, which is why a span's duration is as load-bearing as its value.
    static func sample(timecode: Timecode,
                       formatDescription: CMTimeCodeFormatDescription,
                       from: CMTime, until: CMTime) -> CMSampleBuffer? {
        guard until > from else { return nil }
        var frameNumber = UInt32(clamping: timecode.frameNumber).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 4, flags: 0,
            blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return nil }
        withUnsafeBytes(of: &frameNumber) { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: 4)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTimeSubtract(until, from),
            presentationTimeStamp: from,
            decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}
