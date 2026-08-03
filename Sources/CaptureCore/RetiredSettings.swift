import Foundation

/// Settings fields that no longer exist on `CaptureSettings`, decoded from the
/// same saved blob so a migration can still read them once.
///
/// `CaptureSettings`'s synthesized decoder silently drops keys it does not know,
/// which is exactly what makes removing a field safe — and exactly what makes a
/// removed field unreadable. A feature that is retired INTO something else (the
/// verified backup into the offload destinations) needs its last value one more
/// time, so it is decoded here instead: every property is Optional and the whole
/// decode is best-effort, because the blob it reads is by definition older than
/// this type.
struct RetiredSettings: Decodable {
    /// The verified-backup folder. The feature is gone — the DIT offload copies
    /// with a checksum, writes an ASC MHL manifest and can re-verify a disk
    /// months later, which is everything this did and more — but the folder the
    /// operator had chosen is still the disk they back up to.
    var backupPath: String?
    /// Which CORNER of the player the exposure legend sat in. The legend is a
    /// strip and now lives against an edge (`legendPlacement`), so the corner
    /// itself is gone — but "the operator had it at the top" is still worth
    /// carrying across (see `migrateToVersion3`).
    var legendCorner: String?

    init() {}

    /// Best-effort: anything unreadable leaves every field nil, which means the
    /// migrations that consume them do nothing.
    init(from data: Data) {
        self = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
}
