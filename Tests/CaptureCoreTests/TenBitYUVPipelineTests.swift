@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The 10-bit YCbCr wire through the pipeline rather than through the converter
/// on its own: the right converter is chosen, the record frame cost is stated for
/// the pre-roll ring, and a take comes out tagged the way playback expects —
/// which for this path means NOT tagged.
struct TenBitYUVPipelineTests {
    private func pipeline(in root: URL,
                          codec: CaptureCodec = .proRes422,
                          levels: String? = nil) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .manual
        settings.codec = codec
        settings.preRollFrames = 0
        settings.videoLevels = levels
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    /// A YCbCr signal: `isRGB444` false, which is what makes the levels question
    /// resolve through the "auto means limited" path rather than the RGB one.
    private func format(bitDepth: Int = 10) -> CaptureFormat {
        CaptureFormat(width: 96, height: 64, frameRate: 25, timecodeFPS: 25,
                      name: "96x64", isRGB444: false, bitDepth: bitDepth)
    }

    private func displayByte(_ buffer: CVPixelBuffer, x: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
            .assumingMemoryBound(to: UInt32.self)
        return Int(base[x] & 0xFF)
    }

    /// The pipeline names its wire formats in exactly one place, and this is it.
    /// A frame the 8-bit path should handle must NOT get a converter.
    @Test func theRightConverterIsChosenForEachWireFormat() {
        let root = TestMedia.scratchDirectory("TenBitYUVPick")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        #expect(pipeline.wireConverter(for: V210Packing.pixelFormat)
            as AnyObject === pipeline.tenBitYUVConverter)
        #expect(pipeline.wireConverter(for: TenBitConverter.r210)
            as AnyObject === pipeline.tenBitConverter)
        #expect(pipeline.wireConverter(for: R12BPacking.pixelFormat)
            as AnyObject === pipeline.twelveBitConverter)
        // the 8-bit YUV path is still the 8-bit path
        #expect(pipeline.wireConverter(for: kCVPixelFormatType_422YpCbCr8) == nil)
        #expect(pipeline.wireConverter(for: kCVPixelFormatType_32BGRA) == nil)
    }

    /// The levels stage produces the two products, hands the scopes the untouched
    /// wire, and states the record frame's bytes per pixel — which for `'v210'`
    /// is 3 rather than 4, and is what keeps the pre-roll ring's memory budget
    /// honest.
    @Test func theLevelsStageSplitsAndStatesTheRecordCost() throws {
        let root = TestMedia.scratchDirectory("TenBitYUVLevels")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let wire = try V210Fixtures.makeGrey(width: 96, height: 64) { _, _ in
            V210Fixtures.midGrey
        }
        let leveled = try #require(
            pipeline.levelledFrame(from: wire, format: format()))
        #expect(CVPixelBufferGetPixelFormatType(leveled.display)
            == kCVPixelFormatType_32BGRA)
        let record = try #require(leveled.wireRecord)
        #expect(CVPixelBufferGetPixelFormatType(record)
            == V210Packing.pixelFormat)
        #expect(record === wire, "the record product is not the wire frame")
        // the scopes get the untouched wire, on the studio-swing reading
        let scopeSource = try #require(leveled.scopeSource)
        #expect(CVPixelBufferGetPixelFormatType(scopeSource.buffer)
            == V210Packing.pixelFormat)
        #expect(scopeSource.levels == .limited)
        #expect(pipeline.recordBytesPerPixel == 3)
    }

    /// The decision this whole path turns on: a v210 take is NOT tagged as
    /// carrying wire codes, in either levels mode.
    ///
    /// The file is video-range YCbCr with Rec.709 tags, so it already states what
    /// its codes mean and every decoder acts on it — measured in
    /// `TenBitYUVRecordTests`. Tagging it would expand it twice.
    @Test func aTenBitYUVTakeIsNeverTaggedAsWire() throws {
        let root = TestMedia.scratchDirectory("TenBitYUVTag")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let wire = try V210Fixtures.makeGrey(width: 96, height: 64) { _, _ in 500 }
        for levels in [nil, InputLevels.limited.rawValue, InputLevels.full.rawValue] {
            pipeline.levelsMode = levels
            _ = pipeline.levelledFrame(from: wire, format: format())
            #expect(!pipeline.recordCarriesWireCodes,
                    "levels \(levels ?? "auto") tagged a v210 take as wire")
        }
        // …while an RGB wire in the same pipeline still IS tagged, so the
        // difference is the converter's answer and not a global switch-off
        var r210: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &r210)
        pipeline.levelsMode = InputLevels.limited.rawValue
        _ = pipeline.levelledFrame(from: try #require(r210),
                                   format: CaptureFormat(
                                       width: 96, height: 64, frameRate: 25,
                                       timecodeFPS: 25, name: "96x64",
                                       isRGB444: true, bitDepth: 10))
        #expect(pipeline.recordCarriesWireCodes)
    }

    /// Auto on a YCbCr signal means studio swing, and it has to, because YCbCr is
    /// studio swing by SMPTE over SDI and by CTA-861 over HDMI. The setting is
    /// left nil for a non-RGB-4:4:4 source, so this is really a test that nil
    /// still resolves to `limited` where a mode is needed.
    @Test func autoOnAYCbCrSignalMeansStudioSwing() throws {
        let root = TestMedia.scratchDirectory("TenBitYUVAuto")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root, levels: nil)
        let wire = try V210Fixtures.makeGrey(width: 96, height: 64) { x, _ in
            x < 48 ? V210Fixtures.nominalBlack : V210Fixtures.nominalWhite
        }
        let leveled = try #require(
            pipeline.levelledFrame(from: wire, format: format()))
        // nominal black on 0 and nominal white on 255 — the expansion happened.
        // Untouched, they would read 16 and 235.
        #expect(displayByte(leveled.display, x: 10) == 0,
                "a YCbCr source was left unexpanded on auto")
        #expect(displayByte(leveled.display, x: 80) == 255)
        // the same claim at the source: this is the resolution the whole app
        // relies on for a signal whose levels question was never asked
        #expect(InputLevels.resolved(nil) == .limited)
    }

    /// Switching wire format mid-session leaves the record cost correct — the
    /// board really can change format while the app is running, and a stale
    /// 8 bytes per pixel would shorten every later pre-roll.
    @Test func theRecordCostFollowsTheWireFormat() throws {
        let root = TestMedia.scratchDirectory("TenBitYUVSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let wire = try V210Fixtures.makeGrey(width: 96, height: 64) { _, _ in 500 }
        _ = pipeline.levelledFrame(from: wire, format: format())
        #expect(pipeline.recordBytesPerPixel == 3)

        let wire12 = try R12BFixtures.makeGrey(width: 96, height: 64) { _, _ in 2048 }
        _ = pipeline.levelledFrame(from: wire12,
                                   format: CaptureFormat(
                                       width: 96, height: 64, frameRate: 25,
                                       timecodeFPS: 25, name: "96x64",
                                       isRGB444: true, bitDepth: 12))
        #expect(pipeline.recordBytesPerPixel == 8)

        _ = pipeline.levelledFrame(from: wire, format: format())
        #expect(pipeline.recordBytesPerPixel == 3)
    }

    /// End to end: a 10-bit YCbCr signal recorded through the real writer
    /// produces a playable ProRes 422 take with NO levels key on it, which is
    /// what makes playback leave it alone.
    @Test func aTenBitYUVTakeRecordsAndPlaysWithoutALevelsKey() async throws {
        let root = TestMedia.scratchDirectory("TenBitYUVTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let collected = EventCollector<Take>()
        pipeline.onTakeFinished = { collected.append($0) }
        pipeline.handleFormat(format())
        let wire = try V210Fixtures.makeGrey(width: 96, height: 64) { x, _ in
            x < 48 ? V210Fixtures.nominalBlack : V210Fixtures.nominalWhite
        }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                fps: 25)
        // frames BEFORE the take opens, deliberately: `beginTake` reads what the
        // levels stage decided, so a take started on frame one would say nothing
        for _ in 0..<2 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: wire)
        }
        pipeline.toggleManualRecord()
        for _ in 0..<8 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: wire)
        }
        pipeline.toggleManualRecord()
        await pipeline.finishPendingWrites()
        await TestWait.until({ !collected.all.isEmpty }, timeout: .seconds(60))
        let take = try #require(collected.all.first, "no take was produced")

        let asset = AVURLAsset(url: take.url)
        let metadata = try await asset.load(.metadata)
        #expect(!(await TakeWriter.carriesWireCodes(metadata)),
                "a v210 take claims wire codes — playback will expand it twice")
        #expect(metadata.contains { ($0.key as? String) == TakeWriter.markerKey },
                "the take is not marked as TakeShot's own")
        let track = try #require(
            try await asset.loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description)
            == kCMVideoCodecType_AppleProRes422)
    }
}
