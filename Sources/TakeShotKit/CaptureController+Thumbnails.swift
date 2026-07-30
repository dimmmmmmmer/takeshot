import AVFoundation
import AppKit
import CaptureCore
import CBraw
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import os.log

/// Thumbnails for the takes panel and the Other content block.
///
/// Split out of CaptureController+Library: decoding is its own concern, and
/// every decoder here runs off the main actor.
extension CaptureController {
    static let thumbnailCacheLimit = 120

    /// Grid cells ask for thumbnails as they appear — decoding every take
    /// eagerly pinned 100+ MB of images the list mode never shows.
    func requestThumbnail(for take: Take) {
        guard thumbnails[take.id] == nil,
              !thumbnailsInFlight.contains(take.id) else { return }
        thumbnailsInFlight.insert(take.id)
        generateThumbnail(for: take)
    }
    func requestOtherThumbnail(for url: URL) {
        guard otherThumbnails[url] == nil,
              !otherThumbsInFlight.contains(url) else { return }
        otherThumbsInFlight.insert(url)
        generateOtherThumbnails(for: [url])
    }
    private func storeThumbnail(_ image: NSImage, for id: Take.ID) {
        thumbnails[id] = image
        thumbnailLRU.removeAll { $0 == id }
        thumbnailLRU.append(id)
        while thumbnailLRU.count > Self.thumbnailCacheLimit {
            thumbnails[thumbnailLRU.removeFirst()] = nil
        }
    }
    /// A preview frame from the recorded file; the file finalizes asynchronously,
    /// so several attempts with a pause.
    private func generateThumbnail(for take: Take) {
        Task.detached(priority: .utility) { [weak self] in
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: take.url.path) {
                    let asset = AVURLAsset(url: take.url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 256, height: 256)
                    let time = CMTime(seconds: min(1.0, take.durationSeconds / 2),
                                      preferredTimescale: 600)
                    if let (cgImage, _) = try? await generator.image(at: time) {
                        // NSImage predates Sendable; the box states the contract
                        // (built here, handed over once, used only on main)
                        let image = UncheckedSendable(NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width,
                                         height: cgImage.height)))
                        await MainActor.run { [weak self] in
                            self?.storeThumbnail(image.value, for: take.id)
                            self?.thumbnailsInFlight.remove(take.id)
                        }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // every attempt failed: clear the in-flight mark or this take can
            // never be retried for the rest of the session
            await MainActor.run { [weak self] in
                _ = self?.thumbnailsInFlight.remove(take.id)
            }
        }
    }
    /// Thumbnails for Other content: photos directly, videos via a frame generator.
    private func generateOtherThumbnails(for urls: [URL]) {
        let missing = urls.filter { otherThumbnails[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for url in missing {
                let (image, duration) = await Self.otherThumbnail(for: url)
                if let duration {
                    await MainActor.run { [weak self] in
                        self?.otherDurations[url] = duration
                    }
                }
                // The in-flight mark comes off whether or not a preview was
                // decoded. Removing it only on success left a file that failed
                // once — half-copied onto the card, say — marked in flight for
                // the rest of the session, so it could never be retried even
                // after the copy finished.
                if let image {
                    let boxed = UncheckedSendable(image) // NSImage predates Sendable
                    await MainActor.run { [weak self] in
                        self?.otherThumbnails[url] = boxed.value
                        self?.otherThumbsInFlight.remove(url)
                    }
                } else {
                    await MainActor.run { [weak self] in
                        _ = self?.otherThumbsInFlight.remove(url)
                    }
                }
            }
        }
    }
    /// One Other-content preview, by format: stills decode straight, a
    /// CinemaDNG folder shows its middle frame, BRAW goes through the bridge,
    /// everything else through AVAssetImageGenerator. The duration comes back
    /// with it when the format knows it (Other content shows it in the cell).
    nonisolated private static func otherThumbnail(
        for url: URL) async -> (image: NSImage?, duration: Double?) {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return (imageThumbnail(at: url), nil)
        }
        if isCinemaDNGFolder(url) {
            let frames = DNGSequenceSource.frameURLs(in: url)
            let middle = frames.dropFirst(frames.count / 2).first
            return (middle.flatMap { imageThumbnail(at: $0) },
                    Double(frames.count) / 24.0)
        }
        if ext == "braw" {
            return brawThumbnail(at: url)
        }
        return await videoThumbnail(at: url)
    }
    /// Thumbnail-sized decode: a full 24 MP still would pin ~100 MB in the cache.
    nonisolated private static func imageThumbnail(at url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg,
                       size: NSSize(width: cg.width, height: cg.height))
    }
    nonisolated private static func brawThumbnail(
        at url: URL) -> (image: NSImage?, duration: Double?) {
        guard let clip = try? CBRClip(path: url.path) else { return (nil, nil) }
        var image: NSImage?
        if clip.frameCount > 0,
           let buffer = clip.copyFrame(at: clip.frameCount / 2) {
            image = thumbnail(from: buffer, maxSize: 256)
        }
        let duration = clip.frameRate > 0
            ? Double(clip.frameCount) / Double(clip.frameRate) : nil
        return (image, duration)
    }
    nonisolated private static func videoThumbnail(
        at url: URL) async -> (image: NSImage?, duration: Double?) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        var image: NSImage?
        if let (cgImage, _) = try? await generator.image(
            at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
            image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width,
                                         height: cgImage.height))
        }
        let duration = (try? await asset.load(.duration))?.seconds
        return (image, duration)
    }
    nonisolated private static func thumbnail(from buffer: CVPixelBuffer,
                                              maxSize: CGFloat) -> NSImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxSize / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
