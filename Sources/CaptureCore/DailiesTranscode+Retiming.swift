@preconcurrency import CoreMedia
import Foundation

/// **Putting a sound file's clock on the daily's.**
///
/// Split out of the transcode when that type reached its length ceiling, and a
/// coherent piece rather than an arbitrary cut: everything here is the
/// arithmetic of one leg's timestamps, which is the only thing that makes a
/// recordist's file line up with a picture it was not recorded against.
extension DailiesTranscode {
    /// A sample moved onto the daily's timeline. nil only when CoreMedia
    /// refuses the copy, and then the caller uses the sample as it came —
    /// sound on the wrong clock is still better than a track that stops.
    static func shifted(_ sample: CMSampleBuffer,
                        by shift: CMTime) -> CMSampleBuffer? {
        guard shift != .zero else { return sample }
        let count = CMSampleBufferGetNumSamples(sample)
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(), count: max(1, count))
        var produced = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: max(1, count), arrayToFill: &timings,
            entriesNeededOut: &produced) == noErr else { return nil }
        for index in 0..<produced {
            // Spelled out rather than `+=`: `CMTime`'s shorthand resolves to
            // the FloatingPoint overload and does not compile.
            timings[index].presentationTimeStamp =
                CMTimeAdd(timings[index].presentationTimeStamp, shift)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp =
                    CMTimeAdd(timings[index].decodeTimeStamp, shift)
            }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: produced, sampleTimingArray: timings,
            sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
}
