import Foundation

/// What one offload run is asked to do: one source tree, N destinations, one
/// checksum algorithm.
///
/// N destinations rather than one is the whole point — a card is read ONCE and
/// written to every SSD in the same pass. Reading the card twice is both twice
/// as slow and twice the wear on the one copy of the footage that exists.
public struct OffloadPlan: Sendable {
    /// The card (or sound folder, or anything else) being copied.
    public var source: URL
    /// The folder each copy lands in, one per target volume. The engine writes
    /// the source tree, the MHL manifest and the summary into each of them.
    public var destinations: [URL]
    public var algorithm: OffloadHashAlgorithm
    /// Stamped into the MHL manifest's `creatorinfo`.
    public var creator: OffloadCreatorInfo
    /// Read/write chunk size. Configurable for the tests, which need the
    /// multi-chunk path without writing gigabytes.
    public var chunkBytes: Int
    /// Fault injection for the verify pass: called with each destination copy
    /// after it has been flushed to the device and before it is read back.
    ///
    /// The app never sets it. The suite does, because "a copy that landed
    /// corrupted is reported, renamed and kept out of the manifest" is the one
    /// behaviour the whole feature rests on and the one that cannot be provoked
    /// from outside — a real disk does not flip a bit on demand.
    public var didWriteCopy: (@Sendable (URL) -> Void)?

    public init(source: URL, destinations: [URL],
                algorithm: OffloadHashAlgorithm = .xxh64,
                creator: OffloadCreatorInfo = .current(),
                chunkBytes: Int = OffloadIO.defaultChunkBytes,
                didWriteCopy: (@Sendable (URL) -> Void)? = nil) {
        self.source = source
        self.destinations = destinations
        self.algorithm = algorithm
        self.creator = creator
        self.chunkBytes = max(4096, chunkBytes)
        self.didWriteCopy = didWriteCopy
    }
}

// MARK: - the small values a run is described in
//
// Four fields of an offload report were "files and bytes", four more were
// "started and finished", and two were "what went wrong". Spelled out one at a
// time they made initializers nobody can call without counting commas, and they
// let the two halves of a pair drift apart. Each pair is one value here, with
// whatever it derives on it.

/// How much there is of something: files and bytes together.
///
/// The two answer one question — how big is this card — and every place that
/// states one states the other.
public struct OffloadVolume: Sendable, Equatable {
    public var files: Int
    public var bytes: Int64

    public init(files: Int = 0, bytes: Int64 = 0) {
        self.files = files
        self.bytes = bytes
    }
}

/// When something started and when it stopped.
///
/// `elapsed` is derived rather than stored. A stored duration next to a start
/// and a finish is a third number that can disagree with the other two, and the
/// summary prints all three on adjacent lines where the disagreement is
/// obvious to the reader and to nobody else.
public struct OffloadSpan: Sendable, Equatable {
    public var started: Date
    public var finished: Date

    public init(started: Date, finished: Date) {
        self.started = started
        self.finished = finished
    }

    public var elapsed: TimeInterval { finished.timeIntervalSince(started) }
}

/// What a run could not do. The two lists together are the answer to "is this
/// card safe to wipe", so they travel together — a verdict that consulted one
/// of them and not the other is exactly the bug worth preventing.
public struct OffloadProblems: Sendable, Equatable {
    /// Entries the scan could not take: a directory the card would not let us
    /// walk, or something that is not a regular file (a symlink, a device node).
    public var scan: [String]
    /// Files the card would not give us cleanly — an unreadable file, or one
    /// whose length changed while it was being copied (a camera still writing).
    /// These are what make a card unsafe to wipe, so they are reported at run
    /// level and repeated in every destination's summary.
    public var source: [String]

    public init(scan: [String] = [], source: [String] = []) {
        self.scan = scan
        self.source = source
    }

    public var isEmpty: Bool { scan.isEmpty && source.isEmpty }
}

/// Everything about a run that is the same for every destination: what was
/// copied, with which checksum, by whom, when, how much of it, and what the
/// card would not give up.
///
/// One value because it is exactly what a summary needs. The engine used to
/// copy these eight fields one at a time out of the report and into a second
/// struct holding the same thing, which is two places to forget a field.
public struct OffloadRunFacts: Sendable, Equatable {
    /// The card (or sound folder) that was read.
    public var source: URL
    public var algorithm: OffloadHashAlgorithm
    public var creator: OffloadCreatorInfo
    public var span: OffloadSpan
    /// Everything the scan found on the card.
    public var card: OffloadVolume
    public var problems: OffloadProblems

    public init(source: URL, algorithm: OffloadHashAlgorithm,
                creator: OffloadCreatorInfo, span: OffloadSpan,
                card: OffloadVolume,
                problems: OffloadProblems = OffloadProblems()) {
        self.source = source
        self.algorithm = algorithm
        self.creator = creator
        self.span = span
        self.card = card
        self.problems = problems
    }
}

/// Who made the manifest — the `creatorinfo` block in ASC MHL, and the line in
/// the summary that says which build to blame.
public struct OffloadCreatorInfo: Sendable, Equatable {
    public var toolName: String
    public var toolVersion: String
    public var hostname: String

    public init(toolName: String, toolVersion: String, hostname: String) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.hostname = hostname
    }

    /// `version` comes from the app bundle; CaptureCore has no bundle of its
    /// own and must not guess at one.
    public static func current(toolName: String = "TakeShot",
                               version: String = "dev") -> OffloadCreatorInfo {
        OffloadCreatorInfo(toolName: toolName, toolVersion: version,
                           hostname: ProcessInfo.processInfo.hostName)
    }
}

/// One file on the card: where it is, where it goes, how big it is.
public struct OffloadSourceFile: Sendable, Equatable {
    public let url: URL
    /// Path relative to the source root — the layout of the card, preserved.
    public let relativePath: String
    public let size: Int64

    public init(url: URL, relativePath: String, size: Int64) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
    }
}

/// One verified file, as it goes into the manifest.
public struct OffloadEntry: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let hash: String

    public init(relativePath: String, size: Int64, hash: String) {
        self.relativePath = relativePath
        self.size = size
        self.hash = hash
    }
}

/// Cancel flag shared between the UI and the worker.
///
/// A class with a lock rather than `Task.isCancelled`: the engine is a
/// synchronous run on a utility queue (the copy loop is blocking file I/O, not
/// suspension points), and the operator hitting Cancel arrives from the main
/// thread mid-file.
public final class OffloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { flag }
    }

    public func cancel() {
        lock.withLock { flag = true }
    }
}

/// Live state of one destination, for the sheet's progress rows.
public struct OffloadDestinationProgress: Sendable, Identifiable, Equatable {
    public let id: Int
    public let url: URL
    public var filesDone: Int
    public var bytesWritten: Int64
    public var mismatches: Int
    /// Set once this destination has fallen over; it stops receiving files and
    /// the others carry on.
    public var failure: String?
    public var megabytesPerSecond: Double

    public init(id: Int, url: URL, filesDone: Int, bytesWritten: Int64,
                mismatches: Int, failure: String?, megabytesPerSecond: Double) {
        self.id = id
        self.url = url
        self.filesDone = filesDone
        self.bytesWritten = bytesWritten
        self.mismatches = mismatches
        self.failure = failure
        self.megabytesPerSecond = megabytesPerSecond
    }
}

/// Progress of a run, published as a whole so the sheet never renders a mix of
/// two moments.
public struct OffloadProgress: Sendable, Equatable {
    public var filesTotal: Int
    public var bytesTotal: Int64
    /// Relative path of the file being copied right now.
    public var currentFile: String
    public var destinations: [OffloadDestinationProgress]
    public var elapsed: TimeInterval
    public var isCancelling: Bool

    public init(filesTotal: Int, bytesTotal: Int64, currentFile: String,
                destinations: [OffloadDestinationProgress],
                elapsed: TimeInterval, isCancelling: Bool) {
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
        self.destinations = destinations
        self.elapsed = elapsed
        self.isCancelling = isCancelling
    }
}

/// How one destination ended up.
public enum OffloadOutcome: Sendable, Equatable {
    /// Every file on the card is on this disk and was re-read and matched.
    case verified
    /// Copied, but at least one file did not match on re-read, or could not be
    /// read off the card at all.
    case mismatched
    /// The destination itself fell over (full, unplugged, read-only).
    case failed
    /// The operator stopped the run; what did land is verified.
    case cancelled
}

/// What one destination ended up with.
///
/// The four numbers are one value because they are read as one: the rate comes
/// from two of them, the verdict from the other two, and "126 verified" without
/// the total it is out of says nothing at all.
public struct OffloadDestinationTotals: Sendable, Equatable {
    /// Files re-read from this disk and matched.
    public var filesVerified: Int
    /// Files on the card. Anything less than this verified is a problem, and
    /// saying so needs both numbers in the same place.
    public var filesTotal: Int
    public var bytesWritten: Int64
    /// This destination's own clock, which stops when the destination does —
    /// a disk that died in the first minute of an hour-long run would otherwise
    /// report a rate of 0.4 MB/s and nobody can read that number.
    public var elapsed: TimeInterval

    public init(filesVerified: Int = 0, filesTotal: Int = 0,
                bytesWritten: Int64 = 0, elapsed: TimeInterval = 0) {
        self.filesVerified = filesVerified
        self.filesTotal = filesTotal
        self.bytesWritten = bytesWritten
        self.elapsed = elapsed
    }

    public var megabytesPerSecond: Double {
        OffloadMetrics.megabytesPerSecond(bytes: bytesWritten, seconds: elapsed)
    }
}

/// The result for one destination — also everything its summary .txt says.
public struct OffloadDestinationResult: Sendable, Identifiable, Equatable {
    public let id: Int
    public let url: URL
    public var totals: OffloadDestinationTotals
    /// Files that did not match on re-read, with the reason.
    public var mismatches: [String]
    /// Why this destination stopped, if it did.
    public var failure: String?
    public var wasCancelled: Bool

    // The three report files, filled in afterwards rather than passed in. They
    // cannot be initializer parameters: the engine writes the manifest, folds
    // whether that succeeded into the result, and only then writes the summary
    // FROM that result — so none of the URLs exists at the moment the result is
    // built. (`Take` keeps its review state out of its initializer for the same
    // reason: none of it is known when the value is made.)
    public var manifestURL: URL?
    public var summaryURL: URL?
    /// The summary as a picture (see `OffloadReportCard`) — the copy of the
    /// report that gets handed over.
    public var imageURL: URL?

    public init(id: Int, url: URL, totals: OffloadDestinationTotals,
                mismatches: [String] = [], failure: String? = nil,
                wasCancelled: Bool = false) {
        self.id = id
        self.url = url
        self.totals = totals
        self.mismatches = mismatches
        self.failure = failure
        self.wasCancelled = wasCancelled
    }

    public var outcome: OffloadOutcome {
        if failure != nil { return .failed }
        if !mismatches.isEmpty { return .mismatched }
        if wasCancelled { return .cancelled }
        return totals.filesVerified == totals.filesTotal ? .verified : .mismatched
    }
}

/// The run as a whole.
public struct OffloadReport: Sendable {
    /// What the run was and what it found — the facts every destination's
    /// summary states, and the ones the summary writer is handed.
    public let run: OffloadRunFacts
    /// Files the run reached before it ended (cancel stops between files).
    public let filesProcessed: Int
    public let wasCancelled: Bool
    public let destinations: [OffloadDestinationResult]

    public init(run: OffloadRunFacts, filesProcessed: Int, wasCancelled: Bool,
                destinations: [OffloadDestinationResult]) {
        self.run = run
        self.filesProcessed = filesProcessed
        self.wasCancelled = wasCancelled
        self.destinations = destinations
    }

    /// Nothing to explain to the operator: every destination has every file.
    public var isFullyVerified: Bool {
        !destinations.isEmpty && run.problems.isEmpty
            && destinations.allSatisfy { $0.outcome == .verified }
    }

    public var failedDestinations: [OffloadDestinationResult] {
        destinations.filter { $0.outcome == .failed }
    }
}

/// Shared arithmetic for the rate shown in the UI and written into the summary —
/// one definition so the two can never disagree.
public enum OffloadMetrics {
    /// MB/s in the sense a DIT means it: decimal megabytes, as every offload
    /// tool and drive spec sheet quotes.
    public static func megabytesPerSecond(bytes: Int64, seconds: TimeInterval)
        -> Double {
        guard seconds > 0.001, bytes > 0 else { return 0 }
        return Double(bytes) / 1_000_000 / seconds
    }
}
