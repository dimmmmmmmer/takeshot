import Foundation
import Testing
@testable import CaptureCore

struct TakeLogExporterTests {
    private func makeTake(name: String, scene: String, number: Int,
                          rating: TakeRating = .none, comment: String = "") -> Take {
        Take(url: URL(fileURLWithPath: "/tmp/x/\(name)"),
             displayName: name, scene: scene, takeNumber: number,
             startTimecode: nil, durationSeconds: 10,
             rating: rating, comment: comment, recordedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func csvHasResolveColumnsAndRatings() {
        let csv = TakeLogExporter.resolveCSV(takes: [
            makeTake(name: "1_T01.mov", scene: "1", number: 1, rating: .good),
            makeTake(name: "1_T02.mov", scene: "1", number: 2),
            makeTake(name: "1_T03.mov", scene: "1", number: 3, rating: .bad),
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "File Name,Reel Name,Take,Good Take,Comments")
        #expect(lines[1] == "1_T01.mov,1,1,true,")
        #expect(lines[2] == "1_T02.mov,1,2,false,")
        #expect(lines[3] == "1_T03.mov,1,3,false,NG")
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
