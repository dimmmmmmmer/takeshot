import CryptoKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Verified offload is the one feature in the app whose whole point is that it
/// cannot quietly half-work: a card is wiped on the strength of its result. The
/// two panels in front of it are untestable, but the copy core is not — and it
/// is the part where "silently skipped a file", "silently overwrote a file" and
/// "reported done after the manifest failed to write" would all look identical
/// to the operator.
struct ControllerOffloadTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-offload-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// "A card copy must be COMPLETE": hidden files and nested folders
    /// included, directories themselves excluded.
    @Test func theScanFindsEveryFileIncludingHiddenOnes() throws {
        let source = try scratch("scan")
        defer { try? FileManager.default.removeItem(at: source) }
        try write([1], to: source.appendingPathComponent("DCIM/A001.mov"))
        try write([2], to: source.appendingPathComponent("DCIM/SUB/A002.mov"))
        try write([3], to: source.appendingPathComponent(".metadata"))

        let scan = CaptureController.scanOffloadSource(source)

        #expect(scan.failures.isEmpty)
        #expect(Set(scan.files.map(\.lastPathComponent))
            == ["A001.mov", "A002.mov", ".metadata"])
    }

    @Test func aVerifiedCopyReproducesTheFileAndRecordsItsHash() throws {
        let source = try scratch("copy-src")
        let dest = try scratch("copy-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let bytes: [UInt8] = Array(0...255)
        let file = source.appendingPathComponent("DCIM/A001.mov")
        try write(bytes, to: file)

        var failures: [String] = []
        let row = try #require(CaptureController.copyVerified(
            file, from: source, to: dest, failures: &failures))

        #expect(failures.isEmpty)
        // the relative layout of the card is preserved, not flattened
        let copied = dest.appendingPathComponent("DCIM/A001.mov")
        #expect(try Data(contentsOf: copied) == Data(bytes))
        #expect(row.contains("DCIM/A001.mov"))
        #expect(row.contains(sha256(bytes)))
        #expect(row.contains(",\(bytes.count),"))
        #expect(row.hasSuffix("\n"))
    }

    /// Two cards with the same DCIM layout are the normal case; the second one
    /// must not overwrite the first.
    @Test func anExistingCopyIsUniquifiedRatherThanOverwritten() throws {
        let source = try scratch("clash-src")
        let dest = try scratch("clash-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let earlier: [UInt8] = [0xAA, 0xBB]
        try write(earlier, to: dest.appendingPathComponent("A001.mov"))
        let bytes: [UInt8] = [0x01, 0x02, 0x03]
        try write(bytes, to: source.appendingPathComponent("A001.mov"))

        var failures: [String] = []
        _ = CaptureController.copyVerified(
            source.appendingPathComponent("A001.mov"),
            from: source, to: dest, failures: &failures)

        #expect(failures.isEmpty)
        #expect(try Data(contentsOf: dest.appendingPathComponent("A001.mov"))
            == Data(earlier))
        #expect(try Data(contentsOf: dest.appendingPathComponent("A001_2.mov"))
            == Data(bytes))
    }

    /// A copy that cannot even be attempted has to be named, not dropped —
    /// the failure list is the only thing standing between the operator and a
    /// wiped card.
    @Test func aCopyThatCannotLandIsNamedInTheFailures() throws {
        let source = try scratch("bad-src")
        let blocked = try scratch("bad-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: blocked)
        }
        try write([1], to: source.appendingPathComponent("DCIM/A001.mov"))
        // a regular file where the destination's DCIM folder needs to be
        try write([0], to: blocked.appendingPathComponent("DCIM"))

        var failures: [String] = []
        let row = CaptureController.copyVerified(
            source.appendingPathComponent("DCIM/A001.mov"),
            from: source, to: blocked, failures: &failures)

        #expect(row == nil)
        #expect(failures.count == 1)
        #expect(failures.first?.contains("A001.mov") == true)
    }

    @Test func theManifestLandsNextToTheCopy() throws {
        let dest = try scratch("manifest")
        defer { try? FileManager.default.removeItem(at: dest) }

        var failures: [String] = []
        CaptureController.writeManifest("File,SHA256\nA001.mov,abc\n",
                                        to: dest, failures: &failures)

        #expect(failures.isEmpty)
        let csv = try String(
            contentsOf: dest.appendingPathComponent("offload-manifest.csv"),
            encoding: .utf8)
        #expect(csv.contains("A001.mov,abc"))
    }

    /// The backup volume going away mid-offload used to end with "offload
    /// done" and no manifest at all.
    @Test func aManifestThatCannotBeWrittenIsAFailure() throws {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-offload-gone-\(UUID().uuidString)")

        var failures: [String] = []
        CaptureController.writeManifest("File,SHA256\n", to: gone,
                                        failures: &failures)

        #expect(failures.count == 1)
        #expect(failures.first?.contains("offload-manifest.csv") == true)
    }
}
