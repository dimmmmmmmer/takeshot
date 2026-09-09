import Foundation

/// **What a folder of footage offers a dailies run** (owner: "дейлики нужны из
/// исходников. хотелось бы выбирать папку из которой будут рендериться
/// дейлики, вероятно даже несколько источников, как в оффлоаде").
///
/// The queue used to be the app's own takes and nothing else. A folder of
/// camera originals is the other half of the job — and the honest answer for a
/// folder is not "every video file in it": this path reads through
/// `AVAssetReader`, which opens what AVFoundation opens. A camera RAW clip is
/// a different decode entirely (the app has one for playback — `CR3D` — and it
/// is not this), so a scan says plainly which files it can take and which it
/// is leaving, rather than queueing forty items that will each fail with a
/// message about a reader.
public enum DailiesSourceScan {
    /// Extensions this transcode can read.
    ///
    /// A subset of the library's video set on purpose: that set answers "clips
    /// this app can put on screen", and playback has decoders this does not.
    public static let transcodable: Set<String> = ["mov", "mp4", "m4v", "mxf"]

    /// Camera RAW — readable by the app, not by this path. Named so a scan can
    /// report them as SKIPPED with a reason instead of failing them one at a
    /// time during a run.
    public static let cameraRaw: Set<String> = ["r3d", "braw"]

    /// What one folder holds.
    public struct Findings: Sendable, Equatable {
        /// Files this run can transcode, in a stable order.
        public var files: [URL] = []
        /// Camera RAW found and left alone.
        public var skippedRaw: [URL] = []

        public var isEmpty: Bool { files.isEmpty && skippedRaw.isEmpty }

        public init(files: [URL] = [], skippedRaw: [URL] = []) {
            self.files = files
            self.skippedRaw = skippedRaw
        }
    }

    /// Walk `folder` for footage.
    ///
    /// Recursive, because a card is a tree (`DCIM/100MEDIA/…`) and so is a
    /// day's shuttle drive. Hidden files and package contents are skipped: a
    /// `.RDC` bundle is a directory full of pieces of one clip, and walking
    /// into it would queue the pieces.
    public static func scan(_ folder: URL) -> Findings {
        var findings = Findings()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return findings }
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            if transcodable.contains(ext) {
                findings.files.append(url)
            } else if cameraRaw.contains(ext) {
                findings.skippedRaw.append(url)
            }
        }
        // The walk's order is the filesystem's. A day is read in name order by
        // everyone who receives it, and a queue that runs in a different order
        // every time is a queue nobody can follow in the status line.
        findings.files.sort { $0.path < $1.path }
        findings.skippedRaw.sort { $0.path < $1.path }
        return findings
    }

    /// Every folder's findings, merged, with a file that appears twice counted
    /// once — two sources may overlap (a card and the shuttle it was copied
    /// to), and a daily written twice under one name is a `_2` nobody asked
    /// for.
    public static func scan(_ folders: [URL]) -> Findings {
        var merged = Findings()
        var seen: Set<String> = []
        for folder in folders {
            let found = scan(folder)
            for url in found.files where seen.insert(url.path).inserted {
                merged.files.append(url)
            }
            for url in found.skippedRaw where seen.insert(url.path).inserted {
                merged.skippedRaw.append(url)
            }
        }
        return merged
    }
}
