import CaptureCore
import Foundation

/// The in/out range belongs to the CLIP, not to the transport.
///
/// There is ONE `TransportModel` for the whole app, so without this table a
/// range survived `replaceCurrentItem` untouched and landed on the next clip at
/// the same seconds offset — mark a beat 12 s into a 40 s take, load the next
/// take, and it was already looping over 12 s of somebody else's action.
///
/// Split out of `TransportModel`: driving the player and keeping the day's
/// ranges are separate jobs, and everything here is also the read/write side of
/// the `takeshot-ranges.csv` sidecar.
extension TransportModel {
    static func key(_ url: URL) -> String { url.lastPathComponent }

    /// In/out as they stand for the clip in the player.
    var currentRange: ClipRange {
        ClipRange(inPoint: inPoint, outPoint: outPoint)
    }

    /// The whole table, for the sidecar writer: what is on file, plus the range of
    /// the clip in the player, which is only filed when it is closed.
    var storedRanges: [String: ClipRange] {
        guard let loadedClip else { return rangesByFile }
        var all = rangesByFile
        all[Self.key(loadedClip)] = currentRange
        return all
    }

    /// Point the transport at `url`: file the outgoing clip's range and adopt
    /// this clip's (nothing on file = no range).
    ///
    /// `driving` is false for content this transport does not run: a RAW clip
    /// has its own engine and its own in/out, a still has no transport at all.
    /// The outgoing range is still filed, but nothing is adopted — otherwise
    /// this model's empty range would be written over the RAW engine's.
    func loadClip(_ url: URL?, driving: Bool = true) {
        if let loadedClip { file(currentRange, for: loadedClip) }
        guard let url, driving else {
            loadedClip = nil
            inPoint = nil
            outPoint = nil
            return
        }
        loadedClip = url
        let restored = rangesByFile[Self.key(url)] ?? .unset
        inPoint = restored.inPoint
        outPoint = restored.outPoint
    }

    /// The range on file for a clip this transport is not driving — how the RAW
    /// engine, rebuilt from scratch for every clip, gets its in/out back.
    func storedRange(for url: URL) -> ClipRange {
        rangesByFile[Self.key(url)] ?? .unset
    }

    func storeRange(_ range: ClipRange, for url: URL) {
        file(range, for: url)
    }

    /// Record a range against a clip, and say so only if it actually changed.
    /// Unchanged transitions have to stay silent: reviewing thirty clips without
    /// touching a mark must not rewrite the sidecar thirty times.
    func file(_ range: ClipRange, for url: URL) {
        let key = Self.key(url)
        guard (rangesByFile[key] ?? .unset) != range else { return }
        rangesByFile[key] = range
        onRangesChanged?()
    }

    /// Ranges read back from the sidecar, for the clips a folder scan just found.
    ///
    /// Restricted to what the scan found so that a row for a clip that has been
    /// trashed cannot come back from a sidecar written before it went. Entries the
    /// session already knows are left alone — a scan runs every minute and on
    /// every folder event, and it must not undo a mark the operator just made.
    /// Silent by design: this is the read side, and notifying would write the file
    /// straight back.
    func restoreRanges(_ stored: [String: ClipRange],
                       forFilesNamed names: Set<String>) {
        for (name, range) in stored
        where names.contains(name) && rangesByFile[name] == nil {
            rangesByFile[name] = range
        }
        // the clip in the player was loaded before its range was on file
        if let loadedClip, currentRange.isEmpty {
            let restored = rangesByFile[Self.key(loadedClip)] ?? .unset
            inPoint = restored.inPoint
            outPoint = restored.outPoint
        }
    }

    /// A clip that was deleted takes its range with it — out of the table and out
    /// of the sidecar.
    func forgetClip(_ url: URL) {
        if rangesByFile.removeValue(forKey: Self.key(url)) != nil {
            onRangesChanged?()
        }
        guard loadedClip == url else { return }
        loadedClip = nil
        inPoint = nil
        outPoint = nil
    }

    /// A new record folder is a different set of clips.
    ///
    /// Deliberately silent, and this one matters: the destination has ALREADY
    /// changed by the time this runs (it is called from the settings observer), so
    /// notifying here would write an empty sidecar into the folder we are about to
    /// read one from — erasing the marks of whoever shot there this morning. The
    /// new folder's sidecar arrives through `restoreRanges` on the scan that
    /// follows.
    func forgetAllClips() {
        rangesByFile.removeAll()
        loadedClip = nil
        inPoint = nil
        outPoint = nil
    }
}
