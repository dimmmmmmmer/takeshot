import AVFoundation
import CoreMedia
import Foundation

/// Reads the start timecode from a .mov timecode track
/// (the inverse of what TakeWriter writes).
public enum TimecodeReader {
    public static func startTimecode(of asset: AVAsset) async -> Timecode? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        // the first buffers may be empty markers (numSamples == 0) —
        // skip forward to a sample that has data
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

        // tc32: one big-endian UInt32 with the frame number
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
