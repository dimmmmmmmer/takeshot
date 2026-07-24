import Foundation
import Testing

@testable import CaptureCore

@Suite struct EDLExporterTests {
    private func makeTake(name: String, roll: String = "001",
                          tc: Timecode?, duration: Double,
                          markers: [TakeMarker] = []) -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/\(name)"), displayName: name,
             scene: "", roll: roll, takeNumber: 1, startTimecode: tc,
             durationSeconds: duration, rating: .good, comment: "",
             recordedAt: Date(), markers: markers)
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
        #expect(edl.contains("* LOC: 01:00:01:00 ORANGE 10:00:01:00"))
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

    @Test func markersCSVRoundTrip() {
        let take = makeTake(
            name: "A.mov", tc: nil, duration: 5,
            markers: [
                TakeMarker(seconds: 0.5, timecodeText: "01:00:00:12"),
                TakeMarker(seconds: 3.25, timecodeText: "01:00:03:06"),
            ])
        let csv = TakeLogExporter.markersCSV(takes: [take])
        let parsed = TakeLogExporter.parseMarkers(csv: csv)
        #expect(parsed["A.mov"]?.count == 2)
        #expect(parsed["A.mov"]?.first?.seconds == 0.5)
        #expect(parsed["A.mov"]?.last?.timecodeText == "01:00:03:06")
    }
}
