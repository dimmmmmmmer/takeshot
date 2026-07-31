import Foundation
import Testing

@testable import CaptureCore

/// The two files an offload leaves in each destination, after a real run.
///
/// `OffloadReportTests` pins the shape of the manifest and the summary in
/// isolation; this suite is the other half — what a completed run actually wrote
/// to a scratch disk. It matters separately because the manifest is the
/// deliverable: post drops the SSD on a machine running `ascmhl`, Silverstack or
/// OffShoot weeks later and re-computes every hash. So every entry is re-verified
/// here the way that tool would, against the file on the destination rather than
/// against the card.
struct OffloadManifestTests {
    /// A uniquified copy has to be uniquified in the manifest too.
    ///
    /// The manifest is the deliverable: post runs `ascmhl verify` against the
    /// drive weeks later. A `<path>` that named the card's file rather than the
    /// file actually written would send the verifier at the OTHER file — the one
    /// that was already sitting on the destination — and it would report the
    /// footage corrupt. The hash it lists belongs to the copy, so the path has to
    /// as well.
    @Test func theManifestNamesTheCopyThatWasActuallyWritten() throws {
        let source = try OffloadFixtures.scratch("mpath-src")
        let dest = try OffloadFixtures.scratch("mpath-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        // a previous card left a file of the same name in the same subfolder
        for root in [source, dest] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("DCIM"),
                withIntermediateDirectories: true)
        }
        try OffloadFixtures.content(3, salt: 99)
            .write(to: dest.appendingPathComponent("DCIM/A001.mov"))
        try OffloadFixtures.content(11)
            .write(to: source.appendingPathComponent("DCIM/A001.mov"))

        let report = OffloadEngine.run(OffloadPlan(source: source,
                                                   destinations: [dest],
                                                   chunkBytes: OffloadFixtures.chunk))

        let result = try #require(report.destinations.first)
        #expect(report.isFullyVerified)
        // verifyManifest hashes whatever each <path> points at, so a manifest
        // still naming DCIM/A001.mov fails on the hash as well as on the name
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest) == ["DCIM/A001_2.mov"])
    }

    /// The ordinary case, checked the same way: every entry in the manifest
    /// re-verifies against the file it names on the destination.
    @Test func theWholeManifestReVerifiesAgainstTheCopyOnDisk() throws {
        let source = try OffloadFixtures.scratch("reverify-src")
        let dest = try OffloadFixtures.scratch("reverify-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(OffloadPlan(source: source,
                                                   destinations: [dest],
                                                   chunkBytes: OffloadFixtures.chunk))

        let result = try #require(report.destinations.first)
        #expect(try OffloadFixtures.verifyManifest(
            at: #require(result.manifestURL), root: dest).sorted()
            == OffloadFixtures.card.map(\.path).sorted())
    }

    // MARK: - after a real run

    @Test func theManifestListsEveryFileWithAnIndependentlyComputedHash() throws {
        let source = try OffloadFixtures.scratch("mhl-src")
        let dest = try OffloadFixtures.scratch("mhl-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [dest],
            creator: OffloadCreatorInfo(toolName: "TakeShot", toolVersion: "9.9",
                                        hostname: "test-host"),
            chunkBytes: OffloadFixtures.chunk))

        let manifest = try #require(report.destinations.first?.manifestURL)
        // Where ASC MHL tools look: an `ascmhl` folder at the root of the copy.
        #expect(manifest.deletingLastPathComponent().lastPathComponent == "ascmhl")
        #expect(manifest.lastPathComponent.hasPrefix("0001_"))
        let document = try XMLDocument(contentsOf: manifest)
        // local-name(): the document declares a default namespace, and an
        // unprefixed XPath step would match nothing at all — which is also the
        // check that the namespace is there.
        let hashes = try document.nodes(forXPath: "//*[local-name()='hash']")
        #expect(hashes.count == OffloadFixtures.card.count)
        var listed: [String: (size: String, hash: String)] = [:]
        for node in hashes.compactMap({ $0 as? XMLElement }) {
            let path = try #require(node.elements(forName: "path").first)
            let digest = try #require(node.elements(forName: "xxh64").first)
            #expect(digest.attribute(forName: "action")?.stringValue == "original")
            listed[path.stringValue ?? ""] = (
                path.attribute(forName: "size")?.stringValue ?? "",
                digest.stringValue ?? "")
        }
        #expect(Set(listed.keys) == Set(OffloadFixtures.card.map(\.path)))
        for file in OffloadFixtures.card {
            let entry = try #require(listed[file.path])
            #expect(entry.size == String(file.bytes))
            #expect(entry.hash
                == (try OffloadFixtures.hash(of: source.appendingPathComponent(file.path))),
                    "\(file.path)")
        }
        let tool = try #require(document.nodes(forXPath: "//*[local-name()='tool']")
            .first as? XMLElement)
        #expect(tool.stringValue == "TakeShot")
        #expect(tool.attribute(forName: "version")?.stringValue == "9.9")
        #expect((try document.nodes(forXPath: "//*[local-name()='hostname']")
            .first?.stringValue) == "test-host")
    }

    @Test func theManifestRecordsSHA256WhenThatIsWhatWasAskedFor() throws {
        let source = try OffloadFixtures.scratch("sha-src")
        let dest = try OffloadFixtures.scratch("sha-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.content(2048).write(to: source.appendingPathComponent("A001.mov"))

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [dest], algorithm: .sha256,
            chunkBytes: OffloadFixtures.chunk))

        #expect(report.isFullyVerified)
        let manifest = try #require(report.destinations.first?.manifestURL)
        let xml = try String(contentsOf: manifest, encoding: .utf8)
        #expect(xml.contains("<sha256 action=\"original\">"))
        #expect(!xml.contains("<xxh64"))
        #expect(try OffloadFixtures.summaryText(#require(report.destinations.first))
            .contains("SHA-256 (sha256)"))
    }

    /// A second offload into the same folder keeps the first manifest: ASC MHL
    /// manifests are generations, not a file to overwrite.
    @Test func aSecondOffloadAddsAGenerationRatherThanReplacingOne() throws {
        let source = try OffloadFixtures.scratch("gen-src")
        let dest = try OffloadFixtures.scratch("gen-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.content(64).write(to: source.appendingPathComponent("A001.mov"))
        let plan = OffloadPlan(source: source, destinations: [dest],
                               chunkBytes: OffloadFixtures.chunk)

        let first = OffloadEngine.run(plan)
        let second = OffloadEngine.run(plan)

        #expect(first.destinations.first?.manifestURL?.lastPathComponent
            .hasPrefix("0001_") == true)
        #expect(second.destinations.first?.manifestURL?.lastPathComponent
            .hasPrefix("0002_") == true)
        let manifests = try FileManager.default.contentsOfDirectory(
            at: dest.appendingPathComponent("ascmhl"),
            includingPropertiesForKeys: nil)
        #expect(manifests.count == 2)
    }

    @Test func theSummaryCarriesEveryNumberTheDITIsAskedFor() throws {
        let source = try OffloadFixtures.scratch("sum-src")
        let dest = try OffloadFixtures.scratch("sum-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        try OffloadFixtures.makeCard(at: source)

        let report = OffloadEngine.run(OffloadPlan(
            source: source, destinations: [dest], chunkBytes: OffloadFixtures.chunk))

        let result = try #require(report.destinations.first)
        let text = try OffloadFixtures.summaryText(result)
        let total = OffloadFixtures.card.map(\.bytes).reduce(0, +)
        #expect(text.contains(source.path))
        #expect(text.contains(dest.path))
        #expect(text.contains("xxHash64 (xxh64)"))
        #expect(text.contains("\(OffloadFixtures.card.count) of \(OffloadFixtures.card.count) verified"))
        #expect(text.contains(OffloadFormat.grouped(Int64(total))))
        #expect(text.contains("MB/s"))
        #expect(text.contains(OffloadFormat.timestamp(report.run.span.started)))
        #expect(text.contains("VERDICT: all \(OffloadFixtures.card.count) files verified"))
        // The manifest is named in the summary, so one file leads to the other.
        #expect(text.contains(try #require(result.manifestURL).lastPathComponent))
    }
}
