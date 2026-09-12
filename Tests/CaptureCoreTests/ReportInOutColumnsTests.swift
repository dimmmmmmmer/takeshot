import Foundation
import Testing

@testable import CaptureCore

/// **The in/out the operator marked, in the shift report's table** (owner:
/// "чтоб если был выбран ин/аут тоже писало это").
///
/// The runtime on the header is a total; these are the rows it was counted
/// from. A total on a piece of paper with nothing under it to account for it
/// is a number the production office cannot check — which is the whole reason
/// the marks reach the table at all.
@Suite struct ReportInOutColumnsTests {
    private func take(_ index: Int, duration: Double = 12) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/tmp/CLIP\(index).mov"),
            scene: "", roll: "001", takeNumber: index,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25),
            durationSeconds: duration,
            recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = .good
        return take
    }

    /// One take's row, as cells addressed by the English column name — so a
    /// column inserted anywhere cannot silently re-point an assertion.
    private func row(_ take: Take, range: ClipRange? = nil) throws -> [String: String] {
        var ranges: [String: ClipRange] = [:]
        if let range { ranges[TakeRuntime.key(take)] = range }
        let csv: String = TakeLogExporter.reportCSV(
            TakeRuntime.ReportMaterial([take], ranges: ranges))
        let records: [[String]] = TakeLogExporter.parseCSVRecords(csv)
        #expect(records.count == 2)
        let header: [String] = ShiftReportCSVLabels.english.header
        let cells: [String] = try #require(records.last)
        #expect(cells.count == header.count)
        return Dictionary(uniqueKeysWithValues: zip(header, cells))
    }

    @Test func anUnmarkedTakeLeavesTheThreeCellsEmpty() throws {
        let cells: [String: String] = try row(take(1))
        #expect(cells["In"] == "")
        #expect(cells["Out"] == "")
        #expect(cells["Selected"] == "")
        #expect(cells["Duration"] == "00:00:12:00")
    }

    @Test func aMarkedTakeCarriesItsWindowAndItsLength() throws {
        let cells: [String: String] = try row(
            take(1), range: ClipRange(inPoint: 2, outPoint: 10))
        #expect(cells["In"] == "10:00:02:00")
        #expect(cells["Out"] == "10:00:10:00")
        #expect(cells["Selected"] == "00:00:08:00")
    }

    /// The two columns say different things on purpose — one what was rolled,
    /// the other what was kept. A report that overwrote the first with the
    /// second would lose the only record of how long the camera ran.
    @Test func theRecordedDurationIsNotOverwrittenByTheMark() throws {
        let cells: [String: String] = try row(
            take(1), range: ClipRange(inPoint: 2, outPoint: 10))
        #expect(cells["Duration"] == "00:00:12:00")
        #expect(cells["Start TC"] == "10:00:00:00")
        #expect(cells["End TC"] == "10:00:12:00")
    }

    /// A mark half-set is still a mark: the sidecar keeps one and the table
    /// prints the end it does know, against the take's own edge.
    @Test func aHalfSetMarkStillPrints() throws {
        let cells: [String: String] = try row(take(1), range: ClipRange(inPoint: 2))
        #expect(cells["In"] == "10:00:02:00")
        #expect(cells["Out"] == "10:00:12:00")
        #expect(cells["Selected"] == "00:00:10:00")
    }

    /// Clamped, so an out point that outlived the take it was made against
    /// cannot print past the End TC in the same row.
    @Test func aMarkPastTheEndPrintsTheClampedWindow() throws {
        let cells: [String: String] = try row(
            take(1), range: ClipRange(inPoint: 5, outPoint: 999))
        #expect(cells["Out"] == "10:00:12:00")
        #expect(cells["Selected"] == "00:00:07:00")
    }

    /// A mark that selects nothing (an out at or before the in) says nothing,
    /// rather than printing a zero-length selection nobody made.
    @Test func aBrokenMarkPrintsNothing() throws {
        let cells: [String: String] = try row(
            take(1), range: ClipRange(inPoint: 10, outPoint: 2))
        #expect(cells["In"] == "")
        #expect(cells["Selected"] == "")
    }

    /// **Which shift each row belongs to** (owner: "может нам учитывать
    /// многосменность … в экспорте шифт репортов"), and nothing at all when
    /// the sheet is one shift — a column repeating one date down a page says
    /// nothing, and the sheet's own header already carries it.
    @Test func theShiftColumnNamesTheDayAndOnlyWhenThereIsMoreThanOne() throws {
        let calendar = Calendar.current
        func at(day: Int, hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9,
                                               day: day, hour: hour))
                ?? Date(timeIntervalSince1970: 0)
        }
        var night = take(1)
        night.recordedAt = at(day: 11, hour: 20)
        var after = take(2)
        after.recordedAt = at(day: 12, hour: 1)
        var later = take(3)
        later.recordedAt = at(day: 13, hour: 20)

        let header: [String] = ShiftReportCSVLabels.english.header
        #expect(header.first == "Shift", "the sort column is not first")

        let one: [[String]] = TakeLogExporter.parseCSVRecords(
            TakeLogExporter.reportCSV(
                TakeRuntime.ReportMaterial([night, after])))
        #expect(one.dropFirst().allSatisfy { $0.first == "" },
                "a single-shift sheet stamped its rows")

        let two: [[String]] = TakeLogExporter.parseCSVRecords(
            TakeLogExporter.reportCSV(
                TakeRuntime.ReportMaterial([night, after, later])))
        #expect(two.dropFirst().map { $0.first ?? "" }
            == ["2026-09-11", "2026-09-11", "2026-09-13"],
            "the night through midnight was split, or the rows re-ordered")
    }

    /// The three columns sit with the other timings rather than at the end of
    /// the row: a reader checking the marked part against what was rolled
    /// reads five cells side by side.
    @Test func theColumnsSitWithTheOtherTimings() {
        let header: [String] = ShiftReportCSVLabels.english.header
        #expect(header.firstIndex(of: "In") == header.firstIndex(of: "Duration").map { $0 + 1 })
        #expect(header.firstIndex(of: "Out") == header.firstIndex(of: "In").map { $0 + 1 })
        #expect(header.firstIndex(of: "Selected")
            == header.firstIndex(of: "Out").map { $0 + 1 })
    }
}
