import Foundation
import Testing

@testable import CaptureCore

/// The offload engine is the one part of the app whose whole point is that it
/// cannot quietly half-work: a camera card is formatted on the strength of its
/// result. Everything here runs on scratch directories with a known tree, and
/// every assertion is the kind of failure that would otherwise be discovered
/// after the card was wiped — a file silently skipped, a copy that differs from
/// the original, a card's own layout not preserved.
///
/// This suite is the scan and the copy. What the run WROTE — the manifest and the
/// summary — is `OffloadManifestTests`; what it does when something breaks is
/// `OffloadFailureTests`.
struct OffloadEngineTests {
    // MARK: - the scan

    /// "A card copy must be COMPLETE": hidden files and nested folders included,
    /// the folders themselves excluded, sizes read off the disk.
    @Test func theScanFindsEveryFileWithItsSizeAndCardRelativePath() throws {
        let source = try OffloadFixtures.scratch("scan")
        defer { try? FileManager.default.removeItem(at: source) }
        try OffloadFixtures.makeCard(at: source)

        let scan = OffloadEngine.scan(source)

        #expect(scan.failures.isEmpty)
        #expect(scan.files.map(\.relativePath)
            == OffloadFixtures.card.map(\.path).sorted())
        let sizes = Dictionary(uniqueKeysWithValues:
            scan.files.map { ($0.relativePath, $0.size) })
        for file in OffloadFixtures.card {
            #expect(sizes[file.path] == Int64(file.bytes), "\(file.path)")
        }
    }

    /// The relative path is what the copy's layout and the manifest are built
    /// from. A source with a trailing slash used to leave it absolute, which put
    /// the copy somewhere nobody asked for.
    @Test func theRelativePathSurvivesAnUntidySourceURL() throws {
        let source = try OffloadFixtures.scratch("relative")
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("DCIM/A001.mov")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OffloadFixtures.content(4).write(to: file)

        let trailingSlash = URL(fileURLWithPath: source.path + "/")
        let doubled = URL(fileURLWithPath: source.path + "/./")

        #expect(OffloadEngine.relativePath(of: file, under: source)
            == "DCIM/A001.mov")
        #expect(OffloadEngine.relativePath(of: file, under: trailingSlash)
            == "DCIM/A001.mov")
        #expect(OffloadEngine.relativePath(of: file, under: doubled)
            == "DCIM/A001.mov")
    }

    @Test func aSourceThatIsNotThereIsAFailureNotAnEmptyCard() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-gone-\(UUID().uuidString)")

        let scan = OffloadEngine.scan(missing)

        #expect(scan.files.isEmpty)
        #expect(scan.failures.count == 1)
    }

    // MARK: - the copy

    /// The core promise: one read of the card, two byte-identical copies, every
    /// file verified by reading it back off each destination.
    @Test func oneCardLandsOnTwoDestinationsByteForByte() throws {
        let source = try OffloadFixtures.scratch("copy-src")
        let first = try OffloadFixtures.scratch("copy-a")
        let second = try OffloadFixtures.scratch("copy-b")
        defer {
            for url in [source, first, second] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [first, second],
            chunkBytes: OffloadFixtures.chunk))

        #expect(report.isFullyVerified)
        #expect(report.run.card.files == OffloadFixtures.card.count)
        #expect(report.filesProcessed == OffloadFixtures.card.count)
        #expect(report.run.card.bytes
            == Int64(OffloadFixtures.card.map(\.bytes).reduce(0, +)))
        #expect(report.destinations.count == 2)
        for result in report.destinations {
            #expect(result.outcome == .verified)
            #expect(result.totals.filesVerified == OffloadFixtures.card.count)
            #expect(result.totals.bytesWritten == report.run.card.bytes)
            for file in OffloadFixtures.card {
                let copy = result.url.appendingPathComponent(file.path)
                #expect(try Data(contentsOf: copy)
                    == Data(contentsOf: source.appendingPathComponent(file.path)),
                        "\(file.path) on \(result.url.lastPathComponent)")
            }
        }
    }

    /// The default 8 MiB chunk is what the app actually runs with, so the whole
    /// path is exercised once without the test's small-chunk override.
    @Test func theProductionChunkSizeCopiesAndVerifies() throws {
        let source = try OffloadFixtures.scratch("chunk-src")
        let dest = try OffloadFixtures.scratch("chunk-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(OffloadPlan(source: source,
                                                   destinations: [dest]))

        #expect(report.isFullyVerified)
        #expect(report.destinations.first?.totals.filesVerified
            == OffloadFixtures.card.count)
    }

    /// A byte-for-byte copy is not the whole job: post sorts dailies by shoot
    /// time, so the camera's modification date has to survive the copy. Streaming
    /// the bytes ourselves is what put this at risk — `copyItem` did it for free.
    @Test func theCopyKeepsTheCardsModificationDate() throws {
        let source = try OffloadFixtures.scratch("mtime-src")
        let dest = try OffloadFixtures.scratch("mtime-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let file = source.appendingPathComponent("A001C001.mov")
        try OffloadFixtures.content(128).write(to: file)
        let shotAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: shotAt],
                                              ofItemAtPath: file.path)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [dest],
            chunkBytes: OffloadFixtures.chunk))

        #expect(report.isFullyVerified)
        let copied = try dest.appendingPathComponent("A001C001.mov")
            .resourceValues(forKeys: [.contentModificationDateKey])
        let landed = try #require(copied.contentModificationDate)
        #expect(abs(landed.timeIntervalSince(shotAt)) < 1)
    }

    /// Two cards with the same DCIM layout are the normal case; the second one
    /// must not overwrite the first.
    @Test func anExistingCopyIsUniquifiedRatherThanOverwritten() throws {
        let source = try OffloadFixtures.scratch("clash-src")
        let dest = try OffloadFixtures.scratch("clash-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let earlier = OffloadFixtures.content(3, salt: 99)
        try earlier.write(to: dest.appendingPathComponent("A001.mov"))
        let bytes = OffloadFixtures.content(11)
        try bytes.write(to: source.appendingPathComponent("A001.mov"))

        let report = OffloadEngine.run(OffloadPlan(source: source,
                                                   destinations: [dest],
                                                   chunkBytes: OffloadFixtures.chunk))

        #expect(report.isFullyVerified)
        #expect(try Data(contentsOf: dest.appendingPathComponent("A001.mov"))
            == earlier)
        #expect(try Data(contentsOf: dest.appendingPathComponent("A001_2.mov"))
            == bytes)
    }
}
