import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Playing a take back, and grabbing stills from either source.
///
/// Split out of CaptureController: the type had grown past 2600 lines, the
/// size at which nobody reads it top to bottom any more.
extension CaptureController {
    /// RAW codecs played by our own engine, not AVPlayer.
    nonisolated static let rawExtensions: Set<String> = ["braw", "r3d"]

    /// A folder of .dng frames = one CinemaDNG clip.
    nonisolated static func isCinemaDNGFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !DNGSequenceSource.frameURLs(in: url).isEmpty
    }

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

    /// PNG of a playback buffer (RAW engine / still tap) in display code values.
    private func saveGrab(buffer: CVPixelBuffer) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let context = CIContext(options: [.cacheIntermediates: false])
            let png = CapturePipeline.pngData(from: buffer, ciContext: context)
            await MainActor.run { [weak self] in
                self?.saveGrab(png)
            }
        }
    }
    /// Instant replay (video assist): the freshest take, from the top, looping.
    func instantReplay() {
        guard let last = takes.max(by: { $0.recordedAt < $1.recordedAt })
        else { return }
        replayLoopRequested = true
        play(url: last.url)
        if let raw = rawPlayer {
            raw.isLooping = true
            replayLoopRequested = false
        }
    }
    /// Open a file in the player and switch to playback mode.
    /// Photos are just displayed (AVPlayer isn't needed for them).
    func play(url: URL) {
        playbackURL = url
        playbackFormatText = nil
        playbackStartTC = nil
        playbackAspect = nil
        playbackFPS = 25
        rawPlayer?.pause()
        rawPlayer = nil
        rawPlayerError = nil
        let ext = url.pathExtension.lowercased()
        let isRaw = Self.rawExtensions.contains(ext) || Self.isCinemaDNGFolder(url)
        if Self.imageExtensions.contains(ext), !isRaw {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            playbackLUTSuppressed = false
            loadStill(url: url)
        } else if isRaw {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playbackTap.detach()
            openRawClip(url: url)
        } else {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            playbackTap.attach(to: item)
            playbackTap.setCompareClip(url: compareClipURL, syncTo: player)
            playbackLUTSuppressed = false
            detectBakedLUT(for: item) // applies the LUT itself once it learns the tag
            player.play()
            loadPlaybackInfo(for: item)
        }
        viewerMode = .playback
        updateTapRunning()
        updateScopesRunning()
    }
    /// BRAW/CinemaDNG: our own engine, not AVPlayer. The badges come from the
    /// clip itself — there is no AVAsset to load them from.
    private func openRawClip(url: URL) {
        var openError: String?
        guard let model = RawPlayerModel(url: url, error: &openError) else {
            rawPlayerError = openError
            return
        }
        model.onScopeData = { [weak self] data in
            self?.live.scopeData = data
        }
        rawPlayer = model
        model.setViewAssist(assist)
        wirePlayoutRouting()
        playbackFormatText = "\(model.height)p\(Int(model.frameRate.rounded()))"
        playbackStartTC = model.startTimecode
        playbackFPS = model.frameRate
        playbackAspect = model.height > 0
            ? CGFloat(model.width) / CGFloat(model.height) : nil
        applyLetterboxColor()
        model.play()
    }
    /// Decode a still into Rec.709 display code values and hand it to the tap:
    /// stills render/compare/LUT exactly like video — SwiftUI Image was
    /// color-managed differently and stills never matched the player.
    private func loadStill(url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, [
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return }
            // managed input (embedded profile) rendered INTO the HDTV space:
            // identity for our own grabs, correct conversion for foreign files
            let attachments = [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ] as CFDictionary
            let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
                .takeRetainedValue() ?? CGColorSpaceCreateDeviceRGB()
            let image = CIImage(cgImage: cg)
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height,
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &buffer)
            guard let buffer else { return }
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = space
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let task = try? context.startTask(toRender: image,
                                                    to: destination),
                  (try? task.waitUntilCompleted()) != nil else { return }
            let boxed = UncheckedSendable(buffer)
            await MainActor.run { [weak self] in
                guard let self, self.playbackURL == url else { return }
                self.playbackTap.attachStill(boxed.value)
                self.playbackFormatText = "\(cg.height)p"
                self.playbackAspect = cg.height > 0
                    ? CGFloat(cg.width) / CGFloat(cg.height) : nil
                self.applyPlaybackLUT()
                self.updateTapRunning()
            }
        }
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
    private func loadPlaybackInfo(for item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            guard let track = try? await asset.loadTracks(withMediaType: .video).first
            else { return }
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let fps = Double((try? await track.load(.nominalFrameRate)) ?? 25)
            var startTC: Timecode?
            if let tcTrack = try? await asset.loadTracks(withMediaType: .timecode).first,
               let (frame, fdesc) = try? await Self.firstTimecodeSample(of: tcTrack) {
                let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fdesc))
                let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(fdesc)
                startTC = Timecode(frameNumber: Int(frame), fps: max(1, quanta),
                                   isDropFrame: flags & kCMTimeCodeFlag_DropFrame != 0)
            }
            await MainActor.run { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                let fpsText = fps > 0
                    ? (abs(fps.rounded() - fps) < 0.05
                       ? String(Int(fps.rounded())) : String(format: "%.2f", fps))
                    : "?"
                // same short style as the live badge: 1080p25
                self.playbackFormatText = "\(Int(size.height))p\(fpsText)"
                self.playbackStartTC = startTC
                self.playbackFPS = fps > 0 ? fps : 25
                self.playbackAspect = size.height > 0
                    ? size.width / size.height : nil
            }
        }
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
        guard let sample = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var raw: UInt32 = 0
        CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                   dataLength: 4, destination: &raw)
        return (UInt32(bigEndian: raw), fdesc)
    }
    /// Grab the current frame as a PNG next to the takes. In playback it grabs the
    /// current player frame (with the LUT); otherwise the live processed frame.
    func grabFrame() {
        if viewerMode == .playback, playbackURL != nil {
            // RAW engine and stills have no AVPlayer item — grab what's on
            // screen instead of silently arming a LIVE-camera grab
            if let raw = rawPlayer, let buffer = raw.currentBuffer() {
                saveGrab(buffer: buffer)
            } else if let item = player.currentItem {
                grabPlaybackFrame(item: item)
            } else if let buffer = playbackTap.currentBuffer() {
                saveGrab(buffer: buffer)
            } else {
                lastError = "Frame grab failed"
            }
        } else if isCapturing {
            // the grab lands on the pipeline queue; saving is main-actor work
            pipeline.grabNextFrame { [weak self] png in
                Task { @MainActor in self?.saveGrab(png) }
            }
        } else {
            lastError = L("no_signal")
        }
    }
    private func grabPlaybackFrame(item: AVPlayerItem) {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let time = player.currentTime()
        // stills are deliverables like the recording: the preview LUT is never
        // baked in — a look appears in a still only when it is in the clip itself
        Task { [weak self] in
            let cg = try? await generator.image(at: time).image
            await MainActor.run {
                guard let cg else { self?.lastError = "Frame grab failed"; return }
                self?.saveGrab(NSBitmapImageRep(cgImage: cg)
                    .representation(using: .png, properties: [:]))
            }
        }
    }
    private func saveGrab(_ png: Data?) {
        guard let png else { lastError = "Frame grab failed"; return }
        // project_cam_still_timecode
        let stamp = currentTimecode?.fileNameSafe ?? Self.grabTimeStamp()
        let name = NamingEngine.sanitize(
            [settings.projectName, settings.cameraLabel, "still", stamp]
                .filter { !$0.isEmpty }.joined(separator: "_"))
        let url = CapturePipeline.uniqueURL(for: destinationRoot
            .appendingPathComponent(name).appendingPathExtension("png"))
        do {
            try FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)
            try png.write(to: url)
            scanDestinationFolder() // show it in Other content right away
            flashNewItem(url)
            lastNotice = L("grab_saved", url.lastPathComponent)
        } catch {
            lastError = "Frame grab failed: \(error.localizedDescription)"
        }
    }
    private static func grabTimeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
