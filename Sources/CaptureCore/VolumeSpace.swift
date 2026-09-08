import Foundation

/// **How much room a volume has, asked one way by everything that asks.**
///
/// There were three readers with three different key sets, and the disagreement
/// was visible on set: the offload's destination tile read
/// `volumeAvailableCapacityForImportantUsage` alone, so a 4 TB shuttle with
/// 1.5 TB on it could be reported wrongly (owner: "оффлоадер карт неверно
/// определяет свободное пространство на целевом диске"), while the preflight
/// beside it had already learned to fall back and the record folder's disk
/// alarm had not.
///
/// One place now. A number that decides whether footage gets copied is not a
/// question two parts of the app may answer differently.
public enum VolumeSpace {
    /// Free bytes on the volume holding `url`, or nil — **"no number", not
    /// "no room"**.
    public static func free(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }
        return believe(important: values.volumeAvailableCapacityForImportantUsage,
                       plain: values.volumeAvailableCapacity)
    }

    /// The volume's size and what is left on it — what a tile shows. nil for a
    /// path that is not there, which is the normal state of a destination the
    /// operator saved last week and has not plugged in yet.
    public static func capacity(of url: URL) -> (total: Int64, free: Int64)? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = believe(
                important: values.volumeAvailableCapacityForImportantUsage,
                plain: values.volumeAvailableCapacity)
        else { return nil }
        return (Int64(total), free)
    }

    /// **Which of the volume's two free-space answers to believe.**
    ///
    /// A zero is treated as no number, and that is the whole point.
    /// `volumeAvailableCapacityForImportantUsage` is the key written for the
    /// BOOT volume: it counts space the system could purge, and a volume that
    /// cannot account for that can answer 0 with terabytes on it. It did, on a
    /// 4 TB shuttle with 1.5 TB free, and the offload preflight refused a copy
    /// that would have completed — "not enough space: needs 31.5 GB, 0 bytes
    /// free" (owner, 2026-09-08). `volumeAvailableCapacity` is the plain
    /// number and is what an external drive can always answer.
    ///
    /// Separate from the read so the rule can be asserted without a disk that
    /// misreports — the case it exists for cannot be produced on demand.
    public static func believe(important: Int64?, plain: Int?) -> Int64? {
        if let important, important > 0 { return important }
        guard let plain, plain > 0 else { return nil }
        return Int64(plain)
    }
}
