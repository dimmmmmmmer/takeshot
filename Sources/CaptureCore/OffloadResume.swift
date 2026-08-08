import Foundation

/// Which card a destination's newest manifest was made from.
///
/// The same recognition `OffloadedCardLedger` already does, deliberately not a
/// second one: the volume's UUID as the key — a card keeps it across remounts
/// and across readers — plus the file-count/byte fingerprint that notices a card
/// which has been shot on since. Two additions the ledger has no need of:
///
/// - the source's own PATH, because an offload source is not always a volume. A
///   sound roll is a folder on a working disk, and every folder on that disk
///   reports the same volume UUID — the path is what tells two of them apart. For
///   a card it adds nothing the mount name did not already carry.
/// - all of it has to match, not the strongest available part. A card that comes
///   back mounted under a different name is then refused and copied whole, which
///   is the safe direction to be wrong in.
///
/// **What it cannot distinguish, stated because resume acts on it.** The same
/// card, at the same mount, NOT reformatted (a format issues a new volume UUID),
/// erased and reshot to exactly the same number of files and exactly the same
/// total size — and then only for the files whose path and size also coincide,
/// since those are checked one by one. A clone of the card passes and should:
/// its bytes are the same bytes. Two numbers cannot tell one card's contents
/// from another's replaced by exactly as many bytes in exactly as many files, and
/// `CardFingerprint` says as much about itself; what makes it safe here is that
/// this is only the FIRST of four gates, and that the operator is shown what is
/// about to be skipped and has to agree to it.
public struct OffloadCardIdentity: Codable, Sendable, Equatable {
    /// The volume's UUID, or nil for a filesystem that carries none.
    public var volumeUUID: String?
    /// Where the source was — standardized and with symlinks resolved, so the
    /// same folder reached two ways is one identity.
    public var source: String
    /// Everything the scan found on it — the ledger's own fingerprint.
    public var files: Int
    public var bytes: Int64

    public init(volumeUUID: String?, source: String, files: Int, bytes: Int64) {
        self.volumeUUID = volumeUUID
        self.source = source
        self.files = files
        self.bytes = bytes
    }

    /// The identity of the card a run is reading right now.
    public static func of(source: URL, card: OffloadVolume)
        -> OffloadCardIdentity {
        OffloadCardIdentity(
            volumeUUID: volumeUUID(of: source),
            source: source.standardizedFileURL.resolvingSymlinksInPath().path,
            files: card.files, bytes: card.bytes)
    }

    static func volumeUUID(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    /// Is this the same source at all — never mind what is on it now?
    ///
    /// The two halves are asked separately because the answers mean different
    /// things to the operator: another card's copy is a refusal to explain, and
    /// the same card with more on it than when it was copied is a fact about the
    /// card. Both refuse; only one of them is surprising.
    func isSameSource(as other: OffloadCardIdentity) -> Bool {
        volumeUUID == other.volumeUUID && source == other.source
    }
}

/// The note an offload leaves beside its manifest saying which card that
/// manifest generation was made from.
///
/// Its own small file rather than an element inside the manifest: the manifest
/// is a standardized ASC MHL document that `ascmhl`, Silverstack and OffShoot
/// parse, and a private element in it is a change to a file other people's
/// tools read. It lives in `ascmhl/` because everything in that folder is
/// already exempt from the verify pass's stray list (`OffloadVerify.isReportFile`),
/// so it cannot be reported as footage nobody accounted for.
///
/// It names the manifest it belongs to. Without that the pairing could drift —
/// a run whose manifest failed to write but whose stamp landed would leave a
/// stamp claiming the generation before it.
public struct OffloadSourceStamp: Codable, Sendable, Equatable {
    /// File name of the manifest generation this stamp describes.
    public var manifest: String
    public var card: OffloadCardIdentity

    public init(manifest: String, card: OffloadCardIdentity) {
        self.manifest = manifest
        self.card = card
    }
}

/// Why a destination cannot be resumed — as opposed to being resumed and
/// finding nothing reusable, which is a count rather than a refusal.
///
/// English, like the rest of CaptureCore: these reach the summary .txt on the
/// disk. The app maps each to its own localized sentence, the way it already
/// does for `OffloadVerifyError` — every one of these is something the operator
/// can act on, and "everything will be copied" without the reason is the answer
/// that gets an app distrusted.
public enum OffloadResumeRefusal: Sendable, Equatable {
    /// Nothing has ever been offloaded into this folder.
    case noManifest
    /// There is a manifest and no stamp of ours beside it — a folder written by
    /// another tool, or by a build from before resume existed. A manifest whose
    /// card cannot be established is a manifest from an unknown card.
    case noStamp
    /// The stamp names a different card. This is the one that must never be got
    /// wrong: skipping a file on the strength of another card's manifest is how
    /// footage goes missing.
    case differentCard
    /// The same card, and not what it held when it was copied here — it has been
    /// shot on, or something has been deleted off it. Its own case because it is
    /// the one an operator can immediately make sense of, and because the answer
    /// is different: the card is fine, this copy is simply of an older state of it.
    case cardChanged
    /// The manifest's checksums are of a different kind from this run's, so its
    /// digests and ours are not comparable.
    case differentHash(OffloadHashAlgorithm)
    /// There is a manifest and it will not parse.
    case unreadable(String)

    public var reason: String {
        switch self {
        case .noManifest:
            return "no previous offload in this folder"
        case .noStamp:
            return "the manifest here does not say which card it was made from"
        case .differentCard:
            return "the copy here was made from a different card"
        case .cardChanged:
            return "the card has changed since it was copied here"
        case .differentHash(let found):
            return "the manifest here uses \(found.displayName) checksums"
        case .unreadable(let reason):
            return "the manifest here could not be read: \(reason)"
        }
    }
}

/// What one destination already holds from an earlier run of the same card.
///
/// A CLAIM and not a verdict. Everything in it comes from parsing one manifest
/// and comparing paths and sizes against the card's scan — no file is read, so
/// the operator can be shown the number before deciding. The run then proves
/// every claim by re-hashing the copy off the disk, and anything that fails is
/// copied again.
public struct OffloadResumeOffer: Sendable, Equatable, Identifiable {
    /// The copy's own root — the folder the card's tree lives in.
    public let destination: URL
    public let manifest: URL?
    /// Entries of the previous manifest whose path the card still has at
    /// exactly that size, keyed by the card's own relative path.
    public let claimed: [OffloadEntry]
    public let refusal: OffloadResumeRefusal?

    public var id: String { destination.path }
    public var files: Int { claimed.count }
    public var bytes: Int64 { claimed.reduce(0) { $0 + $1.size } }
    /// Worth offering: something here can be reused, and nothing refuses it.
    public var isUsable: Bool { refusal == nil && !claimed.isEmpty }

    public init(destination: URL, manifest: URL?, claimed: [OffloadEntry],
                refusal: OffloadResumeRefusal?) {
        self.destination = destination
        self.manifest = manifest
        self.claimed = claimed
        self.refusal = refusal
    }
}

/// What every destination of a planned run already holds, with the card it was
/// measured against.
public struct OffloadResumeReview: Sendable, Equatable {
    /// Everything the card holds — the total the offers are counted against.
    public let card: OffloadVolume
    public let offers: [OffloadResumeOffer]

    public init(card: OffloadVolume, offers: [OffloadResumeOffer]) {
        self.card = card
        self.offers = offers
    }

    /// At least one destination has work worth reusing, so there is a question
    /// to ask the operator.
    public var isUsable: Bool { offers.contains(where: \.isUsable) }
    /// Files that would be reused on the destination that holds the most.
    public var bestCase: Int { offers.filter(\.isUsable).map(\.files).max() ?? 0 }
}

/// Resuming an offload that an unplugged disk cut short.
///
/// **The problem.** A destination that dies is taken out of the run and the
/// survivors finish (`OffloadTarget.fail`), so a lost disk never costs the
/// others anything. What it used to cost was the SECOND run: nothing knew that
/// 400 of the card's 900 files were already on the recovered disk, so the
/// operator paid for a full re-read of the card and a full re-write of the disk
/// to redo work that was done.
///
/// **What a done file is, and it is not the size.** A file counts as already
/// here only when the copy on the disk RE-HASHES to what the destination's own
/// manifest says. Size alone lets a truncated file through, and this codebase
/// already knows that hazard — it flags a file whose length changed mid-copy and
/// refuses to call the card safe to wipe. So the four gates are:
///
/// 1. the destination's newest ASC MHL manifest is attested — by the stamp
///    beside it — to THIS card (`OffloadCardIdentity`);
/// 2. that manifest lists the file, at the path the card would put it;
/// 3. the card's own size for it matches the manifest's;
/// 4. the copy on the disk, re-read with the cache bypassed, hashes to the
///    manifest's digest.
///
/// Only 4 can say a file is done. 1 to 3 are what make it worth reading the
/// disk to ask.
///
/// **What it costs, stated honestly.** Resume trades a read of the DESTINATION
/// for a read of the card plus a write of the destination. On a fast card and a
/// slow disk that is not always a win, which is why the operator is shown the
/// numbers and decides — see `OffloadResumeReview`.
public enum OffloadResume {
    /// The stamp's file name inside `ascmhl/`.
    public static let stampName = "takeshot-source.json"

    /// Record which card this manifest generation came from.
    ///
    /// Written by EVERY run, not only resumed ones: the first run is the one
    /// whose stamp the second one reads. Best-effort at the call site — a run
    /// that could not write it simply cannot be resumed later, which is the
    /// safe direction to fail in.
    @discardableResult
    public static func stamp(_ identity: OffloadCardIdentity, manifest: URL,
                             into destination: URL) throws -> URL {
        let folder = destination.appendingPathComponent(OffloadMHL.folderName,
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(stampName)
        let stamp = OffloadSourceStamp(manifest: manifest.lastPathComponent,
                                       card: identity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(stamp).write(to: url, options: .atomic)
        return url
    }

    /// The stamp beside a destination's manifests, if there is one.
    public static func readStamp(in destination: URL) -> OffloadSourceStamp? {
        let url = destination
            .appendingPathComponent(OffloadMHL.folderName, isDirectory: true)
            .appendingPathComponent(stampName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OffloadSourceStamp.self, from: data)
    }

    /// What one destination claims to hold of this card. Cheap: one manifest
    /// parse, no file contents read.
    public static func survey(card: [OffloadSourceFile],
                              identity: OffloadCardIdentity,
                              destination: URL,
                              algorithm: OffloadHashAlgorithm)
        -> OffloadResumeOffer {
        guard let url = OffloadManifestReader.latest(in: destination) else {
            return refuse(destination, nil, .noManifest)
        }
        guard let stamp = readStamp(in: destination),
              stamp.manifest == url.lastPathComponent else {
            return refuse(destination, url, .noStamp)
        }
        guard stamp.card.isSameSource(as: identity) else {
            return refuse(destination, url, .differentCard)
        }
        guard stamp.card == identity else {
            return refuse(destination, url, .cardChanged)
        }
        let manifest: OffloadManifest
        do {
            manifest = try OffloadManifestReader.read(url)
        } catch {
            return refuse(destination, url,
                          .unreadable(error.localizedDescription))
        }
        guard manifest.algorithm == algorithm else {
            return refuse(destination, url, .differentHash(manifest.algorithm))
        }
        // Entries the card no longer has at that size are NOT claimed, so they
        // are copied fresh rather than trusted. Nothing is lost by leaving them
        // out of this run's manifest either: ASC MHL keeps every generation, and
        // the one that listed them is still on the disk.
        var sizes: [String: Int64] = [:]
        for file in card { sizes[file.relativePath] = file.size }
        let claimed = manifest.entries
            .filter { sizes[$0.relativePath] == $0.size }
        return OffloadResumeOffer(destination: destination, manifest: url,
                                  claimed: claimed, refusal: nil)
    }

    /// The whole question, for the sheet: scan the card once and ask every
    /// destination what it already has.
    ///
    /// The card scan is the same one the run itself does. It happens here too
    /// rather than being passed in because the operator is answering about the
    /// card as it is NOW — a card swapped between the question and the answer
    /// would otherwise be surveyed as the one that was there before.
    public static func review(source: URL, destinations: [URL],
                              algorithm: OffloadHashAlgorithm)
        -> OffloadResumeReview {
        let scan = OffloadEngine.scan(source)
        let card = OffloadVolume(files: scan.files.count,
                                 bytes: scan.files.reduce(0) { $0 + $1.size })
        let identity = OffloadCardIdentity.of(source: source, card: card)
        return OffloadResumeReview(
            card: card,
            offers: destinations.map {
                survey(card: scan.files, identity: identity, destination: $0,
                       algorithm: algorithm)
            })
    }

    private static func refuse(_ destination: URL, _ manifest: URL?,
                               _ refusal: OffloadResumeRefusal)
        -> OffloadResumeOffer {
        OffloadResumeOffer(destination: destination, manifest: manifest,
                           claimed: [], refusal: refusal)
    }
}

/// What resuming actually did to one destination — the part of its report that
/// only exists because the run was asked to resume.
///
/// nil on a result means the question was never asked, which is what keeps an
/// ordinary run's summary byte-identical to what it always was.
public struct OffloadResumeFacts: Sendable, Equatable {
    /// Files the previous manifest claimed and the card still has at that size.
    public var claimed: Int
    /// …of those, the ones that re-hashed to the manifest and were skipped:
    /// neither read from the card nor written to the disk.
    public var reused: Int
    public var reusedBytes: Int64
    /// Copies that were already sitting where this run had to write, and were
    /// replaced from the card rather than trusted — a file that failed the hash
    /// gate, or debris from the write the disk died in the middle of.
    public var replaced: [String]
    /// Why nothing here could be resumed, when nothing could.
    public var refusal: String?

    public init(claimed: Int = 0, reused: Int = 0, reusedBytes: Int64 = 0,
                replaced: [String] = [], refusal: String? = nil) {
        self.claimed = claimed
        self.reused = reused
        self.reusedBytes = reusedBytes
        self.replaced = replaced
        self.refusal = refusal
    }
}
