@preconcurrency import CoreMedia
import Foundation

/// Peak metering: what the audio panel's meters read off one packet.
///
/// Split out of PCMAudio, which otherwise builds and re-packs buffers for the
/// writer and the monitor. Metering only ever reads one.
extension PCMAudio {
    /// Per-channel peak levels in dBFS (-∞ → -100) from an interleaved PCM16 sample buffer.
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
        peak == 0 ? -100 : max(-100, 20 * log10(Float(peak) / Float(Int16.max)))
    }
}
