import AVFoundation
import AppKit
import CaptureCore
import Foundation

/// **One frame per take, decoded from the recorded file.**
///
/// The shift report's PDF puts a poster beside each take, and it decodes them
/// HERE rather than reading the takes panel's thumbnail cache: the cache holds
/// only what the grid scrolled past, so a document whose pictures depend on
/// scroll history is a document that is wrong in a way nobody can see.
///
/// It lived on `ContactSheet` until that document was retired (owner, twice:
/// "смысла contact sheet так и не увидел когда есть shift report"), and it is
/// the one thing of that file's that had a second caller — so it moved here
/// rather than going with it.
enum TakePosters {
    /// A poster frame per take, decoded from the recorded file for THIS
    /// export. Deliberately not the panel's `thumbnails` cache: the cache
    /// only holds what the grid happened to scroll past (and evicts past 120
    /// entries), and a sheet whose cells go blank depending on scroll history
    /// is wrong. Same frame source as the panel: the file itself — the
    /// preview LUT is never baked into a reference document (CLAUDE.md,
    /// "stills are deliverables"). A take whose file is missing or does not
    /// decode simply has no entry here; the drawing falls back to the
    /// film-strip placeholder rather than throwing or hanging.
    @MainActor
    static func exportThumbnails(for takes: [Take]) async -> [UUID: NSImage] {
        var posters: [UUID: NSImage] = [:]
        for take in takes {
            guard FileManager.default.fileExists(atPath: take.url.path)
            else { continue }
            let generator = AVAssetImageGenerator(
                asset: AVURLAsset(url: take.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            let time = CMTime(seconds: min(1.0, take.durationSeconds / 2),
                              preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time)
            else { continue }
            posters[take.id] = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return posters
    }
}
