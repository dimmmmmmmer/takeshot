import Foundation
import Testing

@testable import CaptureCore

/// What operator text does to the deliverables that are not CSV: the Avid log,
/// the conform, the hash manifest and the names on disk. Each escapes
/// differently and two of them cannot escape at all, so each is asked the same
/// question separately — see `AwkwardText`.
@Suite struct DeliverableInjectionTests {
    // MARK: - ALE: tab-delimited, no quoting mechanism at all

    /// A tab shifts every later column of the row and a newline splits the clip
    /// in two, and ALE has no way to escape either — so the writer replaces
    /// them. Twelve columns, every value in the corpus, in every free-text cell
    /// at once.
    @Test func everyALEDataRowHasTwelveColumns() throws {
        // pathSafe because the value below also becomes a file NAME, where a
        // NUL reaches Foundation's URL escaping rather than this writer (see
        // AwkwardText.pathSafe). Every free-text CELL still gets the whole
        // corpus, which is what this test is about.
        for (name, value) in AwkwardText.pathSafe {
            let take: Take = AwkwardText.take(
                named: "a\(value)b.mov", roll: value, comment: value,
                scene: value, logDescription: value)
            let ale: String = try #require(ALEExporter.ale(takes: [take]),
                                           "the shift exports")
            let rows: [String] = ale.components(separatedBy: "\r\n")
                .filter { !$0.isEmpty }
            let marker: Int = try #require(rows.firstIndex(of: "Data"),
                                           "the Data section is there")
            let data: [String] = Array(rows[(marker + 1)...])
            #expect(data.count == 1,
                    "one take is one clip in the bin, not two: \(name)")
            #expect(data.first?.components(separatedBy: "\t").count
                == ALEExporter.columns.count,
                "and its row keeps one cell per column: \(name)")
        }
    }

    // MARK: - EDL: column-positional, and comments with their own syntax

    /// A CMX event is a statement on one line. A reel carrying a break ended it
    /// early and left the rest to be read as a statement of its own; a reel
    /// carrying a tab moved every column after it. Neither can be quoted, so
    /// neither reaches the file.
    @Test func everyEDLEventIsExactlyOneLine() throws {
        for (name, value) in AwkwardText.nonEmpty {
            let edl: String = try #require(EDLExporter.selectsEDL(
                takes: [AwkwardText.take(roll: value, comment: value,
                                         note: value)],
                title: value), "the selects export")
            let statements: [String] = edl.split(whereSeparator: \.isNewline)
                .map(String.init)
            #expect(statements.filter { $0.hasPrefix("001") }.count == 1,
                    "one take is one event statement: \(name)")
            let event: String = try #require(
                statements.first { $0.hasPrefix("001") }, "the event is there")
            #expect(!event.contains("\t"), "and no tab moves its columns: \(name)")
            #expect(statements.filter { $0.hasPrefix("* LOC:") }.count == 1,
                    "one marker is one locator: \(name)")
        }
    }

    /// The reel sits in an eight-wide column, and `padding(toLength:)` measures
    /// UTF-16: an eight-character reel holding emoji is thirteen units, and
    /// asking for eight cut it through a surrogate pair — a replacement
    /// character in the conform and a column that no longer lines up.
    @Test func theReelColumnIsEightCharactersWideForEveryReel() throws {
        for (name, value) in AwkwardText.nonEmpty {
            let edl: String = try #require(EDLExporter.selectsEDL(
                takes: [AwkwardText.take(roll: value)], title: "t"),
                "the selects export")
            let event: String = try #require(
                edl.split(whereSeparator: \.isNewline).map(String.init)
                    .first { $0.hasPrefix("001") }, "the event is there")
            #expect(!event.contains("\u{FFFD}"),
                    "the reel is not cut through a character: \(name)")
            // "001" + two spaces + eight columns of reel + one space + "V"
            let reelStart: String.Index = event.index(event.startIndex,
                                                      offsetBy: 5)
            let reelEnd: String.Index = event.index(reelStart, offsetBy: 8)
            #expect(event[reelEnd...].hasPrefix(" V     C"),
                    "and the columns after it still line up: \(name)")
        }
    }

    /// The Tape column of the ALE is the same reel by definition — an assistant
    /// conforming the EDL while importing the log has to see one name for one
    /// roll, and a fix to one of them that missed the other would split them.
    @Test func theALETapeIsStillTheSameReelTheEDLWrites() throws {
        for (name, value) in AwkwardText.nonEmpty {
            let take: Take = AwkwardText.take(roll: value)
            let reel: String = EDLExporter.reelName(for: take, index: 0)
            let ale: String = try #require(ALEExporter.ale(takes: [take]),
                                           "the log exports")
            #expect(ale.contains("\t\(reel)\t"),
                    "one roll, one reel name, in both files: \(name)")
        }
    }

    // MARK: - MHL: XML, and XML 1.0 cannot hold everything a card can

    /// The manifest is what makes the copy verifiable by somebody else weeks
    /// later. A file name holding a C0 control character — legal on a card,
    /// illegal in XML 1.0 — used to make the whole document unparseable, so one
    /// odd name cost the verifiability of the entire card rather than of itself.
    @Test func everyCardNameLeavesAManifestThatParses() throws {
        let root: URL = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, entry) in AwkwardText.nonEmpty.enumerated() {
            let destination: URL = root.appendingPathComponent("d\(index)",
                                                               isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let manifest: URL = try OffloadMHL.write(
                entries: [OffloadEntry(relativePath: "sub/a\(entry.value)b.mov",
                                       size: 7, hash: "aabb")],
                into: destination, algorithm: .xxh64,
                creator: OffloadCreatorInfo(toolName: "TakeShot",
                                            toolVersion: "1", hostname: "cart"),
                date: Date(timeIntervalSince1970: 0))
            let read: OffloadManifest = try OffloadManifestReader.read(manifest)
            #expect(read.entries.count == 1,
                    "the manifest still lists its one file: \(entry.name)")
        }
    }

    /// And the names that XML CAN hold come back byte for byte. A carriage
    /// return is the one that needed a character reference: XML end-of-line
    /// normalization rewrites a literal CR as LF, so the path was written
    /// faithfully and read back as a name no file has — reported by the verify
    /// pass as one file missing and another one extra.
    @Test func aNameXMLCanHoldComesBackUnchanged() throws {
        let root: URL = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let holdable: [(name: String, value: String)] =
            AwkwardText.nonEmpty.filter { entry in
                !entry.value.unicodeScalars.contains { scalar in
                    scalar.value < 0x20 && scalar != "\t" && scalar != "\n"
                        && scalar != "\r"
                }
            }
        for (index, entry) in holdable.enumerated() {
            let destination: URL = root.appendingPathComponent("e\(index)",
                                                               isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let path: String = "sub/a\(entry.value)b.mov"
            let manifest: URL = try OffloadMHL.write(
                entries: [OffloadEntry(relativePath: path, size: 7,
                                       hash: "aabb")],
                into: destination, algorithm: .xxh64,
                creator: OffloadCreatorInfo(toolName: "TakeShot",
                                            toolVersion: "1", hostname: "cart"),
                date: Date(timeIntervalSince1970: 0))
            let read: OffloadManifest = try OffloadManifestReader.read(manifest)
            #expect(read.entries.first?.relativePath == path,
                    "the path comes back as the card spelled it: \(entry.name)")
        }
    }

    private static func scratch() throws -> URL {
        let root: URL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("takeshot-mhl-injection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }
}
