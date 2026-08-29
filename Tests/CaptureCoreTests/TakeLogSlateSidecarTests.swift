import Foundation
import Testing

@testable import CaptureCore

/// The creative sidecar (`takeshot-slate.csv`) and the two things it must never
/// disturb: the FROZEN Resolve schema next to it, and the ALE's column
/// contract.
struct TakeLogSlateSidecarTests {
    private func makeTake(name: String, clip: Int,
                          _ configure: (inout Take) -> Void = { _ in }) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/x/\(name)"),
                        scene: "", roll: "001", takeNumber: clip,
                        startTimecode: nil, durationSeconds: 4,
                        recordedAt: Date(timeIntervalSince1970: 0))
        configure(&take)
        return take
    }

    // MARK: - the frozen schema, restated

    /// The Resolve CSV's header is the contract Media Pool → Import Metadata is
    /// mapped against. The creative fields went into their own sidecar rather
    /// than into four more columns precisely so this line cannot move — pinned
    /// here as well as in `TakeLogExporterTests`, because a second writer now
    /// exists and the temptation to "just add a column" is what this guards.
    @Test func theResolveSchemaIsUnchangedByTheCreativeFields() {
        let take = makeTake(name: "A001C01.mov", clip: 1) {
            $0.slate = SlateMetadata(scene: "12A", shot: 2, take: 3)
            $0.logDescription = "wide on the door"
            $0.comment = "hero"
            $0.rating = .good
        }
        let lines = TakeLogExporter.resolveCSV(takes: [take])
            .split(separator: "\n").map(String.init)
        #expect(lines[0] == "File Name,Reel Name,Take,Good Take,Comments")
        #expect(lines[0] == TakeLogExporter.resolveCSVHeader)
        #expect(lines[1].split(separator: ",").count == 5)
        // the Take column carries the SLATE's number, not the clip counter
        #expect(lines[1] == "A001C01.mov,001,3,true,hero")
        // and nothing creative leaked into it
        #expect(!lines[1].contains("wide on the door"))
        #expect(!lines[1].contains("12A"))
    }

    /// With no slate the Take column is the clip counter, exactly as every
    /// build before this feature wrote it.
    @Test func anUnslatedTakeStillExportsItsClipNumber() {
        let csv = TakeLogExporter.resolveCSV(
            takes: [makeTake(name: "A001C07.mov", clip: 7)])
        #expect(csv.contains("A001C07.mov,001,7,,"))
    }

    // MARK: - the sidecar itself

    @Test func theSidecarRoundTripsEveryCreativeField() {
        let takes = [
            makeTake(name: "A001C01.mov", clip: 1) {
                $0.slate = SlateMetadata(scene: "12A", shot: 2, take: 3)
                $0.logDescription = "wide on the door, then push in"
            },
            makeTake(name: "A001C02.mov", clip: 2) {
                $0.slate = SlateMetadata(scene: "12A", take: 4)
            },
            // description with no slate at all is still the operator's work
            makeTake(name: "A001C03.mov", clip: 3) {
                $0.logDescription = "pickup"
            },
        ]
        let csv = TakeLogExporter.slateCSV(takes: takes)
        #expect(csv.split(separator: "\n").first
                == "File Name,Scene,Shot,Take,Description")
        // a comma in a description has to survive as one field
        #expect(csv.contains(
            "A001C01.mov,12A,2,3,\"wide on the door, then push in\""))

        let parsed = TakeLogExporter.parseSlates(csv: csv)
        #expect(parsed["A001C01.mov"] == .init(
            slate: SlateMetadata(scene: "12A", shot: 2, take: 3),
            logDescription: "wide on the door, then push in"))
        #expect(parsed["A001C02.mov"] == .init(
            slate: SlateMetadata(scene: "12A", take: 4)))
        #expect(parsed["A001C03.mov"] == .init(logDescription: "pickup"))
    }

    /// Rows are written in file-name order so two runs over the same day
    /// produce the same bytes — a sidecar that reshuffles itself is noise in
    /// the DIT's rsync log.
    @Test func rowsAreWrittenInFileNameOrder() {
        let takes = ["C.mov", "A.mov", "B.mov"].enumerated().map { index, name in
            makeTake(name: name, clip: index + 1) { $0.scene = "1" }
        }
        let names = TakeLogExporter.slateCSV(takes: takes)
            .split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",")[0] }
        #expect(names == ["A.mov", "B.mov", "C.mov"])
    }

    /// A take with nothing logged contributes no row, and a day with nothing
    /// logged has its sidecar REMOVED — a stale file would restore a slate the
    /// operator has just cleared.
    @Test func aDayWithNoCreativeMetadataLeavesNoSidecar() throws {
        let directory = TestMedia.scratchDirectory("slate-sidecar")
        defer { try? FileManager.default.removeItem(at: directory) }
        let slated = makeTake(name: "A.mov", clip: 1) { $0.scene = "12" }

        let url = try TakeLogExporter.writeSlates(takes: [slated],
                                                  toDirectory: directory)
        #expect(url.lastPathComponent == "takeshot-slate.csv")
        #expect(FileManager.default.fileExists(atPath: url.path))

        _ = try TakeLogExporter.writeSlates(
            takes: [makeTake(name: "A.mov", clip: 1)], toDirectory: directory)
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "an emptied day kept its sidecar")
    }

    /// The file is plain text in a record folder and gets hand-edited in
    /// Excel: one broken row must not cost the day's other slates, and a Take
    /// cell that is not a positive number must read as "not logged" rather
    /// than as take 0.
    @Test func aMangledRowDropsItselfAndKeepsTheRest() {
        let parsed = TakeLogExporter.parseSlates(csv: """
            File Name,Scene,Shot,Take,Description
            good.mov,12,A,3,fine
            short.mov,12,A
            ,12,A,3,no name
            zero.mov,14,,0,
            junk.mov,15,,not a number,
            """)
        #expect(parsed.count == 3)
        #expect(parsed["good.mov"]?.slate.take == 3)
        #expect(parsed["short.mov"] == nil)
        #expect(parsed["zero.mov"]?.slate == SlateMetadata(scene: "14"))
        #expect(parsed["junk.mov"]?.slate == SlateMetadata(scene: "15"))
    }

    // MARK: - the ALE's creative columns

    /// The scripty's fields have to reach the Avid under the names Avid and
    /// Resolve use, or the assistant maps them by hand — which is the work
    /// this file exists to remove.
    @Test func theALECarriesSceneShotAndDescription() throws {
        let take = makeTake(name: "A001C01.mov", clip: 1) {
            $0.slate = SlateMetadata(scene: "12A", shot: 2, take: 3)
            $0.logDescription = "wide on the door"
        }
        let ale = try #require(ALEExporter.ale(takes: [take]))
        let lines = ale.components(separatedBy: "\r\n")
        let columns = try #require(lines.first { $0.hasPrefix("Name\t") })
            .components(separatedBy: "\t")
        let row = try #require(lines.first { $0.hasPrefix("A001C01.mov") })
            .components(separatedBy: "\t")

        for (name, expected) in [("Take", "3"), ("Scene", "12A"),
                                 ("Shot", "2"),
                                 ("Description", "wide on the door")] {
            let index = try #require(columns.firstIndex(of: name),
                                     "the ALE lost its \(name) column")
            #expect(row[index] == expected, "\(name) column")
        }
    }
}
