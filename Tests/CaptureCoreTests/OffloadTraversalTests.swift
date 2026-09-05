import Foundation
import Testing

@testable import CaptureCore

/// **A manifest naming a path outside the destination is not this app's
/// manifest.** The verify pass read `<path>` off a returned SSD as-is:
/// `../../../../Users/op/Library/Keychains/x` walked up cleanly from the
/// destination, its size went into the report and its bytes through the hash.
@Suite struct OffloadTraversalTests {
    @Test func theRuleIsRelativeAndNeverClimbing() {
        #expect(OffloadManifestReader.staysInside("CLIPS/A001C001.mov"))
        #expect(OffloadManifestReader.staysInside("A001.mov"))
        for climbing in ["/etc/passwd", "../x.mov", "a/../../x", "a//b.mov",
                         "./a.mov", "a/./b", "\\\\server\\share", "a/"] {
            #expect(!OffloadManifestReader.staysInside(climbing),
                    "\(climbing) was read as a path inside the destination")
        }
    }

    @Test func aManifestThatClimbsIsRefusedAsTampered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("traversal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest: URL = try OffloadMHL.write(
            entries: [OffloadEntry(relativePath: "../../outside.mov", size: 7, hash: "aabb")],
            into: root, algorithm: .xxh64,
            creator: OffloadCreatorInfo(toolName: "TakeShot", toolVersion: "1", hostname: "cart"),
            date: Date(timeIntervalSince1970: 0))
        #expect(throws: OffloadVerifyError.self) {
            _ = try OffloadManifestReader.read(manifest)
        }
    }
}
