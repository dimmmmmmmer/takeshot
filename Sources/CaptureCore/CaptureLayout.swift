import Foundation

/// **Where a record folder keeps its takes.**
///
/// Two layouts, and which one a folder is in is a fact about the FOLDER rather
/// than a setting:
///
/// - **Flat** — takes at the root, beside whatever else the day put there.
///   Every folder this app has ever recorded into is in this layout.
/// - **Split** — takes in `Takes/`, and the root is therefore exactly "the
///   other content" (owner: "чтоб у нас короче было сразу по дефолту
///   разделение папки на другой контент и тейки"). It is what makes the two
///   panels' folder buttons mean two different places.
///
/// **A folder that already holds anything keeps the flat layout**, and that is
/// the whole of the migration story: nothing moves, and no take that exists
/// today is reclassified as foreign tomorrow. The owner chose this variant
/// over a blanket switch for exactly that reason.
///
/// The disk answers the question, so there is no setting to get out of step
/// with it and no per-folder map to keep: `Takes/` existing IS the split
/// layout, and an empty folder becomes one the first time a take is written.
///
/// It reverses a decision this file used to state — "write STRAIGHT into the
/// chosen folder — no auto subfolders: the DIT picks the card/roll folder
/// themselves; app nesting surprises them." The reasoning holds and is why the
/// nesting is one level, named in the operator's own words, and never applied
/// to a folder they have already used.
public enum CaptureLayout {
    /// The subfolder a split-layout folder keeps its takes in.
    public static let takesFolderName = "Takes"

    /// Files whose presence means this app has recorded here before.
    ///
    /// Its own list rather than "any file": a folder holding only a
    /// `.DS_Store` is an empty folder, and starting a shoot in the flat layout
    /// because Finder had been there would be the surprise this rule exists to
    /// avoid.
    static let ourSidecars: Set<String> = [
        TakeLogExporter.fileName,
        TakeLogExporter.slateFileName,
        TakeLogExporter.markersFileName,
    ]

    /// Where takes are written and read for `root`.
    ///
    /// `isDirectory: true` is not decoration: the one-argument
    /// `appendingPathComponent` CONSULTS THE FILESYSTEM to decide whether to
    /// add a trailing slash, so the same expression answers differently before
    /// and after the folder exists — and two URLs for one place is a
    /// comparison that fails for no visible reason. (The dailies folder list
    /// was bitten by the same thing from the other side.)
    public static func takesFolder(in root: URL) -> URL {
        isSplit(root)
            ? root.appendingPathComponent(takesFolderName, isDirectory: true)
            : root
    }

    /// Whether `root` is in the split layout.
    ///
    /// The three questions in order:
    /// 1. `Takes/` is there — it is split, whatever else is around.
    /// 2. This app has recorded here (a sidecar), or there is footage at the
    ///    root — an established day, left exactly as it is.
    /// 3. Neither — a fresh folder, so it starts split.
    public static func isSplit(_ root: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let takes = root.appendingPathComponent(takesFolderName).path
        if manager.fileExists(atPath: takes, isDirectory: &isDirectory) {
            // **Something called Takes is already there.** A FOLDER settles
            // it. A FILE settles it the other way: this folder cannot be split
            // — `<root>/Takes/…` would be a path through a regular file and
            // every take of the day would fail to write. Flat is the layout
            // that still works.
            return isDirectory.boolValue
        }
        return !holdsAnythingAlready(root)
    }

    /// Whether the root already has a day in it: a sidecar this app wrote, or
    /// any video file at all.
    ///
    /// Video counts even though it may be somebody else's footage. The
    /// question this answers is "has a shoot started in this folder", and the
    /// safe answer for a folder with clips in it is yes — the cost of being
    /// wrong that way is a layout the operator did not get, and the cost of
    /// being wrong the other way is takes landing somewhere they do not expect
    /// on a folder they were already using.
    static func holdsAnythingAlready(_ root: URL) -> Bool {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path)
        else {
            // A folder that cannot be listed — not there yet, or not readable
            // — is not a folder with a day in it.
            return false
        }
        for name in names {
            if ourSidecars.contains(name) { return true }
            if DailiesSourceScan.transcodable
                .contains((name as NSString).pathExtension.lowercased()) {
                return true
            }
            if DailiesSourceScan.cameraRaw
                .contains((name as NSString).pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }
}
