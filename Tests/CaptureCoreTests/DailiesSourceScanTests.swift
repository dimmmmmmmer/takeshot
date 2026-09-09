import Foundation
import Testing

@testable import CaptureCore

/// **What a folder of footage offers a dailies run.**
///
/// The honest answer is not "every video file": this path reads through
/// `AVAssetReader`, and a camera RAW clip is a different decode entirely. A
/// scan says which files it can take and which it is leaving, so a run does
/// not queue forty items that each fail with a message about a reader.
@Suite struct DailiesSourceScanTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    @Test func aFolderOffersWhatThisPathCanRead() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A001C001.mov", "A001C002.MP4", "notes.txt",
                     "A001C003.r3d", "A001C004.braw", "A001C005.mxf"] {
            try touch(root.appendingPathComponent(name))
        }
        let found = DailiesSourceScan.scan(root)
        #expect(found.files.map(\.lastPathComponent)
            == ["A001C001.mov", "A001C002.MP4", "A001C005.mxf"])
        #expect(found.skippedRaw.map(\.lastPathComponent)
            == ["A001C003.r3d", "A001C004.braw"])
    }

    /// A card is a tree, and so is a day's shuttle drive.
    @Test func theWalkGoesDownIntoTheCardsTree() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("DCIM/100MEDIA/C0001.mov"))
        try touch(root.appendingPathComponent("DCIM/101MEDIA/C0002.mov"))
        let found = DailiesSourceScan.scan(root)
        #expect(found.files.count == 2, "the walk stayed at the top")
    }

    /// **Name order, always.** A day is read in name order by everyone who
    /// receives it, and a queue that runs in a different order every time is a
    /// queue nobody can follow in the status line.
    @Test func theQueueIsInNameOrder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["C0003.mov", "C0001.mov", "C0002.mov"] {
            try touch(root.appendingPathComponent(name))
        }
        #expect(DailiesSourceScan.scan(root).files.map(\.lastPathComponent)
            == ["C0001.mov", "C0002.mov", "C0003.mov"])
    }

    /// Two sources that overlap — a card and the shuttle it was copied to —
    /// contribute one item, not two. A daily written twice under one name is a
    /// `_2` nobody asked for.
    @Test func aFileFoundTwiceIsQueuedOnce() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("CARD")
        try touch(inner.appendingPathComponent("C0001.mov"))
        let merged = DailiesSourceScan.scan([root, inner])
        #expect(merged.files.count == 1,
                "the same file was queued twice: \(merged.files)")
    }

    @Test func aFolderThatIsNotThereIsEmptyRatherThanFatal() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DailiesSourceScan.scan(missing).isEmpty)
        #expect(DailiesSourceScan.scan([missing]).isEmpty)
    }

    /// The two sets do not overlap, or a file would be both offered and
    /// skipped — and which one won would be an ordering accident.
    @Test func nothingIsBothTranscodableAndRaw() {
        #expect(DailiesSourceScan.transcodable
            .isDisjoint(with: DailiesSourceScan.cameraRaw))
    }
}

/// **A finished daily on every shelf** (owner: "и так же несколько источников
/// дестинейшна, ну мало ли что").
///
/// Copied and not encoded again: a second encode would double the cost of the
/// whole batch to produce a byte-identical file, on a machine shared with a
/// capture path that must not be made to wait.
@Suite struct DailiesExtraDestinationTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-dest-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func theDailyLandsOnEveryExtraShelf() throws {
        let first = try scratch("a")
        let second = try scratch("b")
        let third = try scratch("c")
        defer {
            for url in [first, second, third] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let file = first.appendingPathComponent("A001C001_DAILY.mp4")
        try Data([1, 2, 3]).write(to: file)

        let failures = DailiesEngine.copy(file, into: [second, third])
        #expect(failures.isEmpty, "\(failures)")
        for folder in [second, third] {
            let landed = folder.appendingPathComponent("A001C001_DAILY.mp4")
            #expect(FileManager.default.fileExists(atPath: landed.path),
                    "nothing reached \(folder.lastPathComponent)")
            #expect(try Data(contentsOf: landed) == Data([1, 2, 3]))
        }
    }

    /// A folder that is not there yet is created — a destination saved last
    /// week whose subfolder nobody has made is the normal case.
    @Test func aMissingFolderIsCreated() throws {
        let source = try scratch("src")
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("x.mp4")
        try Data([9]).write(to: file)
        let target = source.appendingPathComponent("deeper/still")
        #expect(DailiesEngine.copy(file, into: [target]).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("x.mp4").path))
    }

    /// **A shelf that refuses costs that copy and nothing else.** The daily
    /// exists; an item failed over a second destination would be a report
    /// saying the footage has no daily when it has one.
    @Test func aDeadShelfIsNamedAndTheRestStillGetTheFile() throws {
        let source = try scratch("src2")
        let good = try scratch("good")
        defer {
            for url in [source, good] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let file = source.appendingPathComponent("y.mp4")
        try Data([7]).write(to: file)
        let dead = URL(fileURLWithPath: "/nonexistent-volume-\(UUID().uuidString)/x")

        let failures = DailiesEngine.copy(file, into: [dead, good])
        #expect(failures.count == 1, "\(failures)")
        #expect(FileManager.default.fileExists(
            atPath: good.appendingPathComponent("y.mp4").path),
                "the live shelf was skipped because a dead one came first")
    }

    /// A name already on the shelf gets the app's `_2`, never a clobber: two
    /// cards with the same clip numbering is the normal case.
    @Test func anExistingNameIsNotClobbered() throws {
        let source = try scratch("src3")
        let shelf = try scratch("shelf")
        defer {
            for url in [source, shelf] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let file = source.appendingPathComponent("C0001_DAILY.mp4")
        try Data([1]).write(to: file)
        try Data([2]).write(to: shelf.appendingPathComponent("C0001_DAILY.mp4"))

        #expect(DailiesEngine.copy(file, into: [shelf]).isEmpty)
        #expect(try Data(contentsOf: shelf
            .appendingPathComponent("C0001_DAILY.mp4")) == Data([2]),
                "the file already there was overwritten")
        let names = try FileManager.default
            .contentsOfDirectory(atPath: shelf.path).sorted()
        #expect(names.count == 2, "\(names)")
    }
}
