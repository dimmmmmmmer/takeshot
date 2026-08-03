import AVFoundation
import CaptureCore
import CoreMedia
import Foundation
import SwiftUI

/// What the loaded clip turns out to be: its raster, its frame rate and its
/// start timecode, and the readouts built from them.
///
/// Split out of `+Playback`: opening a clip is one job, reading it back off the
/// file asynchronously is another, and the timecode arithmetic below is the
/// part the transport and the badges both depend on.
extension CaptureController {
    /// Playback position as timecode (start TC + elapsed at the file's fps).
    var playbackTimecodeText: String {
        if let raw = rawPlayer {
            return raw.timecodeText
        }
        let elapsed = max(0, player.currentTime().seconds)
        let fps = max(1, playbackFPS)
        let frames = Int((elapsed * fps).rounded(.down))
        guard let start = playbackStartTC else {
            let total = Int(elapsed)
            let ff = frames % Int(fps.rounded())
            return String(format: "%02d:%02d:%02d:%02d",
                          total / 3600, (total / 60) % 60, total % 60, ff)
        }
        var tc = start
        tc.fps = Int(fps.rounded())
        return Timecode(frameNumber: start.frameNumber + frames,
                        fps: tc.fps, isDropFrame: start.isDropFrame).description
    }

    /// TC text for an arbitrary player position (transport readouts).
    func playbackTC(atSeconds seconds: Double) -> String {
        let fps = max(1, playbackFPS)
        let frames = Int((max(0, seconds) * fps).rounded(.down))
        let fpsInt = max(1, Int(fps.rounded()))
        if let start = playbackStartTC {
            return Timecode(frameNumber: start.frameNumber + frames,
                            fps: fpsInt,
                            isDropFrame: start.isDropFrame).description
        }
        return Timecode(frameNumber: frames, fps: fpsInt).description
    }

    func loadPlaybackInfo(for item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            guard let track = try? await asset.tracks(ofType: .video).first
            else { return }
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let fps = Double((try? await track.load(.nominalFrameRate)) ?? 25)
            var startTC: Timecode?
            if let tcTrack = try? await asset.tracks(ofType: .timecode).first,
               let (frame, fdesc) = try? await Self.firstTimecodeSample(of: tcTrack) {
                let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fdesc))
                let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fdesc)
                startTC = Timecode(frameNumber: Int(frame), fps: max(1, quanta),
                                   isDropFrame: flags & kCMTimeCodeFlag_DropFrame != 0)
            }
            await MainActor.run { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.playbackFormatText = Self.shortFormat(
                    height: Int(size.height), fps: fps)
                self.playbackStartTC = startTC
                self.playbackFPS = fps > 0 ? fps : 25
                self.playbackAspect = size.height > 0
                    ? size.width / size.height : nil
            }
        }
    }

    /// The short format badge — "1080p25", "2160p24".
    ///
    /// One spelling, because there were two: the RAW engine rounded the rate
    /// unconditionally and the AVFoundation path rounded only within 0.05 of an
    /// integer, so a rate further off than that read differently depending on
    /// which engine opened the clip. The near-integer rates cameras actually
    /// shoot (23.976, 29.97) round either way, which is why it went unnoticed.
    nonisolated static func shortFormat(height: Int, fps: Double) -> String {
        guard fps > 0 else { return "\(height)p?" }
        let rate = abs(fps.rounded() - fps) < 0.05
            ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
        return "\(height)p\(rate)"
    }

    /// First tc32 sample of a timecode track: the start frame number.
    nonisolated private static func firstTimecodeSample(
        of track: AVAssetTrack) async throws -> (UInt32, CMTimeCodeFormatDescription)? {
        let descriptions = try await track.load(.formatDescriptions)
        guard let fdesc = descriptions.first,
              CMFormatDescriptionGetMediaType(fdesc) == kCMMediaType_TimeCode
        else { return nil }
        let asset = track.asset
        guard let asset else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        // Walk to the first sample that carries data. The first buffer of a
        // timecode track is routinely an EMPTY marker — bailing out on it left
        // playbackStartTC nil for every file TakeShot itself records, so the
        // playback readout counted from 00:00:00:00 instead of the take's TC.
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  CMBlockBufferGetDataLength(block) >= 4 else { continue }
            var raw: UInt32 = 0
            CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                       dataLength: 4, destination: &raw)
            return (UInt32(bigEndian: raw), fdesc)
        }
        return nil
    }
}
