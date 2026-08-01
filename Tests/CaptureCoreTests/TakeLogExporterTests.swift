import Foundation
import Testing
@testable import CaptureCore

/// The Resolve metadata CSV and its round trip. The markers sidecar next to it
/// on disk has its own suite, `TakeLogMarkerSidecarTests`.
struct TakeLogExporterTests {
    private func makeTake(name: String, scene: String, number: Int,
                          rating: TakeRating = .none,
                          comment: String = "") -> Take {
        var take = Take(url: URL(fileURLWithPath: "/tmp/x/\(name)"),
                        scene: scene, takeNumber: number,
                        startTimecode: nil, durationSeconds: 10,
                        recordedAt: Date(timeIntervalSince1970: 0))
        take.rating = rating
        take.comment = comment
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
        #expect(lines[3] == "1_T03.mov,1,3,false,Bad")
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

    /// The marker is only ever written for a bad take, so the checkbox wins: a
    /// good take whose comment happens to start with the marker word keeps both.
    /// Checked for the spelling this build writes AND the one it still reads.
    @Test(arguments: ["Bad", "NG"])
    func aTickedGoodTakeBeatsAMarkerLookingComment(marker: String) {
        let csv = """
            File Name,Reel Name,Take,Good Take,Comments
            a.mov,001,1,true,\(marker) on the A camera
            """
        let meta = TakeLogExporter.parseMetadata(csv: csv)
        #expect(meta["a.mov"] == .init(rating: .good,
                                       comment: "\(marker) on the A camera"))
    }

    /// The rename is write-only. Every log written before it says "NG", those
    /// files are sitting in record folders on set drives, and a shift that
    /// reopens one has to get its rejected takes back as rejected — reading only
    /// the new spelling would quietly turn the day unrated.
    @Test func aLogWrittenWithTheOldNGMarkerStillRestoresItsRatings() {
        let meta = TakeLogExporter.parseMetadata(csv: """
            File Name,Reel Name,Take,Good Take,Comments
            old_bare.mov,001,1,false,NG
            old_noted.mov,001,2,false,NG: boom in frame
            new_bare.mov,001,3,false,Bad
            new_noted.mov,001,4,false,Bad: boom in frame
            """)
        #expect(meta["old_bare.mov"] == .init(rating: .bad, comment: ""))
        #expect(meta["old_noted.mov"] == .init(rating: .bad,
                                               comment: "boom in frame"))
        #expect(meta["new_bare.mov"] == .init(rating: .bad, comment: ""))
        #expect(meta["new_noted.mov"] == .init(rating: .bad,
                                               comment: "boom in frame"))
    }

    /// …and what a restored old log writes back is the NEW spelling, so a folder
    /// converts itself the first time anything in it is touched rather than
    /// carrying two conventions for the rest of the shoot.
    @Test func anOldLogIsRewrittenWithTheNewMarker() throws {
        let meta = TakeLogExporter.parseMetadata(csv: """
            File Name,Reel Name,Take,Good Take,Comments
            a.mov,001,1,false,NG: soft focus
            """)
        let restored = try #require(meta["a.mov"])
        var take = makeTake(name: "a.mov", scene: "001", number: 1,
                            rating: restored.rating, comment: restored.comment)
        take.roll = "001"
        let rewritten = TakeLogExporter.resolveCSV(takes: [take])
        #expect(rewritten.contains("a.mov,001,1,false,Bad: soft focus"))
        #expect(!rewritten.contains("NG"))
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

    @Test func badTakeCommentUsesTheBadPrefix() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "x.mov", scene: "1", number: 1, rating: .bad,
                     comment: "soft focus"),
        ])
        let comments = csv.split(separator: "\n").map(String.init)[1]
        #expect(comments.hasSuffix("Bad: soft focus"))
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
