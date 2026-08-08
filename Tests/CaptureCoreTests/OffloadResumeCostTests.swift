import Foundation
import Testing

@testable import CaptureCore

/// What resuming COSTS, measured rather than claimed.
///
/// Resume trades a read of the destination for a read of the card plus a write of
/// the destination. That is a large win on a slow disk and a smaller one on a
/// fast disk with a fast card, and the honest thing is to have measured it —
/// which is why this suite copies a real 32 MiB tree three ways and prints what
/// each took.
///
/// The TIMES are printed and not asserted, for the reason the ProRes metadata
/// test prints rather than asserts: a wall clock on a shared CI runner measures
/// the runner, not this code. What is asserted is the I/O VOLUME, which is
/// deterministic — zero bytes written and every file verified is the whole claim,
/// and it is the part that could regress.
struct OffloadResumeCostTests {
    /// Sixteen 2 MiB files: big enough that hashing and copying dominate the
    /// per-file overhead, small enough that the suite stays a suite.
    private static let fileCount = 16
    private static let fileBytes = 2 << 20
    private static var totalBytes: Int64 {
        Int64(fileCount * fileBytes)
    }

    /// A card of identical-length files with distinct contents. Built from one
    /// block with a few bytes stamped per file rather than byte by byte: the
    /// per-byte version of this takes longer to GENERATE in a debug build than
    /// the copies being measured take to run.
    private func makeCard(at root: URL) throws {
        let folder = root.appendingPathComponent("DCIM/100MEDIA")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        var block = Data(repeating: 0xA5, count: Self.fileBytes)
        for index in 0..<Self.fileCount {
            for offset in 0..<8 {
                block[offset] = UInt8(truncatingIfNeeded: index * 8 + offset)
                block[block.count - 1 - offset] = UInt8(
                    truncatingIfNeeded: index * 3 + offset)
            }
            try block.write(to: folder.appendingPathComponent(
                String(format: "A001C%03d.mov", index + 1)))
        }
    }

    private func plan(_ source: URL, _ dest: URL,
                      resume: Bool = false) -> OffloadPlan {
        // The production chunk size, because this is a measurement of what the
        // app actually does.
        OffloadPlan(source: source, destinations: [dest], resume: resume)
    }

    @Test func resumingCostsADiskReadInsteadOfACardReadAndADiskWrite() throws {
        let source = try OffloadFixtures.scratch("cost-src")
        let dest = try OffloadFixtures.scratch("cost-dst")
        let fresh = try OffloadFixtures.scratch("cost-fresh")
        defer {
            for url in [source, dest, fresh] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try makeCard(at: source)

        let firstStart = Date()
        let first = OffloadEngine.run(plan(source, dest))
        let firstElapsed = Date().timeIntervalSince(firstStart)

        let resumeStart = Date()
        let resumed = OffloadEngine.run(plan(source, dest, resume: true))
        let resumeElapsed = Date().timeIntervalSince(resumeStart)

        let againStart = Date()
        let again = OffloadEngine.run(plan(source, fresh))
        let againElapsed = Date().timeIntervalSince(againStart)

        // What is asserted: the resumed run wrote nothing and verified everything.
        #expect(first.isFullyVerified)
        #expect(resumed.isFullyVerified)
        #expect(again.isFullyVerified)
        let result = try #require(resumed.destinations.first)
        #expect(result.totals.bytesWritten == 0)
        #expect(result.totals.filesVerified == Self.fileCount)
        #expect(result.resume?.reused == Self.fileCount)
        #expect(result.resume?.reusedBytes == Self.totalBytes)
        #expect(result.resume?.replaced.isEmpty == true)
        #expect(again.destinations.first?.totals.bytesWritten == Self.totalBytes)

        // What is printed: the trade, on this machine, this run.
        let megabytes = Double(Self.totalBytes) / 1_000_000
        print("""
            offload resume cost — \(Self.fileCount) files, \
            \(String(format: "%.1f", megabytes)) MB
              first copy (card read + disk write + verify read): \
            \(String(format: "%.2f", firstElapsed)) s
              copy it all again to a fresh disk:                 \
            \(String(format: "%.2f", againElapsed)) s
              resume (destination read only, 0 bytes written):   \
            \(String(format: "%.2f", resumeElapsed)) s \
            (\(String(format: "%.2f", againElapsed / max(resumeElapsed, 0.001)))x \
            faster than re-copying)
            """)
    }
}
