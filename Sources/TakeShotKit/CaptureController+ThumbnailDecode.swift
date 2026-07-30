import AVFoundation
import AppKit
import CBraw
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Decoding one preview image, by format.
///
/// Split out of `+Thumbnails`: everything here is `nonisolated static` and runs
/// off the main actor, because a folder of Other content is a hundred files and
/// each of them is a decode.
extension CaptureController {
    /// One Other-content preview, by format: stills decode straight, a
    /// CinemaDNG folder shows its middle frame, BRAW goes through the bridge,
    /// everything else through AVAssetImageGenerator. The duration comes back
    /// with it when the format knows it (Other content shows it in the cell).
    nonisolated static func otherThumbnail(
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
