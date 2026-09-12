import Foundation
import Testing

@testable import CaptureCore

/// **The two XML timelines with an in/out marked** — the clip is the part that
/// was chosen, the media behind it is the whole take (owner: "в самом
/// таймлайне клип кидай по ин ауту но сорс пускай остается полным. монтажер
/// просто если что сможет размотать тейк по началу или по концу").
///
/// The EDL half of this is next door in `TimelineTrimTests`; the two formats
/// here state the same two lengths in opposite ways, which is why both are
/// measured rather than one being trusted to follow the other:
///
/// | | FCPXML 1.10 | FCP7 `xmeml` |
/// | --- | --- | --- |
/// | the media | `<asset duration>` | `<file><duration>` |
/// | the part used | `asset-clip` `start` + `duration` | `<in>`/`<out>` |
/// | where a marker is measured from | the asset's source TC | frame 0 of the file |
/// | a marker outside the used part | dropped — a validator rejects it | kept — it is on the media |
///
/// Parsed rather than string-matched, for `FCPXMLExporterTests`' reason: a text
/// comparison passes on a document no NLE will open.
@Suite struct TimelineTrimXMLTests {
    private func take(_ name: String = "A001C001", seconds: Double = 10,
                      markers: [TakeMarker] = []) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/Volumes/CARD/\(name).mov"),
            scene: "1", roll: "A001", takeNumber: 1,
            startTimecode: Timecode(hours: 10, minutes: 0, seconds: 0,
                                    frames: 0, fps: 25),
            durationSeconds: seconds,
            recordedAt: Date(timeIntervalSince1970: 0))
        take.markers = markers
        return take
    }

    private func marks(_ name: String = "A001C001.mov", in start: Double,
                       out end: Double) -> [String: ClipRange] {
        [name: ClipRange(inPoint: start, outPoint: end)]
    }

    private func parse(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
    }

    private func texts(_ document: XMLDocument, _ path: String) throws -> [String] {
        try document.nodes(forXPath: path).compactMap(\.stringValue)
    }

    /// The attribute `name` of every element at `path`.
    private func attributes(_ document: XMLDocument, _ path: String,
                            _ name: String) throws -> [String] {
        try document.nodes(forXPath: path)
            .compactMap { ($0 as? XMLElement)?.attribute(forName: name)?
                .stringValue }
    }

    // MARK: - FCPXML

    /// The asset keeps the whole ten seconds — 250 frames over the frame
    /// duration's own denominator, which is how this format states a time —
    /// while the clip starts at the in point and runs the four that were
    /// marked. Ten o'clock is frame 900 000, so the asset starts there and the
    /// clip fifty frames later.
    @Test func theFCPXMLAssetStaysWholeWhileTheClipIsTheMarkedPart() throws {
        let document = try parse(try #require(FCPXMLExporter.timeline(
            takes: [take()], project: "FILM", ranges: marks(in: 2, out: 6))))
        #expect(try attributes(document, "//asset", "duration") == ["250/25s"])
        #expect(try attributes(document, "//asset", "start") == ["900000/25s"])
        #expect(try attributes(document, "//asset-clip", "duration")
            == ["100/25s"])
        #expect(try attributes(document, "//asset-clip", "start")
            == ["900050/25s"])
    }

    /// The record side closes up behind a trimmed clip: the second one sits at
    /// four seconds, where the first one ends, and not at ten.
    @Test func theFCPXMLSpineAdvancesByWhatTheClipShows() throws {
        let document = try parse(try #require(FCPXMLExporter.timeline(
            takes: [take("A"), take("B")], project: "FILM",
            ranges: marks("A.mov", in: 2, out: 6))))
        #expect(try attributes(document, "//asset-clip", "offset")
            == ["0s", "100/25s"])
        #expect(try attributes(document, "//sequence", "duration")
            == ["350/25s"])
    }

    /// Markers outside the clip are dropped, and the one inside keeps its
    /// position on the SOURCE line — frame 900 075, three seconds past ten
    /// o'clock, which is where the operator flagged it.
    @Test func markersOutsideAnFCPXMLClipAreDropped() throws {
        let flagged = take(markers: [
            TakeMarker(seconds: 1, timecodeText: "before"),
            TakeMarker(seconds: 3, timecodeText: "inside"),
            TakeMarker(seconds: 9, timecodeText: "after"),
        ])
        let document = try parse(try #require(FCPXMLExporter.timeline(
            takes: [flagged], project: "FILM", ranges: marks(in: 2, out: 6))))
        #expect(try attributes(document, "//marker", "value") == ["inside"])
        #expect(try attributes(document, "//marker", "start")
            == ["900075/25s"])
    }

    /// An unmarked day is the document it always was — the same comparison
    /// `TimelineTrimTests` makes on the EDL, and for the same reason.
    @Test func anUnmarkedDayIsTheFCPXMLItAlwaysWas() throws {
        let takes = [take("A", markers: [TakeMarker(seconds: 1,
                                                    timecodeText: "x")]),
                     take("B", seconds: 4)]
        let before = try #require(FCPXMLExporter.timeline(takes: takes,
                                                          project: "FILM"))
        let after = try #require(FCPXMLExporter.timeline(
            takes: takes, project: "FILM",
            ranges: ["A.mov": ClipRange(inPoint: 0, outPoint: 10)]))
        #expect(before == after)
    }

    // MARK: - FCP7 xmeml

    /// `<in>`/`<out>` are the marked frames, counted from frame 0 of the file;
    /// both `<duration>` elements — the clipitem's and the file's — are still
    /// the whole 250. That difference IS the handle: the editor drags either
    /// edge and the rest of the take is there.
    @Test func theXmemlClipIsTrimmedWhileTheFileStaysWhole() throws {
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take()], project: "FILM", ranges: marks(in: 2, out: 6))))
        #expect(try texts(document, "//clipitem/in") == ["50", "50"])
        #expect(try texts(document, "//clipitem/out") == ["150", "150"])
        #expect(try texts(document, "//clipitem/duration") == ["250", "250"])
        #expect(try texts(document, "//file/duration") == ["250"])
    }

    /// The record side closes up, on both tracks: picture and sound state the
    /// same positions, and the second clip butts against the first at 100.
    @Test func theXmemlTimelineAdvancesByWhatTheClipShows() throws {
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take("A"), take("B")], project: "FILM",
            ranges: marks("A.mov", in: 2, out: 6))))
        #expect(try texts(document, "//clipitem/start") == ["0", "100", "0", "100"])
        #expect(try texts(document, "//clipitem/end")
            == ["100", "350", "100", "350"])
        #expect(try texts(document, "//sequence/duration") == ["350"])
    }

    /// **Markers outside the clip are KEPT here**, unlike FCPXML next door.
    /// This format places them against the MEDIA, which the clipitem declares
    /// in full — so a note left before the in point is a legal statement about
    /// a frame the editor can still drag back to, and it is waiting there when
    /// they do.
    @Test func markersOutsideAnXmemlClipSurviveOnTheMedia() throws {
        let flagged = take(markers: [
            TakeMarker(seconds: 1, timecodeText: "before"),
            TakeMarker(seconds: 9, timecodeText: "after"),
        ])
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [flagged], project: "FILM", ranges: marks(in: 2, out: 6))))
        #expect(try texts(document, "//marker/name") == ["before", "after"])
        #expect(try texts(document, "//marker/in") == ["25", "225"])
    }

    /// An unmarked day is the document it always was.
    @Test func anUnmarkedDayIsTheXmemlItAlwaysWas() throws {
        let takes = [take("A"), take("B", seconds: 4)]
        let before = try #require(FCP7XMLExporter.timeline(takes: takes,
                                                           project: "FILM"))
        let after = try #require(FCP7XMLExporter.timeline(
            takes: takes, project: "FILM",
            ranges: ["A.mov": ClipRange(inPoint: 6, outPoint: 2)]))
        #expect(before == after)
    }
}
