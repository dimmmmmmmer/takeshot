import Foundation
import Testing
@testable import CaptureCore

struct TakeLogExporterTests {
    private func makeTake(name: String, scene: String, number: Int,
                          rating: TakeRating = .none, comment: String = "",
                          startTimecode: Timecode? = nil,
                          markers: [TakeMarker] = []) -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/x/\(name)"),
                        scene: scene, takeNumber: number,
                        startTimecode: startTimecode, durationSeconds: 10,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = rating
        take.comment = comment
        take.markers = markers
        return take
    }

    /// Resolve's Good Take column is a checkbox and the rating is ternary, so
    /// the third state is the absence of a value. A written "false" on every
    /// unmarked take told Resolve the whole day had been rejected.
    @Test func csvHasResolveColumnsAndThreeRatingStates() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "1_T01.mov", scene: "1", number: 1, rating: .good),
            makeTake(name: "1_T02.mov", scene: "1", number: 2),
            makeTake(name: "1_T03.mov", scene: "1", number: 3, rating: .bad),
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "File Name,Reel Name,Take,Good Take,Comments")
        #expect(lines[1] == "1_T01.mov,1,1,true,")
        #expect(lines[2] == "1_T02.mov,1,2,,")
        #expect(lines[3] == "1_T03.mov,1,3,false,NG")
    }

    /// The full ternary round trip: good, unmarked and bad have to come back as
    /// themselves, with their comments, through the file on disk.
    @Test func allThreeRatingStatesSurviveTheRoundTrip() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "good.mov", scene: "1", number: 1, rating: .good,
                     comment: "hero"),
            makeTake(name: "unmarked.mov", scene: "1", number: 2,
                     comment: "not watched yet"),
            makeTake(name: "bad.mov", scene: "1", number: 3, rating: .bad,
                     comment: "boom in frame"),
        ])
        let meta = TakeLogExporter.parseMetadata(csv: csv)
        #expect(meta["good.mov"] == .init(rating: .good, comment: "hero"))
        #expect(meta["unmarked.mov"]
                == .init(rating: .none, comment: "not watched yet"))
        #expect(meta["bad.mov"] == .init(rating: .bad, comment: "boom in frame"))
    }

    /// Logs written before the empty-checkbox convention say "false" for an
    /// unmarked take. Reading one must not turn the day's unmarked takes into
    /// rejected ones.
    @Test func anOlderLogWithFalseForUnmarkedStillReadsAsUnmarked() {
        let csv = """
            File Name,Reel Name,Take,Good Take,Comments
            a.mov,001,1,false,
            b.mov,001,2,false,handheld
            """
        let meta = TakeLogExporter.parseMetadata(csv: csv)
        #expect(meta["a.mov"] == .init(rating: .none, comment: ""))
        #expect(meta["b.mov"] == .init(rating: .none, comment: "handheld"))
    }

    /// NG is only ever written for a bad take, so the checkbox wins: a good
    /// take whose comment happens to start with "NG" keeps both.
    @Test func aTickedGoodTakeBeatsAnNGLookingComment() {
        let csv = """
            File Name,Reel Name,Take,Good Take,Comments
            a.mov,001,1,true,NG on the A camera
            """
        let meta = TakeLogExporter.parseMetadata(csv: csv)
        #expect(meta["a.mov"] == .init(rating: .good,
                                       comment: "NG on the A camera"))
    }

    @Test func escapesCommasAndQuotes() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "clip.mov", scene: "INT, kitchen \"day\"", number: 3),
        ])
        #expect(csv.contains("\"INT, kitchen \"\"day\"\"\""))
    }

    @Test func parseRatingsRoundTrip() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "a.mov", scene: "1", number: 1, rating: .good),
            makeTake(name: "b.mov", scene: "1", number: 2),
            makeTake(name: "c.mov", scene: "1", number: 3, rating: .bad),
        ])
        let ratings = TakeLogExporter.parseRatings(csv: csv)
        #expect(ratings["a.mov"] == .good)
        #expect(ratings["b.mov"] == nil)
        #expect(ratings["c.mov"] == .bad)
    }

    // MARK: - markers sidecar

    private static let startTC = Timecode(hours: 10, minutes: 0, seconds: 0,
                                          frames: 0, fps: 25)

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

    @Test func commentsRoundTripWithRatings() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "a.mov", scene: "1", number: 1, rating: .good,
                     comment: "hero take"),
            makeTake(name: "b.mov", scene: "1", number: 2, rating: .bad,
                     comment: "boom in frame"),
            makeTake(name: "c.mov", scene: "1", number: 3, rating: .bad),
            makeTake(name: "d.mov", scene: "1", number: 4,
                     comment: "note, with comma"),
        ])
        let meta = TakeLogExporter.parseMetadata(csv: csv)
        #expect(meta["a.mov"] == .init(rating: .good, comment: "hero take"))
        #expect(meta["b.mov"] == .init(rating: .bad, comment: "boom in frame"))
        #expect(meta["c.mov"] == .init(rating: .bad, comment: ""))
        // a comment with a comma must be quoted and survive the round trip
        #expect(meta["d.mov"] == .init(rating: .none, comment: "note, with comma"))
    }

    @Test func badTakeCommentUsesNGPrefix() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "x.mov", scene: "1", number: 1, rating: .bad,
                     comment: "soft focus"),
        ])
        let comments = csv.split(separator: "\n").map(String.init)[1]
        #expect(comments.hasSuffix("NG: soft focus"))
    }

    @Test func writesFileToDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TakeLogExporter.write(
            takes: [makeTake(name: "a.mov", scene: "2", number: 1, rating: .good)],
            toDirectory: dir)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(url.lastPathComponent == "takeshot-log.csv")
        #expect(content.contains("a.mov,2,1,true,"))
    }
}
