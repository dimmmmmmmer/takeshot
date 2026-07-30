import CryptoKit
import Foundation

/// Which checksum an offload run uses.
///
/// Two, not one: xxHash64 is what the DIT tools default to and what post will
/// re-verify with, and SHA-256 is what a delivery spec occasionally demands in
/// writing. The choice travels into the MHL manifest, so it has to be recorded
/// per run rather than compiled in.
public enum OffloadHashAlgorithm: String, CaseIterable, Codable, Sendable,
                                  Identifiable {
    case xxh64
    case sha256

    public var id: String { rawValue }

    /// The element name ASC MHL uses for this hash inside a `<hash>` entry —
    /// also the string tools print in their own reports.
    public var manifestElement: String { rawValue }

    /// For the UI and the human-readable summary.
    public var displayName: String {
        switch self {
        case .xxh64: return "xxHash64"
        case .sha256: return "SHA-256"
        }
    }
}

/// One streaming digest, whichever algorithm the run chose.
///
/// The offload path hashes the source on the read stream and the destination on
/// a re-read, in both algorithms, over files that do not fit in memory — so the
/// only shape that works is a hasher fed arbitrary chunks. CryptoKit's
/// `SHA256` already is one; `XXH64` is written to match.
public struct OffloadHasher {
    private var xxh: XXH64?
    private var sha: SHA256?

    public init(_ algorithm: OffloadHashAlgorithm) {
        switch algorithm {
        case .xxh64: xxh = XXH64()
        case .sha256: sha = SHA256()
        }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        xxh?.update(bytes)
        sha?.update(bufferPointer: bytes)
    }

    /// Lowercase hex, the form both an MHL manifest and `xxhsum`/`shasum` use.
    public func finalize() -> String {
        if let xxh { return XXH64.hex(xxh.finalize()) }
        guard let sha else { return "" }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of a whole file, streamed.
    ///
    /// `bypassCache` reads through `F_NOCACHE`: verifying a copy that is still
    /// sitting in the unified page cache verifies RAM, not the disk the card is
    /// about to be wiped against.
    public static func hashFile(at url: URL,
                                algorithm: OffloadHashAlgorithm,
                                bypassCache: Bool = false,
                                chunkBytes: Int = OffloadIO.defaultChunkBytes) throws
        -> String {
        var hasher = OffloadHasher(algorithm)
        try OffloadIO.readChunks(of: url, bypassCache: bypassCache,
                                 chunkBytes: chunkBytes) { chunk in
            hasher.update(chunk)
        }
        return hasher.finalize()
    }
}

/// Offload failures that are ours rather than the filesystem's. English, like
/// the rest of CaptureCore — these strings end up in a report for post, not in
/// the operator's UI chrome.
public enum OffloadError: LocalizedError {
    case cannotCreateFile(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let name):
            return "could not create \(name) on the destination"
        }
    }
}

/// The file I/O the offload engine is built on, in one place: chunked reads that
/// report errors instead of trapping, and the cache/flush behaviour a verified
/// copy depends on.
public enum OffloadIO {
    /// 8 MiB: large enough that a spinning-disk card reads at full speed, small
    /// enough that N destination writes of one chunk stay in cache together.
    public static let defaultChunkBytes = 8 << 20

    /// Feed `body` the file's bytes, chunk by chunk.
    ///
    /// `FileHandle.read(upToCount:)` and not `readData(ofLength:)`: the latter
    /// raises an Objective-C exception on an I/O error, which Swift cannot
    /// catch — a card with a bad sector took the whole app down instead of
    /// naming the file it could not read.
    public static func readChunks(
        of url: URL, bypassCache: Bool = false,
        chunkBytes: Int = defaultChunkBytes,
        body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassCache {
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        }
        while try autoreleasepool(invoking: {
            // The chunk is a fresh Data per iteration and the pool keeps a
            // long file from stacking every one of them until the loop ends.
            guard let chunk = try handle.read(upToCount: chunkBytes),
                  !chunk.isEmpty else { return false }
            try chunk.withUnsafeBytes(body)
            return true
        }) {}
    }

    /// Push a freshly written file out of the buffer cache and onto the device.
    ///
    /// `F_FULLFSYNC` rather than `fsync`: fsync only guarantees the data reached
    /// the drive, not that the drive wrote it out of its own cache, and the
    /// re-read that verifies the copy would happily be served from either. The
    /// point of the verify pass is to read what is actually on the SSD.
    public static func flushToDevice(_ handle: FileHandle) throws {
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            // Not every filesystem implements it (network volumes especially);
            // fall back rather than fail a copy that is otherwise fine.
            try handle.synchronize()
        }
    }
}
