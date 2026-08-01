import Foundation
import Testing
@testable import CaptureCore

/// The markers sidecar: what a row on disk says, and what comes back off it.
///
/// Its own suite rather than more of `TakeLogExporterTests`: that file is the
/// Resolve metadata CSV and its round trip, this one is a different file on
/// disk with its own columns, its own lifecycle and its own history of column
/// changes — and the two together outgrew the size at which anyone reads a type
/// top to bottom.
struct TakeLogMarkerSidecarTests {
    private static let startTC = Timecode(hours: 10, minutes: 0, seconds: 0,
                                          frames: 0, fps: 25)

    private func makeTake(name: String, scene: String, number: Int,
                          startTimecode: Timecode? = nil,
                          markers: [TakeMarker] = []) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/x/\(name)"),
                        scene: scene, takeNumber: number,
                        startTimecode: startTimecode, durationSeconds: 10,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.markers = markers
        return take
    }

    /// The Seconds column is gone: the timecode is the position, and two
    /// records of one value drifted apart.
    @Test func markersCSVCarriesTheTimecodeAndNoSecondsColumn() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC,
                            markers: [TakeMarker(seconds: 1.5,
                                                 timecodeText: "10:00:01:12",
                                                 color: "red", note: "focus")])
        let lines = TakeLogExporter.markersCSV(takes: [take])
            .split(separator: "\n").map(String.init)
        #expect(lines[0] == "File Name,Timecode,Color,Note")
        #expect(lines[1] == "A.mov,10:00:01:12,red,focus")
    }

    /// The sidecar is keyed by file name, so it can carry a clip that is not a
    /// take at all — one that landed in the record folder from a card (owner
    /// item 24). Such a clip has no start timecode to anchor against, so its
    /// rows are offsets from zero, and they sort by name after the takes so two
    /// runs over the same marks produce the same file.
    @Test func theSidecarAlsoCarriesClipsThatAreNotTakes() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC,
                            markers: [TakeMarker(seconds: 1.5,
                                                 timecodeText: "10:00:01:12")])
        let lines = TakeLogExporter.markersCSV(takes: [take], other: [
            "card_B.mov": [TakeMarker(seconds: 2, color: "red", note: "gate")],
            "card_A.mov": [TakeMarker(seconds: 0.4)],
        ]).split(separator: "\n").map(String.init)

        #expect(lines[1] == "A.mov,10:00:01:12,orange,")
        #expect(lines[2] == "card_A.mov,00:00:00:10,orange,")
        #expect(lines[3] == "card_B.mov,00:00:02:00,red,gate")
    }

    /// …and those rows resolve back onto the clip's own zero, which is the same
    /// arithmetic a take with no readable start timecode uses.
    @Test func aNonTakeClipsMarkersRoundTrip() {
        let csv = TakeLogExporter.markersCSV(takes: [], other: [
            "card_A.mov": [TakeMarker(seconds: 0.4, color: "red", note: "gate"),
                           TakeMarker(seconds: 2)],
        ])
        let rows = TakeLogExporter.parseMarkerRows(csv: csv)
        let restored = TakeLogExporter.markers(rows["card_A.mov"] ?? [],
                                               startingAt: nil, duration: 0)
        #expect(restored.map(\.seconds) == [0.4, 2])
        #expect(restored.map(\.color) == ["red", "orange"])
        #expect(restored.first?.note == "gate")
    }

    /// The file is deleted when nothing has a marker left — and "nothing" has to
    /// count the non-take clips too, or a folder whose only marks were on a card
    /// clip would keep writing them into a sidecar it thinks is empty.
    @Test func theSidecarIsWrittenAndRemovedForNonTakeClipsToo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Markers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        let url = try TakeLogExporter.writeMarkers(
            takes: [], other: ["card_A.mov": [TakeMarker(seconds: 1)]],
            toDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: url.path))

        _ = try TakeLogExporter.writeMarkers(takes: [], other: ["card_A.mov": []],
                                             toDirectory: dir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A marker is one frame of the take, so the offset comes back quantized to
    /// that frame — and stays there on every later export.
    @Test func markersRoundTripThroughTheirTimecode() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC,
                            markers: [
                                TakeMarker(seconds: 0.48,
                                           timecodeText: "10:00:00:12"),
                                TakeMarker(seconds: 3.24,
                                           timecodeText: "10:00:03:06",
                                           color: "green", note: "flare"),
                            ])
        let rows = TakeLogExporter.parseMarkerRows(
            csv: TakeLogExporter.markersCSV(takes: [take]))
        let restored = TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
        #expect(restored.count == 2)
        #expect(restored.map(\.seconds) == [0.48, 3.24])
        #expect(restored.map(\.timecodeText) == ["10:00:00:12", "10:00:03:06"])
        #expect(restored.map(\.color) == ["orange", "green"])
        #expect(restored[1].note == "flare")
    }

    /// A marker flagged while recording a source with no timecode has no text
    /// of its own. With the Seconds column gone the writer has to derive one,
    /// or the marker is lost.
    @Test func aMarkerWithoutTimecodeTextGetsOneDerivedFromTheTake() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC,
                            markers: [TakeMarker(seconds: 2)])
        let csv = TakeLogExporter.markersCSV(takes: [take])
        #expect(csv.contains("A.mov,10:00:02:00,orange,"))
        let rows = TakeLogExporter.parseMarkerRows(csv: csv)
        let restored = TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
        #expect(restored.map(\.seconds) == [2])
    }

    /// A take with no start timecode cannot anchor an absolute one, so its
    /// markers are written as offsets from zero even when they have a camera
    /// timecode of their own — the case is real: manual record on a source whose
    /// timecode only starts arriving after the take has begun. Written out as
    /// "10:00:05:00" the marker reads back ten hours past the end of the take.
    @Test func aTakeWithoutAStartTimecodeStoresItsMarkersAsOffsets() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            markers: [TakeMarker(seconds: 2,
                                                 timecodeText: "10:00:05:00")])
        let csv = TakeLogExporter.markersCSV(takes: [take])
        #expect(csv.contains("A.mov,00:00:02:00,orange,"))
        let rows = TakeLogExporter.parseMarkerRows(csv: csv)
        #expect(TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
                    .map(\.seconds) == [2])
    }

    /// The same mismatch the other way round: a sidecar written while the take
    /// still had a start timecode, read back after the file lost its timecode
    /// track. The absolute timecode resolves hours outside a ten-second take, so
    /// an old file's Seconds column is preferred over it.
    @Test func aMarkerThatCanNoLongerBeAnchoredFallsBackToSeconds() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1)
        let rows = TakeLogExporter.parseMarkerRows(csv: """
            File Name,Seconds,Timecode,Color,Note
            A.mov,2.000,10:00:05:00,orange,handheld
            """)
        let restored = TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
        #expect(restored.map(\.seconds) == [2])
        #expect(restored.first?.note == "handheld")
    }

    /// With no Seconds column to fall back on there is nothing to recover, and a
    /// marker ten hours past the end of the take is worse than no marker: it
    /// cannot be seen, cannot be reached, and is written out again every export.
    @Test func anUnanchorableMarkerWithNoFallbackIsDropped() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1)
        let rows = TakeLogExporter.parseMarkerRows(csv: """
            File Name,Timecode,Color,Note
            A.mov,10:00:05:00,orange,
            A.mov,00:00:03:00,red,
            """)
        #expect(rows["A.mov"]?.count == 2)
        #expect(TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
                    .map(\.seconds) == [3])
    }

    /// Sidecars written before the column change still have Seconds in them,
    /// and a shift that spans an app update must not lose its markers.
    @Test func anOlderSidecarWithASecondsColumnStillParses() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC)
        let csv = """
            File Name,Seconds,Timecode,Color,Note
            A.mov,1.500,10:00:01:12,red,focus
            A.mov,0.040,10:00:00:01,orange,
            """
        let rows = TakeLogExporter.parseMarkerRows(csv: csv)
        let restored = TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
        #expect(restored.map(\.timecodeText) == ["10:00:00:01", "10:00:01:12"])
        #expect(restored.map(\.color) == ["orange", "red"])
        #expect(restored.last?.note == "focus")
    }

    /// A take that rolled through midnight ends on a smaller timecode than it
    /// started on; its markers must not land before the take.
    @Test func markersOnATakeThatCrossedMidnightStayInsideIt() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Timecode(hours: 23, minutes: 59,
                                                    seconds: 58, frames: 0,
                                                    fps: 25))
        #expect(TakeLogExporter.markerSeconds(timecodeText: "00:00:01:00",
                                              start: take.startTimecode) == 3)
    }

    /// A marker flagged while recording a source with no timecode had nothing in
    /// the old sidecar's Timecode cell — its Seconds column was the only record
    /// of where it was, so reading one carries it over instead of dropping it.
    /// Written back, it gets a derived timecode like any other.
    @Test func anOldSidecarKeepsAMarkerThatNeverHadATimecode() {
        var take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC)
        let rows = TakeLogExporter.parseMarkerRows(csv: """
            File Name,Seconds,Timecode,Color,Note
            A.mov,2.000,,orange,handheld
            """)
        take.markers = TakeLogExporter.markers(rows["A.mov"] ?? [], of: take)
        #expect(take.markers.map(\.seconds) == [2])
        #expect(take.markers.first?.note == "handheld")

        let rewritten = TakeLogExporter.markersCSV(takes: [take])
        #expect(rewritten.contains("A.mov,10:00:02:00,orange,handheld"))
    }

    /// A row whose timecode is junk is dropped rather than landing on frame
    /// zero, where it would sit under the head of every take.
    @Test func anUnparsableMarkerRowIsDroppedNotZeroed() {
        let take = makeTake(name: "A.mov", scene: "1", number: 1,
                            startTimecode: Self.startTC)
        let rows = TakeLogExporter.parseMarkerRows(csv: """
            File Name,Timecode,Color,Note
            A.mov,not-a-timecode,red,
            A.mov,10:00:01:00,red,
            """)
        #expect(rows["A.mov"]?.count == 2)
        #expect(TakeLogExporter.markers(rows["A.mov"] ?? [], of: take).count == 1)
    }
}
