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
    /// everything else through AVAssetImageGenerator.
    nonisolated static func otherThumbnail(for url: URL) async -> OtherPreview {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let (image, pixels) = imageThumbnail(at: url)
            return OtherPreview(image: image, pixelSize: pixels)
        }
        if isCinemaDNGFolder(url) {
            let frames = DNGSequenceSource.frameURLs(in: url)
            let middle = frames.dropFirst(frames.count / 2).first
            return OtherPreview(image: middle.flatMap { imageThumbnail(at: $0).image },
                                duration: Double(frames.count) / 24.0)
        }
        if ext == "braw" || ext == "r3d" {
            let (image, duration) = rawThumbnail(at: url, extension: ext)
            return OtherPreview(image: image, duration: duration)
        }
        let (image, duration) = await videoThumbnail(at: url)
        return OtherPreview(image: image, duration: duration)
    }
    /// Thumbnail-sized decode: a full 24 MP still would pin ~100 MB in the cache.
    ///
    /// The pixel size comes from the file's PROPERTIES, not from the thumbnail
    /// that was just decoded: the decode is capped at 256 px, so the image's own
    /// size would report the cap back as the photo's resolution.
    nonisolated private static func imageThumbnail(
        at url: URL) -> (image: NSImage?, pixels: CGSize?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return (nil, nil) }
        var pixels: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0, height > 0 {
            pixels = CGSize(width: width, height: height)
        }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary) else { return (nil, pixels) }
        return (NSImage(cgImage: cg,
                        size: NSSize(width: cg.width, height: cg.height)), pixels)
    }
    /// BRAW and R3D through their own bridges — AVAssetImageGenerator cannot
    /// open either, and until this branch existed an .r3d showed the generic film
    /// glyph and no duration.
    ///
    /// Both go through `RawClipSource`, the same abstraction the player uses,
    /// rather than reaching into the bridges directly as the BRAW path used to:
    /// one decode contract, and the R3D options (a small decode scale for a
    /// 256 px thumbnail) are stated in one place.
    nonisolated private static func rawThumbnail(
        at url: URL, extension ext: String) -> (image: NSImage?, duration: Double?) {
        let clip: RawClipSource?
        if ext == "r3d" {
            // A thumbnail is 256 px: an eighth-res decode of an 8K frame is
            // still four times what it needs, and a folder of R3D clips would
            // otherwise be a full-res decode each.
            clip = try? R3DSource(url: url, scale: .eighth, applyCameraLUT: false)
        } else {
            clip = try? BRAWSource(url: url)
        }
        guard let clip, clip.frameCount > 0 else { return (nil, nil) }
        let image = clip.copyFrame(at: clip.frameCount / 2)
            .flatMap { thumbnail(from: $0, maxSize: 256) }
        let duration = clip.frameRate > 0
            ? Double(clip.frameCount) / clip.frameRate : nil
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

/// What one Other-content decode produces: the preview, plus the single fact the
/// panel shows beside the name. A clip answers with its length, a photo with its
/// pixel size — which is also how the two are told apart at a glance (see
/// `CaptureController.otherMetricText`).
///
/// At file scope rather than nested in `CaptureController`: everything that
/// builds one is `nonisolated` and runs off the main actor, and a type nested in
/// a `@MainActor` one is isolated to it.
struct OtherPreview {
    var image: NSImage?
    var duration: Double?
    var pixelSize: CGSize?
}
