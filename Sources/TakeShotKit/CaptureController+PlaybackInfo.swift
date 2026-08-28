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
    /// Which engine is driving the picture under review. The one place that
    /// says so; see `PlaybackEngine` for why it is not asked inline.
    var playbackEngine: PlaybackEngine {
        PlaybackEngine.current(hasGrid: syncPlay != nil,
                               hasRawPlayer: rawPlayer != nil)
    }

    /// Whether the picture is actually moving right now.
    ///
    /// What the TC badge's 10 Hz tick is gated on — a paused readout is static
    /// and re-rendering it at 10 Hz is work with nothing to show for it. It
    /// asks the engine rather than two of the three engines, which is what it
    /// used to do: over a grid the badge simply stopped updating.
    var playbackIsRunning: Bool {
        switch playbackEngine {
        case .grid: return syncPlay?.isPlaying == true
        case .raw: return rawPlayer?.isPlaying == true
        case .single: return player.rate != 0
        }
    }

    /// Playback position as timecode (start TC + elapsed at the file's fps).
    var playbackTimecodeText: String {
        switch playbackEngine {
        case .grid:
            // 2–4 takes on one master timeline have no single timecode, and
            // each tile carries its own — see `PlaybackEngine`.
            return timecodeFallbackText
        case .raw:
            return rawPlayer?.timecodeText ?? timecodeFallbackText
        case .single:
            break
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

    /// What the clip turned out to be, reduced to values that can leave the
    /// load. An `AVAssetTrack` is not `Sendable` in any macOS SDK, so the
    /// tracks are read and asked their questions inside one nonisolated pass
    /// and only this crosses back to the main actor.
    struct ClipInfo: Sendable {
        var size: CGSize
        var fps: Double
        var startTimecode: Timecode?
    }

    /// The file is opened for its raster and rate rather than the item's own
    /// asset being read: an `AVPlayerItem` is main-actor state, and the tracks
    /// have to be walked off it (see `ClipInfo`, and the same decision in
    /// `PlaybackFrameTap.detectLevels`).
    func loadPlaybackInfo(for item: AVPlayerItem, at url: URL) {
        Task { [weak self] in
            guard let info = await Self.clipInfo(of: url) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.playbackFormatText = Self.shortFormat(
                    height: Int(info.size.height), fps: info.fps)
                self.playbackStartTC = info.startTimecode
                self.playbackFPS = info.fps > 0 ? info.fps : 25
                self.playbackAspect = info.size.height > 0
                    ? info.size.width / info.size.height : nil
            }
        }
    }

    /// Raster, rate and start timecode of one file. Nonisolated: no track and
    /// no format description ever leaves this scope.
    nonisolated private static func clipInfo(of url: URL) async -> ClipInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.tracks(ofType: .video).first
        else { return nil }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 25)
        var startTC: Timecode?
        if let tcTrack = try? await asset.tracks(ofType: .timecode).first,
           let (frame, fdesc) = try? await firstTimecodeSample(of: tcTrack) {
            let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fdesc))
            let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fdesc)
            startTC = Timecode(frameNumber: Int(frame), fps: max(1, quanta),
                               isDropFrame: flags & kCMTimeCodeFlag_DropFrame != 0)
        }
        return ClipInfo(size: size, fps: fps, startTimecode: startTC)
    }

    /// The short format badge for PLAYBACK — "1080p25", "2160p24".
    ///
    /// One spelling across the playback engines, because there were two: the RAW
    /// engine rounded the rate unconditionally and the AVFoundation path rounded
    /// only within 0.05 of an integer, so a rate further off than that read
    /// differently depending on which engine opened the clip. The near-integer
    /// rates cameras actually shoot (23.976, 29.97) round either way, which is
    /// why it went unnoticed.
    ///
    /// The LIVE badge is still a separate spelling (`playerShortFormat` /
    /// `playerFPSText`), and it disagrees here: it keeps the decimals for
    /// anything that is not an exact integer, so a 23.976 signal reads
    /// "1080p23.98" live and "1080p24" once the take is played back. Which of
    /// the two is right is a question for the operator — the board's own mode
    /// name is "1080p23.98" and the ALE writes 23.976 — so it is left stated
    /// rather than silently unified.
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
