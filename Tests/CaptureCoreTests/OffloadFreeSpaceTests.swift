import Foundation
import Testing

@testable import CaptureCore

/// **Which free-space number the preflight believes.**
///
/// The offload refused a card with "not enough space: needs 31.5 GB, 0 bytes
/// free" onto a 4 TB shuttle with 1.5 TB on it, while the destination tile
/// beside it read 1.5 TB free — off the same key (owner, 2026-09-08).
///
/// `volumeAvailableCapacityForImportantUsage` is written for the BOOT volume:
/// it counts space the system could purge, and a volume that cannot account for
/// that may answer 0 with terabytes free. So a zero from it is not an answer,
/// and the plain capacity — which an external drive can always give — is.
@Suite struct OffloadFreeSpaceTests {
    @Test func aZeroFromTheBootVolumesKeyIsNotAnAnswer() {
        #expect(VolumeSpace.believe(important: 0, plain: 1_500_000_000_000)
                    == 1_500_000_000_000)
        #expect(VolumeSpace.believe(important: nil, plain: 512) == 512)
    }

    /// When it does answer, it is the better number of the two: it includes
    /// space the system would free up rather than only what is unused today.
    @Test func theImportantUsageNumberWinsWhenItHasOne() {
        #expect(VolumeSpace.believe(important: 2000, plain: 1000) == 2000)
    }

    /// **No number is nil, and nil does not fail the preflight.** A check that
    /// refuses on a reading it could not take costs the operator the offload;
    /// a disk that really is full fails on the first write, saying so.
    @Test func noNumberAtAllIsNotAFullDisk() {
        #expect(VolumeSpace.believe(important: nil, plain: nil) == nil)
        #expect(VolumeSpace.believe(important: 0, plain: 0) == nil)
    }
}

/// **One rule, asked by everything that asks.**
///
/// The offload's destination tile, the offload's preflight and the record
/// folder's disk alarm each read free space their own way, and the tile and
/// the preflight disagreed on set (owner: "оффлоадер карт неверно определяет
/// свободное пространство на целевом диске"). A number that decides whether
/// footage gets copied is not a question two parts of the app may answer
/// differently, so there is one function now and this is the check that it
/// stays the only one.
@Suite struct VolumeSpaceSingleRuleTests {
    /// Every reader goes through `VolumeSpace`. Asserted on the SOURCE,
    /// because the failure is a second reader appearing — which no runtime
    /// test can see, and which is exactly how this bug happened.
    @Test func nothingElseAsksTheVolumeDirectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "VolumeSpace.swift",
                  let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            files += 1
            for (index, line) in raw.components(separatedBy: "\n").enumerated() {
                let code = line.contains("//")
                    ? String(line[line.startIndex..<line.range(of: "//")!.lowerBound])
                    : line
                guard code.contains("volumeAvailableCapacity") else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        #expect(offenders.isEmpty, """
            free space is read outside VolumeSpace, which is how the tile and \
            the preflight came to disagree: \(offenders.joined(separator: ", "))
            """)
    }

    /// The tile's two numbers come from the same believing rule as the
    /// preflight's one — a tile that reported 0 free beside a preflight that
    /// found 1.5 TB is the shape of the original complaint.
    @Test func theTileAndThePreflightBelieveTheSameAnswer() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capacity = try #require(VolumeSpace.capacity(of: folder))
        let free = try #require(VolumeSpace.free(of: folder))
        #expect(capacity.free == free,
                "the tile says \(capacity.free) and the preflight \(free)")
        #expect(capacity.total > 0)
    }
}
