@preconcurrency import AVFoundation
import Foundation

/// **Every review copy at the same level** — what the loudness measurement is
/// FOR (owner, on what else dailies should carry: audio normalisation).
///
/// A director watching rushes should not be reaching for the volume between
/// takes, and the sound department should not be shipping a copy that
/// distorts because somebody turned it up to hear the last one. So a daily
/// gets ONE gain, computed from the take's own measured loudness.
///
/// # One gain for the whole file, and why
///
/// A daily can carry several sound tracks — the camera's, and a recordist's
/// file matched to the take — and a player plays them together. Normalising
/// each one separately would rewrite the balance BETWEEN them, which is the
/// one relationship this app has no business judging: it is what the recordist
/// and the camera produced. So the gain is measured on the source's own sound
/// and applied to every leg, and what the viewer hears moves as one.
///
/// The consequence is stated rather than hidden: a take whose own audio track
/// is silent is not normalised at all, even when a recordist's file under it
/// is not. A gain computed from silence is a number nobody measured.
///
/// # Up is capped and down is not
///
/// Turning a hot take down never costs anything. Turning a quiet one up brings
/// its noise floor with it, and past a dozen decibels the source has a problem
/// no gain fixes — a review copy of amplified hiss is not more watchable than
/// a quiet one. So the boost stops at `maximumBoost` and the attenuation does
/// not stop at all.
public enum AudioGain {
    /// EBU R128's programme loudness target. The broadcast standard rather
    /// than a streaming one, because a daily is production paperwork and a
    /// viewer can turn a knob up — while nothing undoes a clip.
    public static let targetLUFS = -23.0
    /// The gain will not push a sample past this, in dBFS.
    ///
    /// A SAMPLE peak, not a true peak: a true-peak meter oversamples by four
    /// to find what the reconstruction filter does between samples, which is a
    /// different measurement with a different cost. One decibel of headroom is
    /// about what that difference is worth on material like this, so the
    /// ceiling is where it is for that reason rather than by convention.
    public static let ceilingDBFS = -1.0
    /// How far up a take can be brought. See the note above.
    public static let maximumBoost = 12.0

    /// The gain in decibels for a measured take, or nil when there is nothing
    /// to go on — which is silence, and a file with no audio at all.
    public static func decibels(loudness: Double?, peak: Double) -> Double? {
        guard let loudness, loudness.isFinite else { return nil }
        let wanted = min(targetLUFS - loudness, maximumBoost)
        guard peak > 0 else { return wanted }
        // …and never past the ceiling, which is the half a loudness target
        // cannot see: a quiet programme with one loud transient in it is
        // exactly the take a boost would clip. The ceiling is a promise about
        // the OUTPUT, so a take that already peaks above it comes down — by
        // the decibel that takes, and no more.
        return min(wanted, ceilingDBFS - 20 * log10(peak))
    }

    /// The same as a linear multiplier, which is what a sample is scaled by.
    public static func factor(loudness: Double?, peak: Double) -> Double? {
        decibels(loudness: loudness, peak: peak).map { pow(10, $0 / 20) }
    }

    /// One interleaved 16-bit sample buffer with `factor` applied.
    ///
    /// A NEW buffer rather than a write into the reader's: a decoder's block
    /// buffer may be shared with something that has not finished with it, and
    /// the one failure that would produce is the kind nobody reproduces.
    ///
    /// A factor of exactly 1 hands the buffer straight back, so a run with
    /// normalisation off — or a take already on the target — costs nothing.
    public static func apply(_ factor: Double,
                             to sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard factor != 1 else { return sample }
        guard let source = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            source, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 2 else { return nil }
        var scaled = [Int16](repeating: 0, count: length / 2)
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { raw in
            for index in 0..<(length / 2) {
                scaled[index] = clamp(Double(raw[index]) * factor)
            }
        }
        return rebuilt(sample, from: scaled, bytes: length)
    }

    /// Full scale is ±32 767 on the way OUT: −32 768 has no positive twin, and
    /// a sample that wrapped instead of clipping is a click.
    static func clamp(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-32_767, min(32_767, value.rounded())))
    }

    /// The same sample, timings and format, around new bytes.
    private static func rebuilt(_ sample: CMSampleBuffer, from scaled: [Int16],
                                bytes length: Int) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &block) == noErr, let block
        else { return nil }
        let written = scaled.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: length)
        }
        guard written == noErr else { return nil }
        // **Built rather than copied-and-repointed.** `CMSampleBufferCreateCopy`
        // brings the data buffer with it and `CMSampleBufferSetDataBuffer`
        // refuses a buffer that already has one — measured, as a nil from
        // every call. So the new bytes get a new sample buffer around them,
        // carrying the original's format, timing and sizes unchanged.
        let count = CMSampleBufferGetNumSamples(sample)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(),
                                           count: max(1, count))
        var timingsProduced = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: max(1, count), arrayToFill: &timings,
            entriesNeededOut: &timingsProduced) == noErr else { return nil }
        var sizes = [Int](repeating: 0, count: max(1, count))
        var sizesProduced = 0
        // A constant-bitrate stream states no per-sample sizes at all, and
        // passing an array it did not give is how a valid buffer is rejected.
        if CMSampleBufferGetSampleSizeArray(
            sample, entryCount: max(1, count), arrayToFill: &sizes,
            entriesNeededOut: &sizesProduced) != noErr {
            sizesProduced = 0
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: CMSampleBufferGetFormatDescription(sample),
            sampleCount: count, sampleTimingEntryCount: timingsProduced,
            sampleTimingArray: timings, sampleSizeEntryCount: sizesProduced,
            sampleSizeArray: sizesProduced > 0 ? sizes : nil,
            sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
}
