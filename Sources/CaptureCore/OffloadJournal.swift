import Foundation

/// What a destination has verified SO FAR, written while the run is still
/// going.
///
/// **The manifest is written at the END, and that is exactly the case resume
/// could not cover.** `OffloadResume` recognises an interrupted run by reading
/// the newest ASC MHL generation and the stamp beside it — both of which
/// `finalize` writes after the last file. A run that ends the way runs actually
/// end on set — the disk pulled, the cable kicked, the machine asleep — never
/// reaches `finalize`, so there is nothing to recognise: the next run says "no
/// previous offload in this folder" and copies a card that is already ninety
/// per cent there. On a 2 TB card that is an hour of a wrap nobody has.
///
/// So the run leaves a running note. It is OURS and not an MHL: a half-written
/// manifest would be a standardized document making a claim about a copy that
/// is not finished, read by `ascmhl`, Silverstack and OffShoot as if it were,
/// and the whole reason the stamp is a separate file is that the manifest is
/// not ours to put private things in. This lives beside the stamp, in `ascmhl/`
/// — which is already exempt from the verify pass's stray-file list — and is
/// removed the moment a real manifest exists.
///
/// **It is safe for exactly the reason the manifest is.** It carries the card's
/// identity, so the same four gates apply: another card's journal is refused,
/// and a card that has been shot on since is refused. And nothing in it is
/// TRUSTED: every claim is re-read off the destination disk and re-hashed
/// before a file is skipped (`OffloadTarget.reuse`). A journal that lied would
/// cost the run nothing but the hashing it would have done anyway.
public struct OffloadJournal: Codable, Sendable, Equatable {
    /// The card this progress was made from.
    public var card: OffloadCardIdentity
    /// Which checksums the entries carry — a run with a different algorithm
    /// cannot compare against them, exactly as with a manifest.
    public var algorithm: OffloadHashAlgorithm
    /// Everything verified onto this destination so far.
    public var entries: [OffloadEntry]

    public init(card: OffloadCardIdentity, algorithm: OffloadHashAlgorithm,
                entries: [OffloadEntry]) {
        self.card = card
        self.algorithm = algorithm
        self.entries = entries
    }
}

/// Reading and writing the note above.
public enum OffloadProgressJournal {
    /// Beside the stamp, under the manifest folder.
    public static let fileName = "takeshot-progress.json"

    /// **How much work an interruption may cost, in the unit it is felt in.**
    ///
    /// Ten seconds, checked at file boundaries — which is the only place there
    /// is anything to record, since a partly copied file has not been verified
    /// and is not an entry. A card of small files checkpoints every ten
    /// seconds of them; a card of 8 GB clips checkpoints after each one,
    /// because each one takes longer than that.
    ///
    /// Stated as time rather than as a file count because the file count is
    /// not what an operator loses: twenty-five files is four seconds of a
    /// DSLR card and twenty minutes of a RED card, and the second one is the
    /// case this exists for.
    ///
    /// The FIRST checkpoint is not subject to it — see
    /// `OffloadTarget.lastCheckpoint`.
    public static let checkpointSeconds: TimeInterval = 10

    public static func url(in destination: URL) -> URL {
        destination
            .appendingPathComponent(OffloadMHL.folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Atomic, so a journal that is being written while the disk goes is
    /// either the old one or the new one and never half of either.
    @discardableResult
    public static func write(_ journal: OffloadJournal,
                             into destination: URL) throws -> URL {
        let folder = destination.appendingPathComponent(OffloadMHL.folderName,
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let target = url(in: destination)
        let encoder = JSONEncoder()
        try encoder.encode(journal).write(to: target, options: .atomic)
        return target
    }

    /// The journal in a destination, or nil when there is none or it will not
    /// parse. Unparsable is the same answer as absent on purpose: a journal is
    /// a shortcut and never evidence, so the only cost of ignoring one is the
    /// copying a build without this feature would have done anyway.
    public static func read(in destination: URL) -> OffloadJournal? {
        guard let data = try? Data(contentsOf: url(in: destination))
        else { return nil }
        return try? JSONDecoder().decode(OffloadJournal.self, from: data)
    }

    /// Taken away once a real manifest states the same thing.
    ///
    /// Not `try` — a journal left behind is harmless: the next run's survey
    /// unions it with the manifest and every entry in it is in the manifest
    /// too. Failing an otherwise-verified destination over a leftover
    /// scratch file would be the worse lie.
    public static func remove(in destination: URL) {
        try? FileManager.default.removeItem(at: url(in: destination))
    }
}
