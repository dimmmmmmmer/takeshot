import AVFoundation
import CoreMedia
import Foundation

/// Чтение стартового таймкода из timecode-трека .mov
/// (обратная операция к тому, что пишет TakeWriter).
public enum TimecodeReader {
    public static func startTimecode(of asset: AVAsset) async -> Timecode? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        // первые буферы могут быть пустыми маркерами (numSamples == 0) —
        // листаем до сэмпла с данными
        var sampleWithData: CMSampleBuffer?
        for _ in 0..<16 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            if CMSampleBufferGetNumSamples(sample) > 0,
               CMSampleBufferGetDataBuffer(sample) != nil {
                sampleWithData = sample
                break
            }
        }
        guard let sample = sampleWithData,
              let block = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample)
        else { return nil }

        // tc32: один big-endian UInt32 с номером кадра
        var raw: UInt32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                         dataLength: 4, destination: &raw) == noErr
        else { return nil }
        let frameNumber = Int(UInt32(bigEndian: raw))

        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(description))
        guard quanta > 0 else { return nil }
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(description)
        let dropFrame = flags & kCMTimeCodeFlag_DropFrame != 0
        return Timecode(frameNumber: frameNumber, fps: quanta, isDropFrame: dropFrame)
    }
}
