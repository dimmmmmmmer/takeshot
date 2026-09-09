import Foundation
import Testing

@testable import CaptureCore

/// **Where a record folder keeps its takes**, and the promise that nothing
/// already shot ever moves.
///
/// The owner asked for the folder to be split into takes and other content
/// ("чтоб у нас короче было сразу по дефолту разделение папки на другой
/// контент и тейки") and chose the variant that applies to NEW folders only.
@Suite struct CaptureLayoutTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try Data([0]).write(to: url)
    }

    @Test func aFreshFolderStartsSplit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CaptureLayout.isSplit(root))
        #expect(CaptureLayout.takesFolder(in: root).path
            == root.appendingPathComponent("Takes").path)
    }

    /// **A folder this app has recorded into keeps the flat layout.** Nothing
    /// moves and no take is reclassified — the whole of the migration story.
    @Test func anEstablishedDayIsLeftFlat() throws {
        for sidecar in ["takeshot-log.csv", "takeshot-slate.csv",
                        "takeshot-markers.csv"] {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            try touch(root.appendingPathComponent(sidecar))
            #expect(!CaptureLayout.isSplit(root),
                    Comment(rawValue: "\(sidecar) did not mark the day"))
            #expect(CaptureLayout.takesFolder(in: root).path == root.path)
        }
    }

    /// Footage at the root counts too, whoever shot it: the question is
    /// whether a shoot has started here, and takes landing somewhere new on a
    /// folder already in use is the expensive way to be wrong.
    @Test func footageAtTheRootKeepsItFlat() throws {
        for name in ["A001C001.mov", "DJI_0042.MP4", "A001C001.R3D"] {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            try touch(root.appendingPathComponent(name))
            #expect(!CaptureLayout.isSplit(root),
                    Comment(rawValue: "\(name) did not mark the folder as in use"))
        }
    }

    /// A folder Finder has been in is still an empty folder.
    @Test func aStrayDotFileIsNotADay() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent(".DS_Store"))
        try touch(root.appendingPathComponent("notes.txt"))
        #expect(CaptureLayout.isSplit(root),
                "a folder with no footage and no sidecar was called a day")
    }

    /// **`Takes/` wins over everything.** Once a folder is split it stays
    /// split, whatever else lands in the root — which is the point: the root
    /// IS the other content from then on.
    @Test func anExistingTakesFolderSettlesIt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Takes"),
            withIntermediateDirectories: true)
        try touch(root.appendingPathComponent("DJI_0042.MP4"))
        try touch(root.appendingPathComponent("takeshot-log.csv"))
        #expect(CaptureLayout.isSplit(root))
        #expect(CaptureLayout.takesFolder(in: root).path
            == root.appendingPathComponent("Takes").path)
    }

    /// A file NAMED Takes is not the folder — a check that reads the name
    /// alone would send every take of the day into a write error.
    @Test func aFileNamedTakesIsNotTheFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root.appendingPathComponent("Takes"))
        #expect(!CaptureLayout.isSplit(root),
                "a plain file called Takes was taken for the subfolder")
    }

    /// A folder that is not there yet is a fresh one, not a crash.
    @Test func aMissingFolderIsFresh() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(CaptureLayout.isSplit(missing))
    }
}

/// **The take's path goes through the layout.**
///
/// Asserted on the SOURCE rather than by building a pipeline: `takeFileURL` is
/// an instance method on a live `CapturePipeline` — a board, a writer and a
/// config — and what is worth pinning here is the one line that decides the
/// folder. The rule itself is measured above; this is the wiring, and the
/// wiring is exactly what a refactor drops.
@Suite struct CaptureLayoutWritePathTests {
    @Test func theTakePathAsksTheLayoutForItsFolder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/CaptureCore/CapturePipeline+TakeFiles.swift"),
            encoding: .utf8)
        #expect(source.contains("CaptureLayout.takesFolder(in: root)"),
                "the take path no longer goes through the layout")
        // …and nothing writes straight into the root behind its back.
        #expect(!source.contains("return root\n"),
                "a take path bypasses the layout")
    }
}
