import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// What a retired setting is allowed to be.
///
/// Two fields on `CaptureSignalSettings` have no picker any more, and the
/// difference between them was the bug: `tenBitCapture` was tombstoned properly
/// — the key stays on the record so a blob carrying it still decodes and a
/// downgrade finds its value, and NOTHING reads it. `colorTagPreset` was not: its
/// picker was deleted and two live sites went on reading it for real behaviour,
/// the recorded file's colour tags and the display buffer's. With no writer left
/// it was permanently nil, so both were always Rec.709 — which is what the
/// documentation says the app does, and it was true by accident.
///
/// It is not coming back, and that is a decision rather than a gap: what a file
/// says its codes MEAN is a measurement of the signal, not a preference. Where a
/// camera really sends something else the app already follows it and overrides
/// everything — `WireColorimetry.filePreset` puts PQ, HLG and Rec.2020 on the
/// file from the wire's own per-frame metadata, latched per take. A preset an
/// operator could set on top of that could only ever be wrong: nothing on set can
/// verify it, and Rec.709 codes tagged 601 or 2020 are mis-transformed by every
/// tool downstream. The same shape as `hdrMode` deliberately having no "force
/// HDR", and as the manual bit depth that went for the owner's own reason.
///
/// So this states the tombstone contract for both fields, as a rule about the
/// source rather than a list of today's call sites — a list of call sites is
/// itself a thing that goes stale, which is exactly how one of these came to be
/// read again after its picker was gone.
@Suite struct RetiredSettingTests {
    /// The retired fields, by the expression a reader would have to write.
    ///
    /// Reached through their group, which is the only way in: `capture` is the
    /// group `CaptureSignalSettings` is mounted as, so `capture.tenBitCapture` is
    /// what any read of it looks like anywhere in the app.
    static let retired: [String] = ["capture.tenBitCapture",
                                    "capture.colorTagPreset"]

    /// Nothing under `Sources` reads either of them.
    @Test func aRetiredSettingIsReadNowhere() throws {
        let sources: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var isDirectory = ObjCBool(false)
        try #require(FileManager.default.fileExists(atPath: sources.path,
                                                    isDirectory: &isDirectory),
                     "the Sources tree was not where this test looked for it")
        let walker = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil),
                                  "the Sources tree could not be walked")
        var readers: [String] = []
        var files: Int = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            guard let raw: String = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            // Comments are cut out first, or this file's own explanation of what
            // used to be read here would read as a reader of it.
            let code: String = Self.withoutComments(raw)
            for field: String in Self.retired where code.contains(field) {
                readers.append("\(url.lastPathComponent): \(field)")
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        // **And the detector can still see a reader.** The assertion below is
        // an ABSENCE, so it holds just as well when the detector has stopped
        // detecting — a `withoutComments` that stripped a line too many, or a
        // `retired` list that lost its entries, would report a clean tree
        // forever. Two planted positives, one of them behind a trailing
        // comment, prove the shape of the walk before it is trusted with an
        // empty answer (the same precaution `ViewFieldRuleTests` takes).
        let planted = Self.withoutComments("""
            let a = settings.capture.tenBitCapture // and a comment after it
            // let b = settings.capture.colorTagPreset — this one must NOT count
            let c = settings.capture.colorTagPreset
            """)
        for field in Self.retired {
            try #require(planted.contains(field), """
                the walk cannot see `\(field)` even when it is there — the \
                clean result below proves nothing
                """)
        }
        try #require(
            planted.components(separatedBy: "capture.colorTagPreset").count == 2,
            "a commented-out reader was counted, so real ones are overcounted")

        #expect(readers.isEmpty,
                "a retired setting is being read for real behaviour again: \(readers.joined(separator: " | "))")
    }

    /// …and it is still on the record, which is the other half of a tombstone: a
    /// key that is REMOVED is a change to the on-disk format, and this one buys
    /// nothing. A blob carrying either value still decodes, and the value is
    /// still there afterwards for a build that downgrades.
    @Test func aRetiredSettingIsStillCarriedByTheRecord() throws {
        // The eight non-Optional keys have to be there — a synthesized decoder
        // does not fall back on a property's default — plus the two retired ones.
        let json: String = """
            {"codec":"ProRes 422","namingTemplate":"{prefix}_{cam}C{clip}",
             "destinationPath":"/tmp/shoot","detectionMode":"vanc",
             "startDebounceFrames":3,"stopDebounceFrames":7,
             "projectName":"Nightfall","cameraLabel":"B",
             "tenBitCapture":false,"colorTagPreset":"2020"}
            """
        let settings: CaptureSettings = try JSONDecoder()
            .decode(CaptureSettings.self, from: Data(json.utf8))
        #expect(settings.capture.tenBitCapture == false)
        #expect(settings.capture.colorTagPreset == "2020")

        let round: Data = try JSONEncoder().encode(settings)
        let text: String = try #require(String(data: round, encoding: .utf8))
        #expect(text.contains("\"tenBitCapture\""),
                "a retired key was dropped from the record")
        #expect(text.contains("\"colorTagPreset\""),
                "a retired key was dropped from the record")
    }

    /// And the behaviour those two sites had: with no colorimetry from the
    /// signal, the file and the display buffer are tagged Rec.709 — whatever a
    /// stored preset says, because nothing asks it any more.
    @Test func anSDRTakeIsTaggedRec709WhateverTheRetiredPresetSays() {
        // The take's tag comes from the signal's own colorimetry and nothing
        // else; SDR states no preset, and nil IS Rec.709.
        #expect(WireColorimetry.sdr.filePreset == nil)
        #expect(WireColorimetry.sdr.displayPreset == nil)
        let values: ColorTags.Values = ColorTags.values(for: nil)
        #expect(values.avPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(values.avTransfer == AVVideoTransferFunction_ITU_R_709_2)
        #expect(values.avMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    /// Line comments only — that is all this codebase writes about these fields,
    /// and a block-comment stripper that gets a string literal wrong would be
    /// worse than none.
    private static func withoutComments(_ text: String) -> String {
        var kept: [String] = []
        for line: String in text.components(separatedBy: "\n") {
            if let comment: Range<String.Index> = line.range(of: "//") {
                kept.append(String(line[line.startIndex..<comment.lowerBound]))
            } else {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }
}

/// **Each wire converter answers for its own format, and the pipeline routes on
/// that answer.**
///
/// `wireConverter(for:)` used to `switch` on the three concrete constants,
/// which made `WireConverter.wireFormat` a second statement of the same fact
/// that nothing read — a converter could answer a format the switch did not
/// route to it and nothing would notice. Only two of the three had even that
/// much asserted, so the `r210` path, which is the one an UltraStudio delivers,
/// had no guard at all.
@Suite struct WireConverterRoutingTests {
    private func pipeline() -> CapturePipeline {
        CapturePipeline(config: .init(settings: CaptureSettings(), takeNumber: 1))
    }

    @Test func everyConverterIsReachedByTheFormatItClaims() {
        let pipeline = self.pipeline()
        for converter in pipeline.wireConverters {
            let routed = pipeline.wireConverter(for: converter.wireFormat)
            #expect(routed === converter, """
                a converter claims \(converter.wireFormat) and the pipeline \
                hands that format to somebody else
                """)
        }
    }

    /// And the three claim three DIFFERENT formats — two answering the same one
    /// would make the routing depend on the order of a list.
    @Test func theThreeClaimDistinctFormats() {
        let formats = pipeline().wireConverters.map(\.wireFormat)
        #expect(Set(formats).count == formats.count,
                "two converters claim the same wire format: \(formats)")
        #expect(formats.count == 3)
    }

    /// An 8-bit frame is nobody's: it goes down the path that does not split.
    @Test func anEightBitFormatIsRoutedNowhere() {
        #expect(pipeline().wireConverter(for: kCVPixelFormatType_32BGRA) == nil)
        #expect(pipeline().wireConverter(for: kCVPixelFormatType_422YpCbCr8) == nil)
    }

    /// The record format each one names is the one its record buffer really is
    /// — the second requirement that had no production caller.
    @Test func theRecordFormatMatchesTheBufferHandedToTheWriter() throws {
        let pipeline = self.pipeline()
        for converter in pipeline.wireConverters {
            #expect(converter.recordPixelFormat != 0,
                    "a converter names no record format")
            #expect(converter.recordBytesPerPixel > 0)
        }
    }
}
