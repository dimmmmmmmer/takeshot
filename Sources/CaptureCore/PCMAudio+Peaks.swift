@preconcurrency import CoreMedia
import Foundation

/// Peak metering: what the audio panel's meters read off one packet.
///
/// Split out of PCMAudio, which otherwise builds and re-packs buffers for the
/// writer and the monitor. Metering only ever reads one.
extension PCMAudio {
    /// What a channel of exact digital silence reads, and the ONE place that
    /// number is written down.
    ///
    /// Two readers depend on it meaning the same thing, which is why it is a
    /// constant rather than a literal in `dBFS`: the meters pin an empty
    /// channel to the bottom of their scale with it, and
    /// `AudioChannelDetector` reads `level > silenceLevel` as "this channel is
    /// carrying a stream". That second reading is only exact because the
    /// smallest NON-zero peak an Int16 sample can have is 1 LSB, which is
    /// 20·log10(1/32767) = -90.3 dBFS — comfortably above this floor, so the
    /// `max` in `dBFS` below can never pull a carrying channel down onto it.
    /// Move this number up past -90.3 and the detector stops being a test for
    /// silence and starts being a test for loudness, which is a different
    /// question and one standby cannot answer (see `AudioChannelDetector`).
    public static let silenceLevel: Float = -100

    /// Per-channel peak levels in dBFS (-∞ → `silenceLevel`) from an
    /// interleaved PCM16 sample buffer.
    public static func peakLevels(of sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let asbd = interleavedPCM16(of: sampleBuffer),
              asbd.mFormatID == kAudioFormatLinearPCM else { return [] }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0,
              let samples = interleavedSamples(of: sampleBuffer),
              samples.count >= channels else { return [] }
        return peaks(of: samples, channels: channels).map(Self.dBFS)
    }

    /// Largest magnitude per channel.
    private static func peaks(of samples: [Int16], channels: Int) -> [Int16] {
        var peaks = [Int16](repeating: 0, count: channels)
        for frame in 0..<(samples.count / channels) {
            for channel in 0..<channels {
                let value = samples[frame * channels + channel]
                // Int16.min has no positive counterpart — clamp to max
                let magnitude = value == Int16.min ? Int16.max : abs(value)
                peaks[channel] = max(peaks[channel], magnitude)
            }
        }
        return peaks
    }

    /// Sample magnitude as dBFS, with silence pinned at the meter floor.
    private static func dBFS(_ peak: Int16) -> Float {
        peak == 0
            ? silenceLevel
            : max(silenceLevel, 20 * log10(Float(peak) / Float(Int16.max)))
    }

    /// How long a packet is, in seconds — what `AudioChannelDetector` counts
    /// its observation in.
    ///
    /// The buffer's own duration first, because that is what the source said.
    /// Derived from the sample count and the stream's rate when it is not
    /// numeric, because a detector that silently never accumulates would
    /// silently never answer, and "the feature quietly did nothing" is the
    /// failure mode this whole area is trying to stop being possible. 0 when
    /// neither can be read at all, which the detector ignores.
    public static func seconds(of sampleBuffer: CMSampleBuffer) -> Double {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isNumeric, duration.seconds > 0 { return duration.seconds }
        guard let asbd = interleavedPCM16(of: sampleBuffer),
              asbd.mSampleRate > 0 else { return 0 }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return 0 }
        return Double(frames) / asbd.mSampleRate
    }
}
