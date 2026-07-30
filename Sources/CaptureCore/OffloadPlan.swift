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

/// The result for one destination — also everything its summary .txt says.
public struct OffloadDestinationResult: Sendable, Identifiable, Equatable {
    public let id: Int
    public let url: URL
    /// Files re-read from this disk and matched.
    public var filesVerified: Int
    /// Files on the card. Anything less than this verified is a problem, and
    /// saying so needs both numbers in the same place.
    public var filesTotal: Int
    public var bytesWritten: Int64
    /// Files that did not match on re-read, with the reason.
    public var mismatches: [String]
    /// Why this destination stopped, if it did.
    public var failure: String?
    public var manifestURL: URL?
    public var summaryURL: URL?
    public var elapsed: TimeInterval
    public var wasCancelled: Bool

    public init(id: Int, url: URL, filesVerified: Int, filesTotal: Int,
                bytesWritten: Int64, mismatches: [String], failure: String?,
                manifestURL: URL?, summaryURL: URL?, elapsed: TimeInterval,
                wasCancelled: Bool) {
        self.id = id
        self.url = url
        self.filesVerified = filesVerified
        self.filesTotal = filesTotal
        self.bytesWritten = bytesWritten
        self.mismatches = mismatches
        self.failure = failure
        self.manifestURL = manifestURL
        self.summaryURL = summaryURL
        self.elapsed = elapsed
        self.wasCancelled = wasCancelled
    }

    public var megabytesPerSecond: Double {
        OffloadMetrics.megabytesPerSecond(bytes: bytesWritten, seconds: elapsed)
    }

    public var outcome: OffloadOutcome {
        if failure != nil { return .failed }
        if !mismatches.isEmpty { return .mismatched }
        if wasCancelled { return .cancelled }
        return filesVerified == filesTotal ? .verified : .mismatched
    }
}

/// The run as a whole.
public struct OffloadReport: Sendable {
    public let source: URL
    public let algorithm: OffloadHashAlgorithm
    public let started: Date
    public let finished: Date
    public let filesTotal: Int
    public let bytesTotal: Int64
    /// Files the run reached before it ended (cancel stops between files).
    public let filesProcessed: Int
    /// Entries the scan could not take: a directory the card would not let us
    /// walk, or something that is not a regular file (a symlink, a device node).
    public let scanFailures: [String]
    /// Files the card would not give us cleanly — an unreadable file, or one
    /// whose length changed while it was being copied (a camera still writing).
    /// These are what make a card unsafe to wipe, so they are reported at run
    /// level and repeated in every destination's summary.
    public let sourceFailures: [String]
    public let wasCancelled: Bool
    public let destinations: [OffloadDestinationResult]

    public init(source: URL, algorithm: OffloadHashAlgorithm, started: Date,
                finished: Date, filesTotal: Int, bytesTotal: Int64,
                filesProcessed: Int, scanFailures: [String],
                sourceFailures: [String], wasCancelled: Bool,
                destinations: [OffloadDestinationResult]) {
        self.source = source
        self.algorithm = algorithm
        self.started = started
        self.finished = finished
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
        self.filesProcessed = filesProcessed
        self.scanFailures = scanFailures
        self.sourceFailures = sourceFailures
        self.wasCancelled = wasCancelled
        self.destinations = destinations
    }

    /// Nothing to explain to the operator: every destination has every file.
    public var isFullyVerified: Bool {
        !destinations.isEmpty && scanFailures.isEmpty && sourceFailures.isEmpty
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
