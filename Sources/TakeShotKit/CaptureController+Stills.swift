import AVFoundation
import AppKit
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

/// Stills, both directions: showing one in the player, and making one from
/// whatever is on screen.
///
/// One file because they share the rule that makes them work — a still is a
/// deliverable, not a screenshot. It goes through the same tap render as video
/// (SwiftUI's `Image` is color-managed differently and never matched), and a
/// grab never bakes the preview LUT: a look appears in a still only when it is
/// in the clip itself.
///
/// Split out of `+Playback`, which had grown to hold the engine switch, the
/// asynchronous format read and both of these at once.
extension CaptureController {
    /// Decode a still into Rec.709 display code values and hand it to the tap.
    func loadStill(url: URL) {
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
            guard let buffer = CIBufferRender.render(
                image, width: cg.width, height: cg.height, into: space)
            else { return }
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

    /// Grab the current frame as a PNG next to the takes. In playback it grabs the
    /// current player frame (with the LUT); otherwise the live processed frame.
    func grabFrame() {
        if viewerMode == .playback, playbackURL != nil {
            // RAW engine and stills have no AVPlayer item — grab what's on
            // screen instead of silently arming a LIVE-camera grab
            if let raw = rawPlayer, let buffer = raw.currentBuffer() {
                saveGrab(buffer: buffer)
            } else if player.currentItem != nil, let url = playbackURL {
                grabPlaybackFrame(url: url)
            } else if let buffer = playbackTap.currentBuffer() {
                saveGrab(buffer: buffer)
            } else {
                lastError = L("toast_grab_failed")
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
    private func grabPlaybackFrame(url: URL) {
        let time = player.currentTime()
        // stills are deliverables like the recording: the preview LUT is never
        // baked in — a look appears in a still only when it is in the clip itself
        Task { [weak self] in
            let cg = await Self.decodeStill(from: url, at: time)
            await MainActor.run {
                guard let cg else { self?.lastError = L("toast_grab_failed"); return }
                self?.saveGrab(NSBitmapImageRep(cgImage: cg)
                    .representation(using: .png, properties: [:]))
            }
        }
    }

    /// One frame out of a clip on disk, decoded off the main actor.
    ///
    /// The asset and the generator are built HERE rather than handed in from
    /// the player's item. Neither type is Sendable, and the decode has always
    /// run off the main actor — so instead of asserting that a main-actor
    /// object may be carried onto another thread, the pair is created on the
    /// thread that uses it and dies there. It costs one extra open of a file
    /// the player already has open, once per grab, on an operator's keypress.
    private nonisolated static func decodeStill(from url: URL,
                                                at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: time).image
    }
    private func saveGrab(_ png: Data?) {
        guard let png else { lastError = L("toast_grab_failed"); return }
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
            lastError = L("toast_grab_failed_reason", error.localizedDescription)
        }
    }
    private static func grabTimeStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
