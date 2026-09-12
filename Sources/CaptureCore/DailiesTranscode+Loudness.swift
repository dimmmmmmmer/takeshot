@preconcurrency import AVFoundation
import Foundation

/// **What the take measures, and what that makes the gain.**
///
/// Its own file beside `+Timecode` and `+Chapters` because it is one question
/// asked once per item — how loud is this, and by how much does it move — and
/// because the answer needs a whole second read of the source that nothing
/// else in the transcode does.
extension DailiesTranscode {
    /// The multiplier every sound leg is scaled by, or nil when the take has
    /// nothing to measure.
    ///
    /// The source's OWN audio, decoded through the same settings the transcode
    /// reads it with, so the number describes the samples that will actually
    /// be written rather than some other rendering of them.
    ///
    /// A file with no audio track, a silent one, or one too short to fill a
    /// 400 ms block all answer nil — and nil means no gain at all rather than
    /// a gain computed from nothing.
    static func audioFactor(of asset: AVAsset) async -> Double? {
        guard let measurement = await measure(asset) else { return nil }
        return AudioGain.factor(loudness: measurement.loudness,
                                peak: measurement.peak)
    }

    /// The take's loudness and peak, or nil when it cannot be read at all.
    static func measure(_ asset: AVAsset) async -> LoudnessMeter? {
        guard let tracks = try? await asset.tracks(ofType: .audio),
              !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: DailiesEngine.audioReadSettings())
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        while let sample = output.copyNextSampleBuffer() {
            meter.add(samples(of: sample))
        }
        reader.cancelReading()
        return meter
    }

    /// One decoded buffer as interleaved 16-bit samples.
    static func samples(of sample: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= 2 else { return [] }
        return pointer.withMemoryRebound(to: Int16.self,
                                         capacity: length / 2) { raw in
            Array(UnsafeBufferPointer(start: raw, count: length / 2))
        }
    }
}
