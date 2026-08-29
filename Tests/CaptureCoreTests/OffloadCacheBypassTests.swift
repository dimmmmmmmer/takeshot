import Foundation
import Testing

@testable import CaptureCore

/// Whether the verify pass actually read the DISK, as opposed to having asked
/// to.
///
/// The pass re-reads every copy through `F_NOCACHE` for one reason: comparing
/// against something still sitting in the unified page cache verifies RAM, not
/// the disk the card is about to be wiped against. `F_NOCACHE` is advisory — a
/// network volume is the ordinary refusal — and the result of asking was
/// discarded, which turned that guarantee into a hope nothing could check.
struct OffloadCacheBypassTests {
    private func scratch(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-bypass-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root
    }

    /// On a local volume the bypass is granted, and the report says nothing —
    /// which is the case that must not become noisy.
    @Test func aLocalVolumeGrantsTheBypass() throws {
        let root = try scratch("local")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.bin")
        try Data(repeating: 0xA5, count: 64 * 1024).write(to: file)

        var refused = true
        let hash = try OffloadHasher.hashFile(
            at: file, algorithm: .xxh64, bypassCache: true,
            cacheBypassRefused: &refused)
        #expect(!hash.isEmpty)
        #expect(!refused,
                "the scratch volume refused F_NOCACHE — this test cannot speak")
    }

    /// …and the digest is the same either way. The flag is about WHERE the
    /// bytes came from, never about what they are, so a refusal must not
    /// quietly change a hash that a manifest is about to record.
    @Test func theDigestDoesNotDependOnTheBypass() throws {
        let root = try scratch("digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.bin")
        try Data((0..<40_000).map { UInt8($0 % 251) }).write(to: file)

        var refused = false
        let bypassed = try OffloadHasher.hashFile(
            at: file, algorithm: .xxh64, bypassCache: true,
            cacheBypassRefused: &refused)
        let cached = try OffloadHasher.hashFile(
            at: file, algorithm: .xxh64, bypassCache: false)
        #expect(bypassed == cached,
                "the cache bypass changed the digest: \(bypassed) vs \(cached)")
    }

    /// A read that never ASKED for the bypass reports nothing either way — the
    /// callback fires only for a request, so "not refused" cannot be confused
    /// with "not asked".
    @Test func aReadThatDidNotAskIsNotReportedAsRefused() throws {
        let root = try scratch("unasked")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.bin")
        try Data(repeating: 7, count: 2048).write(to: file)

        var told = false
        try OffloadIO.readChunks(of: file, bypassCache: false,
                                 onCacheBypass: { _ in told = true },
                                 body: { _ in })
        #expect(!told, "a read that asked for nothing was told about a bypass")

        told = false
        try OffloadIO.readChunks(of: file, bypassCache: true,
                                 onCacheBypass: { _ in told = true },
                                 body: { _ in })
        #expect(told, "a read that asked was never told the answer")
    }

    /// The count is a per-DESTINATION fact arriving one file at a time, and it
    /// reaches the result the panel reads.
    @Test func theCountReachesTheDestinationResult() {
        var result = OffloadDestinationResult(
            id: 0, url: URL(fileURLWithPath: "/tmp/dest"),
            totals: OffloadDestinationTotals(filesVerified: 3, filesTotal: 3,
                                             bytesWritten: 300, elapsed: 1),
            mismatches: [], failure: nil, wasCancelled: false)
        #expect(result.unbypassedVerifies == 0,
                "an ordinary result starts out claiming refusals")
        result.unbypassedVerifies = 3
        #expect(result.outcome == .verified,
                "a refused bypass must not change the verdict, only qualify it")
    }
}
