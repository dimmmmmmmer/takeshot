import Foundation
import Testing

@testable import CaptureCore

/// **The day as an `xmeml` timeline that actually opens** (owner: "таймлайн
/// хмл мне нужен .xml а не fcpxml").
///
/// Parsed rather than string-matched, for `FCPXMLExporterTests`' reason: a
/// text comparison passes on a document no NLE will read, and `XMLDocument` is
/// the same parser the applications use.
@Suite struct FCP7XMLExporterTests {
    private func take(_ name: String, start: String = "10:00:00:00",
                      fps: Int = 25, dropFrame: Bool = false,
                      rate: Double? = nil, seconds: Double = 10,
                      markers: [TakeMarker] = [],
                      recorded: Date = Date()) -> Take {
        var take = Take(
            url: URL(fileURLWithPath: "/Volumes/CARD/\(name).mov"),
            scene: "1", roll: "A001", takeNumber: 1,
            startTimecode: Timecode(text: start, fps: fps).map {
                Timecode(hours: $0.hours, minutes: $0.minutes,
                         seconds: $0.seconds, frames: $0.frames,
                         fps: fps, isDropFrame: dropFrame)
            },
            durationSeconds: seconds, recordedAt: recorded)
        take.frameRate = rate
        take.markers = markers
        return take
    }

    private func parse(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
    }

    /// The text of the first `path` under `document`.
    private func text(_ document: XMLDocument, _ path: String) throws -> String {
        let nodes: [XMLNode] = try document.nodes(forXPath: path)
        return try #require(nodes.first?.stringValue, "nothing at \(path)")
    }

    private func texts(_ document: XMLDocument, _ path: String) throws -> [String] {
        try document.nodes(forXPath: path).compactMap(\.stringValue)
    }

    @Test func nothingToExportIsNil() {
        #expect(FCP7XMLExporter.timeline(takes: [], project: "FILM") == nil)
    }

    @Test func theDocumentParsesAndHoldsEveryTake() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A001C001"), take("A001C002"), take("A001C003")],
            project: "FILM"))
        let document = try parse(xml)
        let root = try #require(document.rootElement())
        #expect(root.name == "xmeml")
        #expect(root.attribute(forName: "version")?.stringValue == "5")
        #expect(try text(document, "//sequence/name") == "FILM")
        #expect(try texts(document, "//media/video/track/clipitem/name")
            == ["A001C001", "A001C002", "A001C003"])
    }

    /// The reason this format exists beside the EDL: the timeline opens with
    /// the picture on it instead of with a relink dialog.
    @Test func everyClipPointsAtItsOwnFile() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A001C001"), take("A001C002")], project: "FILM"))
        let document = try parse(xml)
        #expect(try texts(document, "//file/pathurl")
            == ["file:///Volumes/CARD/A001C001.mov",
                "file:///Volumes/CARD/A001C002.mov"])
        #expect(try texts(document, "//file/name")
            == ["A001C001.mov", "A001C002.mov"])
    }

    /// **The sound travels with the picture.** One audio clip per take on its
    /// own track, naming track 1 of the file — the one track `TakeWriter`
    /// writes, whatever its channel width — and joined to the picture by a
    /// link group both halves carry.
    @Test func everyTakeCarriesItsSoundAndTheTwoAreLinked() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A001C001"), take("A001C002")], project: "FILM"))
        let document = try parse(xml)
        let video: [String] = try document
            .nodes(forXPath: "//media/video/track/clipitem")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        let audio: [String] = try document
            .nodes(forXPath: "//media/audio/track/clipitem")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue }
        #expect(video == ["clipitem-1", "clipitem-3"])
        #expect(audio == ["clipitem-2", "clipitem-4"])
        // the sound names the file's own first track and does not invent a
        // channel count
        #expect(try texts(document,
                          "//media/audio/track/clipitem/sourcetrack/mediatype")
            == ["audio", "audio"])
        #expect(try document.nodes(forXPath: "//channelcount").isEmpty)
        // both halves of the first take carry the same link group
        #expect(try texts(document,
                          "//clipitem[@id='clipitem-1']/link/linkclipref")
            == ["clipitem-1", "clipitem-2"])
        #expect(try texts(document,
                          "//clipitem[@id='clipitem-2']/link/linkclipref")
            == ["clipitem-1", "clipitem-2"])
    }

    /// Back to back with no gap and no overlap: each clip starts where the
    /// last one ended, which is what "the selects, in order" means.
    @Test func theClipsRunBackToBack() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", seconds: 10), take("B", seconds: 4),
                    take("C", seconds: 2.5)],
            project: "FILM"))
        let document = try parse(xml)
        // 25 fps: 250, 100, 63 frames (2.5 s rounds to 63 — half a frame up)
        #expect(try texts(document, "//media/video/track/clipitem/start")
            == ["0", "250", "350"])
        #expect(try texts(document, "//media/video/track/clipitem/end")
            == ["250", "350", "413"])
        #expect(try text(document, "//sequence/duration") == "413")
        // and the sound sits on exactly the same frames
        #expect(try texts(document, "//media/audio/track/clipitem/start")
            == ["0", "250", "350"])
    }

    /// **23.976 is a timebase of 24 with the NTSC flag**, which is how this
    /// format states a rate no decimal can. A document that said 24 would
    /// conform every clip a frame short every 41 seconds.
    @Test func anNTSCRateIsSaidAsATimebaseAndAFlag() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", fps: 24, rate: 24 * 1000 / 1001, seconds: 10)],
            project: "FILM"))
        let document = try parse(xml)
        #expect(try text(document, "//sequence/rate/timebase") == "24")
        #expect(try text(document, "//sequence/rate/ntsc") == "TRUE")
        // 10 s at 23.976 is 240 frames, not 240 at 24 — the count is the same
        // here and the RATE is what makes the conform right
        #expect(try text(document, "//media/video/track/clipitem/duration")
            == "240")
    }

    @Test func aPlainRateSaysSoJustAsPlainly() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", fps: 25)], project: "FILM"))
        let document = try parse(xml)
        #expect(try text(document, "//sequence/rate/timebase") == "25")
        #expect(try text(document, "//sequence/rate/ntsc") == "FALSE")
    }

    /// The file's own timecode, as both a string and the ordinal behind it —
    /// readers disagree about which they trust, and here they cannot disagree
    /// with each other.
    @Test func theFileCarriesItsSourceTimecodeBothWays() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", start: "10:00:00:00", fps: 25)], project: "FILM"))
        let document = try parse(xml)
        #expect(try text(document, "//file/timecode/string") == "10:00:00:00")
        #expect(try text(document, "//file/timecode/frame") == "900000")
        #expect(try text(document, "//file/timecode/displayformat") == "NDF")
    }

    @Test func aDropFrameTakeSaysDF() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", start: "10:00:00:00", fps: 30, dropFrame: true)],
            project: "FILM"))
        let document = try parse(xml)
        #expect(try text(document, "//file/timecode/displayformat") == "DF")
        #expect(try text(document, "//sequence/rate/ntsc") == "TRUE")
    }

    /// A marker is placed against the MEDIA, from frame 0 of the file — a
    /// position measured from the start timecode would land it ten hours past
    /// the end of the clip. (The FCPXML writer does the opposite, because its
    /// clip timeline starts at the asset's source timecode.)
    @Test func markersArePlacedOnTheFilesOwnFrames() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", markers: [TakeMarker(seconds: 2, note: "focus"),
                                        TakeMarker(seconds: 4)])],
            project: "FILM"))
        let document = try parse(xml)
        #expect(try texts(document, "//clipitem/marker/in") == ["50", "100"])
        #expect(try texts(document, "//clipitem/marker/out") == ["-1", "-1"])
        #expect(try texts(document, "//clipitem/marker/name").first == "focus")
    }

    /// A take of no length is one an NLE drops from the timeline without
    /// saying so, and a take that recorded a fraction of a second is still a
    /// take that happened. Same for one whose length cannot be read at all.
    @Test func noClipIsEverZeroFramesLong() throws {
        var unreadable = take("B")
        unreadable.durationSeconds = .nan
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", seconds: 0.001), unreadable], project: "FILM"))
        let document = try parse(xml)
        #expect(try texts(document, "//media/video/track/clipitem/duration")
            == ["1", "1"])
        #expect(try text(document, "//sequence/duration") == "2")
    }

    /// A path with `&` in it makes the document fail to PARSE rather than
    /// fail to relink, and the error an NLE shows for that names a line
    /// number, not a file.
    @Test func awkwardNamesSurviveTheDocument() throws {
        var take = take("A")
        take.url = URL(fileURLWithPath: "/Volumes/A&B <2>/take \"one\".mov")
        take.markers = [TakeMarker(seconds: 1, note: "a & b < c")]
        let xml = try #require(FCP7XMLExporter.timeline(takes: [take],
                                                        project: "A & B"))
        let document = try parse(xml)
        #expect(try text(document, "//sequence/name") == "A & B")
        #expect(try text(document, "//clipitem/marker/name") == "a & b < c")
        #expect(try text(document, "//file/name") == "take \"one\".mov")
    }

    /// The raster only sizes the canvas — the picture on the timeline is the
    /// file's — but a sequence with no format at all is one some readers
    /// refuse. With no device attached it falls back, like the ALE's CUSTOM.
    @Test func theSequenceAlwaysHasARaster() throws {
        let plain = try parse(try #require(
            FCP7XMLExporter.timeline(takes: [take("A")], project: "FILM")))
        #expect(try text(plain, "//sequence//format//width") == "1920")
        #expect(try text(plain, "//sequence//format//height") == "1080")
        // …and so does every file, because some readers size a clip from
        // there and a file with no raster links as a clip of no width
        #expect(try text(plain, "//file/media/video/samplecharacteristics/width")
            == "1920")
        #expect(try text(plain, "//file/media/video/samplecharacteristics/height")
            == "1080")
    }

    /// The signal's own raster when there is a device attached, on both.
    @Test func theSignalsRasterIsUsedWhenThereIsOne() throws {
        let format = CaptureFormat(width: 3840, height: 2160,
                                   frameRate: 25, timecodeFPS: 25,
                                   name: "2160p25")
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take("A")], project: "FILM", format: format)))
        #expect(try text(document, "//sequence//format//width") == "3840")
        #expect(try text(document, "//file/media/video/samplecharacteristics/height")
            == "2160")
    }

    // MARK: - a project that spans several nights

    /// A moment on the shoot, local — a shift is a wall-clock thing.
    private func at(day: Int, hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Owner: "может нам учитывать многосменность в экспорте хмл". Three
    /// nights laid end to end as one sequence is a timeline nobody asked for;
    /// `xmeml` takes several sequences, so the import arrives as three.
    @Test func aProjectAcrossTwoNightsBecomesTwoTimelines() throws {
        let xml = try #require(FCP7XMLExporter.timeline(
            takes: [take("A", recorded: at(day: 11, hour: 20)),
                    take("B", recorded: at(day: 12, hour: 1)),
                    take("C", recorded: at(day: 13, hour: 20))],
            project: "FILM"))
        let document = try parse(xml)
        let sequences: [XMLNode] = try document.nodes(forXPath: "//sequence")
        #expect(sequences.count == 2)
        #expect(try texts(document, "//sequence/name")
            == ["FILM 2026-09-11", "FILM 2026-09-13"])
        #expect(sequences.compactMap {
            ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue
        } == ["sequence-1", "sequence-2"])
        // the night through midnight kept both its takes
        #expect(try texts(document, "//sequence[1]//video/track/clipitem/name")
            == ["A", "B"])
        #expect(try texts(document, "//sequence[2]//video/track/clipitem/name")
            == ["C"])
    }

    /// One shift keeps the project's bare name — a timeline renamed with a
    /// date on every export would rename the one most days produce, for
    /// nothing.
    @Test func oneShiftKeepsTheProjectsBareName() throws {
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take("A", recorded: at(day: 12, hour: 8)),
                    take("B", recorded: at(day: 12, hour: 9))],
            project: "FILM")))
        #expect(try texts(document, "//sequence/name") == ["FILM"])
    }

    /// **Ids are unique across the DOCUMENT and clip indexes are not.** Two
    /// countings, and writing one number into both roles is how the second
    /// day's links point at the first day's clips.
    @Test func theSecondShiftsClipsAreItsOwn() throws {
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take("A", recorded: at(day: 11, hour: 20)),
                    take("B", recorded: at(day: 13, hour: 20))],
            project: "FILM")))
        let ids: [String] = try document.nodes(forXPath: "//clipitem/@id")
            .compactMap(\.stringValue)
        #expect(ids == ["clipitem-1", "clipitem-2", "clipitem-3", "clipitem-4"])
        #expect(Set(ids).count == ids.count, "two clips share an id")
        let files: [String] = try document.nodes(forXPath: "//file/@id")
            .compactMap(\.stringValue)
        #expect(Set(files) == ["file-1", "file-2"])
        // …and each day's first clip is clip 1 of its own track
        #expect(try texts(document, "//clipitem[@id='clipitem-3']/link/clipindex")
            == ["1", "1"])
    }

    /// Each shift's timeline starts at zero: a second day that began where the
    /// first left off would open with an hour of black in front of it.
    @Test func everyShiftsTimelineStartsAtZero() throws {
        let document = try parse(try #require(FCP7XMLExporter.timeline(
            takes: [take("A", seconds: 10, recorded: at(day: 11, hour: 20)),
                    take("B", seconds: 4, recorded: at(day: 13, hour: 20))],
            project: "FILM")))
        #expect(try texts(document, "//video/track/clipitem/start") == ["0", "0"])
        #expect(try texts(document, "//sequence/duration") == ["250", "100"])
    }

    /// Two exports of one unchanged day are the same bytes: nothing in here
    /// is a fresh UUID or a timestamp, so a DIT syncing the folder sees no
    /// change where there was none.
    @Test func theSameDayExportsTheSameBytes() throws {
        let takes = [take("A"), take("B", markers: [TakeMarker(seconds: 1)])]
        #expect(FCP7XMLExporter.timeline(takes: takes, project: "FILM")
            == FCP7XMLExporter.timeline(takes: takes, project: "FILM"))
    }
}
