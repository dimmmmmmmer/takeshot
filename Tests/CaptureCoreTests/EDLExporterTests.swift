import Foundation
import Testing

@testable import CaptureCore

@Suite struct EDLExporterTests {
    private func makeTake(name: String, roll: String = "001",
                          tc: Timecode?, duration: Double,
                          markers: [TakeMarker] = []) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/\(name)"),
                        scene: "", roll: roll, takeNumber: 1, startTimecode: tc,
                        durationSeconds: duration, recordedAt: Date())
        take.rating = .good
        take.markers = markers
        return take
    }

    @Test func emptySelectsReturnNil() {
        #expect(EDLExporter.selectsEDL(takes: [], title: "t") == nil)
    }

    @Test func eventLineUsesSourceAndRecordTC() throws {
        let take = makeTake(
            name: "A_001C001.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 2)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(edl.contains(
            "001  001      V     C        10:00:00:00 10:00:02:00 01:00:00:00 01:00:02:00"))
        #expect(edl.contains("* FROM CLIP NAME: A_001C001.mov"))
    }

    @Test func markersBecomeLocatorsOnTheRecordSide() throws {
        let take = makeTake(
            name: "A.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 4,
            markers: [TakeMarker(seconds: 1, timecodeText: "10:00:01:00")])
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        // YELLOW and not ORANGE: the `* LOC:` palette is Avid's eight and
        // orange is in none of them. See `EDLExporter.locatorColors`.
        #expect(edl.contains("* LOC: 01:00:01:00 YELLOW 10:00:01:00"))
    }

    // MARK: - ASC CDL

    /// A strong on-set primary, the same one the cube tests measure against.
    private static let grade = CDLLook(id: "day3_ext",
                                       slope: CDLLook.RGB(1.10, 1.00, 0.90),
                                       offset: CDLLook.RGB(0.02, 0.00, -0.03),
                                       power: CDLLook.RGB(0.95, 1.00, 1.15),
                                       saturation: 0.85)

    /// The graded EDL, byte for byte. The colourist's `ColorTrace` reads the
    /// two `*ASC_` lines off this file and applies them to the conform, so the
    /// spacing, the parentheses and the four decimals are the interface.
    ///
    /// Four decimals is the ASC's own limit — five digits of precision, chosen
    /// so all nine values fit in one 80-column CMX comment.
    @Test func theGradedEDLIsExactlyThis() throws {
        let take = makeTake(
            name: "A001C001.mov", roll: "A001",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 2,
            markers: [TakeMarker(seconds: 1, timecodeText: "10:00:01:00",
                                 color: "red", note: "focus")])
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [take], title: "day3 selects", cdl: Self.grade))
        #expect(edl == [
            "TITLE: day3 selects",
            "FCM: NON-DROP FRAME",
            "",
            "001  A001     V     C        "
                + "10:00:00:00 10:00:02:00 01:00:00:00 01:00:02:00",
            "* FROM CLIP NAME: A001C001.mov",
            "*ASC_SOP (1.1000 1.0000 0.9000)"
                + "(0.0200 0.0000 -0.0300)(0.9500 1.0000 1.1500)",
            "*ASC_SAT 0.8500",
            "* LOC: 01:00:01:00 RED focus",
            "",
        ].joined(separator: "\n") + "\n")
    }

    /// The SOP line fits the 80-column CMX comment the ASC sized it for, even
    /// with negative offsets — that is what the four decimals buy.
    @Test func theSOPLineFitsAnEightyColumnComment() throws {
        let take = makeTake(
            name: "A.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 1)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t",
                                                      cdl: Self.grade))
        let sop = try #require(edl.split(separator: "\n")
            .first { $0.hasPrefix("*ASC_SOP") })
        #expect(sop.count <= 80, "the SOP line is \(sop.count) columns")
    }

    /// No CDL means no SOP. A .cube look reaches the exporter as nil, because
    /// an identity SOP written in its place tells the colourist the day was
    /// graded flat when it was graded with a LUT the EDL cannot carry.
    @Test func aLookThatIsNotACDLGetsNoFakeSOP() throws {
        let take = makeTake(
            name: "A.mov",
            tc: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25),
            duration: 1)
        let edl = try #require(EDLExporter.selectsEDL(takes: [take], title: "t"))
        #expect(!edl.contains("ASC_SOP"))
        #expect(!edl.contains("ASC_SAT"))
    }

    /// Every event carries the grade: the look is the session's, and a conform
    /// that grades only the first clip is worse than one that grades none.
    @Test func everyEventCarriesTheGrade() throws {
        let tc = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let edl = try #require(EDLExporter.selectsEDL(
            takes: [makeTake(name: "A.mov", tc: tc, duration: 1),
                    makeTake(name: "B.mov", tc: tc, duration: 1)],
            title: "t", cdl: Self.grade))
        #expect(edl.components(separatedBy: "*ASC_SOP").count == 3)
        #expect(edl.components(separatedBy: "*ASC_SAT").count == 3)
    }

    @Test func takesCutBackToBack() throws {
        let tc = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, fps: 25)
        let takes = [
            makeTake(name: "A.mov", tc: tc, duration: 2),
            makeTake(name: "B.mov", tc: tc, duration: 3),
        ]
        let edl = try #require(EDLExporter.selectsEDL(takes: takes, title: "t"))
        // the second event starts where the first ended
        #expect(edl.contains("01:00:02:00 01:00:05:00"))
    }

    /// **Every swatch the app offers lands on a colour a conform tool reads.**
    ///
    /// The `* LOC:` convention is Avid's and so is its palette: white, red,
    /// green, blue, cyan, magenta, yellow, black. Two of the app's seven
    /// swatches — orange, which is the DEFAULT, and purple — are in none of
    /// them, and were written through verbatim. An importer that meets
    /// `ORANGE` on a line it otherwise understands drops the colour, so an
    /// assistant conforming a day of colour-coded markers sees a wall of
    /// identical locators.
    @Test func everySwatchLandsInThePaletteTheFormatHas() {
        let palette: Set<String> = ["WHITE", "RED", "GREEN", "BLUE", "CYAN",
                                    "MAGENTA", "YELLOW", "BLACK"]
        for swatch in TakeMarker.colors {
            let mapped = EDLExporter.locatorColor(for: swatch)
            #expect(palette.contains(mapped),
                    "\(swatch) became \(mapped), which is in no importer")
        }
        // Orange lands on yellow and NOT on red: red is what every set uses
        // for "do not use this one", and moving a note there would make the
        // EDL say something the operator did not.
        #expect(EDLExporter.locatorColor(for: "orange") == "YELLOW")
        #expect(EDLExporter.locatorColor(for: "purple") == "MAGENTA")
        // …and the ones that already were in the palette are untouched, so
        // this is a mapping and not a flattening.
        #expect(EDLExporter.locatorColor(for: "red") == "RED")
        #expect(EDLExporter.locatorColor(for: "cyan") == "CYAN")
    }

    /// A swatch from a palette this build does not know still draws.
    ///
    /// White rather than the word itself: a marker drawn in the wrong colour
    /// is recoverable in a way one that never appeared is not.
    @Test func anUnknownSwatchStillDrawsAsAMarker() {
        #expect(EDLExporter.locatorColor(for: "chartreuse") == "WHITE")
        #expect(EDLExporter.locatorColor(for: "") == "WHITE")
        // Case is the operator's, not the format's.
        #expect(EDLExporter.locatorColor(for: "Cyan") == "CYAN")
    }
}
