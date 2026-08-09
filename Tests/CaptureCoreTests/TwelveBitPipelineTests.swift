@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The 12-bit wire through the pipeline rather than through the converter on its
/// own: the right converter is chosen, the record frame size is stated for the
/// pre-roll ring, and a take comes out tagged the way playback expects.
struct TwelveBitPipelineTests {
    private func pipeline(in root: URL,
                          codec: CaptureCodec = .proRes4444) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.codec = codec
        settings.capture.preRollFrames = 0
        settings.capture.videoLevels = InputLevels.limited.rawValue
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    private func format(bitDepth: Int) -> CaptureFormat {
        CaptureFormat(width: 128, height: 64, frameRate: 25, timecodeFPS: 25,
                      name: "128x64", isRGB444: true, bitDepth: bitDepth)
    }

    /// The pipeline names the two wire formats in exactly one place, and this is
    /// it. A frame the 8-bit path should handle must NOT get a converter.
    @Test func theRightConverterIsChosenForEachWireFormat() {
        let root = TestMedia.scratchDirectory("TwelveBitPick")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        #expect(pipeline.wireConverter(for: TenBitConverter.r210)
            as AnyObject === pipeline.tenBitConverter)
        #expect(pipeline.wireConverter(for: R12BPacking.pixelFormat)
            as AnyObject === pipeline.twelveBitConverter)
        #expect(pipeline.wireConverter(for: kCVPixelFormatType_32BGRA) == nil)
        #expect(pipeline.wireConverter(for: kCVPixelFormatType_422YpCbCr8) == nil)
    }

    /// The levels stage produces the two products and states what the writer is
    /// being handed — including the record frame's bytes per pixel, which is
    /// what keeps the pre-roll ring inside its memory budget at UHD.
    @Test func theLevelsStageSplitsAndStatesTheRecordCost() throws {
        let root = TestMedia.scratchDirectory("TwelveBitLevels")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let wire = try R12BFixtures.makeGrey(width: 128, height: 64) { _, _ in
            R12BFixtures.midGrey
        }
        let leveled = try #require(
            pipeline.levelledFrame(from: wire, format: format(bitDepth: 12)))
        #expect(CVPixelBufferGetPixelFormatType(leveled.display)
            == kCVPixelFormatType_32BGRA)
        let record = try #require(leveled.wireRecord)
        #expect(CVPixelBufferGetPixelFormatType(record)
            == kCVPixelFormatType_64RGBALE)
        // the scopes get the untouched wire, not the display buffer
        let scopeSource = try #require(leveled.scopeSource)
        #expect(CVPixelBufferGetPixelFormatType(scopeSource.buffer)
            == R12BPacking.pixelFormat)
        #expect(scopeSource.levels == .limited)
        // …and the take will be able to say its codes are the camera's
        #expect(pipeline.recordCarriesWireCodes)
        #expect(pipeline.recordBytesPerPixel == 8)
    }

    /// A `full` source records the same codes but is not tagged as wire — the
    /// wire codes already ARE display values, so playback must leave it alone.
    ///
    /// `levelsMode` is set directly rather than through `setVideoLevels`, which
    /// hops to the pipeline queue: this test calls `levelledFrame` on its own
    /// thread, so the two have to be consistent about which thread they are on.
    @Test func aFullRangeSourceIsNotTaggedAsWire() throws {
        let root = TestMedia.scratchDirectory("TwelveBitFullTag")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        pipeline.levelsMode = InputLevels.full.rawValue
        let wire = try R12BFixtures.makeGrey(width: 128, height: 64) { _, _ in 2048 }
        _ = pipeline.levelledFrame(from: wire, format: format(bitDepth: 12))
        #expect(!pipeline.recordCarriesWireCodes)
        // …and auto on an RGB 4:4:4 signal still means studio swing, which is
        // the CTA-861 default an HDMI camera sends
        pipeline.levelsMode = nil
        _ = pipeline.levelledFrame(from: wire, format: format(bitDepth: 12))
        #expect(pipeline.recordCarriesWireCodes)
    }

    /// Switching wire format mid-session leaves the record cost correct — the
    /// board really can change format while the app is running, and a stale
    /// 8 bytes per pixel would shorten every later pre-roll.
    @Test func theRecordCostFollowsTheWireFormat() throws {
        let root = TestMedia.scratchDirectory("TwelveBitSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let wire12 = try R12BFixtures.makeGrey(width: 128, height: 64) { _, _ in 2048 }
        _ = pipeline.levelledFrame(from: wire12, format: format(bitDepth: 12))
        #expect(pipeline.recordBytesPerPixel == 8)

        var r210: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &r210)
        _ = pipeline.levelledFrame(from: try #require(r210),
                                   format: format(bitDepth: 10))
        #expect(pipeline.recordBytesPerPixel == 4)

        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 128, 64,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &bgra)
        _ = pipeline.levelledFrame(from: try #require(bgra),
                                   format: format(bitDepth: 8))
        #expect(pipeline.recordBytesPerPixel == 4)
    }

    /// End to end: a 12-bit signal recorded through the real writer produces a
    /// playable take tagged `com.takeshot.levels = "wire"`, which is what makes
    /// playback expand the studio swing back out. 12-bit swing is 256/3760,
    /// i.e. 16/235 in the 8 bits the player works in, so the existing playback
    /// table needs no 12-bit case — this is the test that the tag arrives.
    @Test func aTwelveBitTakeIsTaggedForPlayback() async throws {
        let root = TestMedia.scratchDirectory("TwelveBitTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(in: root)
        let collected = EventCollector<Take>()
        pipeline.onTakeFinished = { collected.append($0) }
        pipeline.handleFormat(format(bitDepth: 12))
        let wire = try R12BFixtures.makeGrey(width: 128, height: 64) { x, _ in
            x < 64 ? R12BFixtures.nominalBlack : R12BFixtures.nominalWhite
        }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                               fps: 25)
        // frames BEFORE the take opens, deliberately: `beginTake` reads what
        // the levels stage decided, and a take started before the first frame
        // has been through it says nothing rather than guessing (see the
        // comment on `recordCarriesWireCodes`). Recording from frame one would
        // therefore produce an untagged take and prove nothing here.
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
        let levels = metadata.first {
            ($0.key as? String) == TakeWriter.levelsKey
        }
        let value = try #require(try await levels?.load(.stringValue),
                                 "the take carries no levels key")
        #expect(value == TakeWriter.wireValue)
        // and it really is a ProRes 4444 video track
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(description)
            == kCMVideoCodecType_AppleProRes4444)
    }
}
