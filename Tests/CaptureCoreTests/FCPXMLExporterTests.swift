import Foundation
import Testing

@testable import CaptureCore

/// **The day as a timeline that actually opens.**
///
/// Parsed rather than string-matched: an exporter test that compares text
/// passes on a document no NLE will read, and the one question here is whether
/// Resolve can open it. `XMLDocument` is the same parser the applications use,
/// so a document that does not parse fails here first.
@Suite struct FCPXMLExporterTests {
    private func take(_ name: String, start: String = "10:00:00:00",
                      fps: Int = 25, dropFrame: Bool = false,
                      rate: Double? = nil, seconds: Double = 10,
                      markers: [TakeMarker] = []) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/Volumes/CARD/\(name).mov"),
            scene: "1", roll: "A001", takeNumber: 1,
            startTimecode: Timecode(text: start, fps: fps).map {
                Timecode(hours: $0.hours, minutes: $0.minutes,
                         seconds: $0.seconds, frames: $0.frames,
                         fps: fps, isDropFrame: dropFrame)
            },
            durationSeconds: seconds, recordedAt: Date())
        take.frameRate = rate
        take.markers = markers
        return take
    }

    private func parse(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
    }

    @Test func nothingToExportIsNil() {
        #expect(FCPXMLExporter.timeline(takes: [], project: "FILM") == nil)
    }

    /// The document parses, says which version it is, and holds one clip per
    /// take in the order it was given.
    @Test func theDocumentParsesAndHoldsEveryTake() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A001C001"), take("A001C002"), take("A001C003")],
            project: "FILM"))
        let document = try parse(xml)
        let root = try #require(document.rootElement())
        #expect(root.name == "fcpxml")
        #expect(root.attribute(forName: "version")?.stringValue == "1.10")

        let clips = try document.nodes(forXPath: "//spine/asset-clip")
        #expect(clips.count == 3)
        #expect(clips.compactMap {
            ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue
        } == ["A001C001", "A001C002", "A001C003"])
    }

    /// **Every clip points at its own file.** The reason this format exists
    /// beside the EDL: the timeline opens with the picture on it instead of
    /// with a relink dialog.
    @Test func everyAssetNamesItsFile() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A001C001")], project: "FILM"))
        let reps = try parse(xml).nodes(forXPath: "//asset/media-rep")
        let src = try #require((reps.first as? XMLElement)?
            .attribute(forName: "src")?.stringValue)
        #expect(src == "file:///Volumes/CARD/A001C001.mov")
    }

    /// A path with a space and an ampersand in it survives as a URL that
    /// parses — the case that turns a document into one the NLE refuses to
    /// open at all rather than one that fails to relink.
    @Test func anAwkwardPathStillParses() throws {
        var awkward = take("clip")
        awkward.url = URL(fileURLWithPath: "/Volumes/A & B/Day 1/A001C001.mov")
        let xml = try #require(FCPXMLExporter.timeline(takes: [awkward],
                                                       project: "A & B"))
        let document = try parse(xml)
        let src = try #require((try document.nodes(forXPath: "//media-rep")
            .first as? XMLElement)?.attribute(forName: "src")?.stringValue)
        #expect(src.contains("A%20&%20B") || src.contains("A%20&amp;%20B")
            || src.contains("A%20%26%20B"),
                "the space and ampersand did not survive: \(src)")
        #expect(try #require(URL(string: src)).path
            == "/Volumes/A & B/Day 1/A001C001.mov",
                "the src does not read back as the file it names")
        // …and the project name reached the document without breaking it.
        let event = try #require(try document.nodes(forXPath: "//event")
            .first as? XMLElement)
        #expect(event.attribute(forName: "name")?.stringValue == "A & B")
    }

    /// **23.976 is written as 1001/24000, not as a decimal.** The reason the
    /// whole format is rational: a timeline built from rounded decimals drifts
    /// a frame every few minutes, and the markers land on the wrong picture.
    @Test func anNTSCRateIsWrittenAsAnExactRational() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A001C001", fps: 24, rate: 24000.0 / 1001.0)],
            project: "FILM"))
        let format = try #require((try parse(xml)
            .nodes(forXPath: "//format").first as? XMLElement))
        #expect(format.attribute(forName: "frameDuration")?.stringValue
            == "1001/24000s")
        // …and every time in the document is over that same denominator.
        for name in ["duration", "start", "offset"] {
            for node in try parse(xml).nodes(forXPath: "//@\(name)") {
                let value = node.stringValue ?? ""
                #expect(value == "0s" || value.hasSuffix("/24000s"),
                        "\(name)=\(value) is not on the frame grid")
            }
        }
    }

    /// A whole-number rate stays whole: 25 is `1/25s`, and a take at 25 must
    /// not be dragged onto the NTSC grid by a rate reading that is a hair off.
    @Test func aWholeRateIsNotDraggedOntoTheNTSCGrid() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A001C001", fps: 25, rate: 25.0)], project: "FILM"))
        let format = try #require((try parse(xml)
            .nodes(forXPath: "//format").first as? XMLElement))
        #expect(format.attribute(forName: "frameDuration")?.stringValue
            == "1/25s")
    }

    /// The clips lie back to back: each one starts where the last one ended,
    /// and the sequence is as long as the sum.
    @Test func theClipsRunBackToBackAndTheSequenceIsTheSum() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A", seconds: 10), take("B", seconds: 4)],
            project: "FILM"))
        let document = try parse(xml)
        let clips = try document.nodes(forXPath: "//spine/asset-clip")
            .compactMap { $0 as? XMLElement }
        #expect(clips.count == 2)
        #expect(clips[0].attribute(forName: "offset")?.stringValue == "0s")
        // 10 s at 25 fps = 250 frames
        #expect(clips[1].attribute(forName: "offset")?.stringValue == "250/25s")
        let sequence = try #require((try document.nodes(forXPath: "//sequence")
            .first as? XMLElement))
        #expect(sequence.attribute(forName: "duration")?.stringValue
            == "350/25s")
    }

    /// **A marker sits on the frame it was flagged on.** Measured from the
    /// asset's own source timecode, because that is where the clip's local
    /// timeline starts — a marker written from zero is wrong by exactly the
    /// take's start TC, which on a 10:00:00:00 roll is ten hours.
    @Test func aMarkerLandsOnTheFrameItWasFlaggedOn() throws {
        let flagged = take("A001C001", start: "10:00:00:00",
                           markers: [TakeMarker(seconds: 2, note: "focus")])
        let xml = try #require(FCPXMLExporter.timeline(takes: [flagged],
                                                       project: "FILM"))
        let marker = try #require((try parse(xml)
            .nodes(forXPath: "//asset-clip/marker").first as? XMLElement))
        // 10:00:00:00 at 25 fps is 900_000 frames; two seconds in is +50.
        #expect(marker.attribute(forName: "start")?.stringValue
            == "\(900_000 + 50)/25s")
        #expect(marker.attribute(forName: "value")?.stringValue == "focus")
        #expect(marker.attribute(forName: "duration")?.stringValue == "1/25s")
    }

    /// A take with no timecode at all still exports, from zero — the manual
    /// take on a source that carries none.
    @Test func aTakeWithoutTimecodeStartsAtZero() throws {
        var bare = take("A001C001")
        bare.startTimecode = nil
        let xml = try #require(FCPXMLExporter.timeline(takes: [bare],
                                                       project: "FILM"))
        let asset = try #require((try parse(xml).nodes(forXPath: "//asset")
            .first as? XMLElement))
        #expect(asset.attribute(forName: "start")?.stringValue == "0s")
    }

    /// A take shorter than one frame is still a clip. A zero-length clip is
    /// one Resolve drops from the timeline without saying so, which is the
    /// worst way for a take to go missing: the file is there, the timeline is
    /// not, and nothing said anything.
    @Test func aVeryShortTakeIsStillAClip() throws {
        let xml = try #require(FCPXMLExporter.timeline(
            takes: [take("A001C001", seconds: 0.001)], project: "FILM"))
        let clip = try #require((try parse(xml)
            .nodes(forXPath: "//asset-clip").first as? XMLElement))
        #expect(clip.attribute(forName: "duration")?.stringValue == "1/25s")
    }
}
