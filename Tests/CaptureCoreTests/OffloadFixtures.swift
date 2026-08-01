import Foundation
import Testing

@testable import CaptureCore

/// Shared fixtures for the offload suites: a scratch card on disk, and a
/// finished run that never touched one.
///
/// The card layout is deliberately awkward in the ways a real one is: nested
/// folders, a hidden file the camera wrote, a file long enough to need several
/// chunks, and one only a byte long. Content is deterministic, so a hash
/// mismatch in a test means the copy is wrong rather than that the fixture
/// rolled different bytes this run.
enum OffloadFixtures {
    static let card: [(path: String, bytes: Int)] = [
        ("DCIM/100MEDIA/A001C001.mov", 200_000),
        ("DCIM/100MEDIA/A001C002.mov", 9),
        ("DCIM/100MEDIA/sub/deep/A001C003.mov", 1),
        ("CLIPS/index.xml", 512),
        (".metadata", 32),
    ]

    /// 64 KiB, so the 200 KB file above goes through the multi-chunk path
    /// without the suite writing gigabytes.
    static let chunk = 64 << 10

    static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-offload-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        // Resolved, because the engine reports the paths the enumerator hands
        // back (/private/var...) and a test comparing against /var... never matches.
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    static func content(_ count: Int, salt: Int = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31 + salt + 7) })
    }

    static func makeCard(at root: URL) throws {
        for (index, file) in card.enumerated() {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try content(file.bytes, salt: index).write(to: url)
        }
    }

    /// Independent of the engine's streaming reader: whole file, one shot.
    static func hash(of url: URL) throws -> String {
        XXH64.hex(XXH64.hash(try Data(contentsOf: url)))
    }

    /// Re-verify a manifest the way an outside tool does, and return the paths it
    /// listed.
    ///
    /// This is the property the whole feature is sold on: post drops the SSD on a
    /// machine running `ascmhl`/Silverstack weeks later, and every `<path>` is
    /// resolved against the copy's own root, hashed and compared with what the
    /// manifest claims. A manifest that does not line up with the disk is worse
    /// than no manifest, because it fails at the post house instead of on set.
    static func verifyManifest(at manifest: URL, root: URL) throws -> [String] {
        let document = try XMLDocument(contentsOf: manifest)
        var listed: [String] = []
        for node in try document.nodes(forXPath: "//*[local-name()='hash']")
            .compactMap({ $0 as? XMLElement }) {
            let path = try #require(node.elements(forName: "path").first)
            let relative = try #require(path.stringValue)
            listed.append(relative)
            let copy = root.appendingPathComponent(relative)
            let digest = try #require(node.elements(forName: "xxh64").first)
            #expect(digest.stringValue == (try hash(of: copy)),
                    "manifest hash for \(relative)")
            #expect(path.attribute(forName: "size")?.stringValue
                == String(try Data(contentsOf: copy).count),
                    "manifest size for \(relative)")
        }
        return listed
    }

    static func summaryText(_ result: OffloadDestinationResult) throws -> String {
        let url = try #require(result.summaryURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - a finished run, invented rather than copied

    /// The synthetic facts the two report suites draw from.
    ///
    /// Shared because the .txt summary and the picture beside it are two
    /// renderings of the SAME run. A suite that invented its own numbers would
    /// drift, and the day the two reports started disagreeing there would be
    /// nothing to say which of them was right.
    static let reportCreator = OffloadCreatorInfo(toolName: "TakeShot",
                                                  toolVersion: "0.1.0",
                                                  hostname: "studio-mac.local")

    static func reportRun(files: Int = 3, bytes: Int64 = 4096,
                          sourceFailures: [String] = [],
                          scanFailures: [String] = []) -> OffloadRunFacts {
        OffloadRunFacts(
            source: URL(fileURLWithPath: "/Volumes/CARD_A001"),
            algorithm: .xxh64, creator: reportCreator,
            span: OffloadSpan(
                started: Date(timeIntervalSince1970: 1_800_000_000),
                finished: Date(timeIntervalSince1970: 1_800_000_930)),
            card: OffloadVolume(files: files, bytes: bytes),
            problems: OffloadProblems(scan: scanFailures,
                                      source: sourceFailures))
    }

    static func reportResult(
        verified: Int = 3, mismatches: [String] = [], failure: String? = nil,
        cancelled: Bool = false) -> OffloadDestinationResult {
        var result = OffloadDestinationResult(
            id: 0, url: URL(fileURLWithPath: "/Volumes/SSD1/CARD_A001"),
            totals: OffloadDestinationTotals(
                filesVerified: verified, filesTotal: 3, bytesWritten: 4096,
                elapsed: 930),
            mismatches: mismatches, failure: failure, wasCancelled: cancelled)
        result.manifestURL = URL(fileURLWithPath:
            "/Volumes/SSD1/CARD_A001/ascmhl/0001_CARD_A001.mhl")
        return result
    }

    /// Corrupt one byte in place — the fault the verify pass exists to catch.
    static func flipFirstByte(of url: URL) {
        guard let handle = try? FileHandle(forUpdating: url),
              let byte = try? handle.read(upToCount: 1), !byte.isEmpty
        else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Data([byte[byte.startIndex] ^ 0xFF]))
        try? handle.close()
    }
}
