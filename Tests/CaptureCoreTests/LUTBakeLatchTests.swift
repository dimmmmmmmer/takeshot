import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The LUT bake, latched at take open — the same question
/// `ChromaKeyBakeTests` asks of the key, asked of the look.
///
/// It matters for the same reason and it was NOT latched. `recordProduct` read
/// `lutRecord` per frame, so the "bake into recording" switch handed the writer
/// BGRA display frames while it was on and the wire-code record buffer (r210,
/// R12B or v210) while it was off — a PIXEL FORMAT change inside an open
/// `AVAssetWriter` session, which is the hazard the audio channel mask is
/// latched to avoid. And the file's `lutKey` tag is written once, at open, so a
/// take that changed halfway also lied about what it was.
///
/// Every test here reads EVERY frame of the finished file rather than the first
/// one, because a latch that holds for a frame and not for a take is the bug
/// this suite exists to catch.
@Suite struct LUTBakeLatchTests {
    /// Turns everything pure red whatever went in, so one pixel says whether the
    /// look reached the file.
    private static let redCube = """
        LUT_3D_SIZE 2
        \(Array(repeating: "1.0 0.0 0.0", count: 8).joined(separator: "\n"))
        """

    /// …and blue, for the look SWAPPED mid-take.
    private static let blueCube = """
        LUT_3D_SIZE 2
        \(Array(repeating: "0.0 0.0 1.0", count: 8).joined(separator: "\n"))
        """

    /// A uniform mid-grey frame at the recording size: both of the chroma
    /// probe's zones set to the same colour, so any pixel answers for the frame.
    private static func greyFrame() -> CVPixelBuffer {
        ChromaProbe.frame(screen: ChromaProbe.midGray,
                          subject: ChromaProbe.midGray,
                          width: 320, height: 180)
    }

    private func recordingPipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.videoLevels = "full"
        settings.capture.preRollFrames = 0
        settings.capture.codec = .proResProxy
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                    takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "1080p25"))
        return pipeline
    }

    /// Record one take, running `midTake` halfway through — which is where every
    /// latch question lives. Shaped like `ChromaKeyBakeTests.record`, including
    /// the frames before the take opens: the levels stage learns what the wire
    /// carries from a frame that has been through it, and a real REC press
    /// happens on a signal that was already running.
    private func record(_ pipeline: CapturePipeline, frames: Int = 12,
                        midTake: (() -> Void)? = nil) async throws -> Take {
        let source = Self.greyFrame()
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0,
                                fps: 25)
        for _ in 0..<3 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        for index in 0..<frames {
            if index == frames / 2 { midTake?() }
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        await pipeline.finishPendingWrites()
        await TestWait.untilWritten { takes.all.count >= 1 }
        return try #require(takes.all.first, "no take was published")
    }

    private func isRed(_ pixel: ChromaProbe.Pixel) -> Bool {
        pixel.r > 150 && pixel.g < 90 && pixel.b < 90
    }

    private func isBlue(_ pixel: ChromaProbe.Pixel) -> Bool {
        pixel.b > 150 && pixel.r < 90 && pixel.g < 90
    }

    /// A grey frame that no LUT reached: the three channels stay together.
    private func isNeutral(_ pixel: ChromaProbe.Pixel) -> Bool {
        abs(Int(pixel.r) - Int(pixel.g)) < 40
            && abs(Int(pixel.g) - Int(pixel.b)) < 40
    }

    /// Disarming the bake mid-take finishes the take that was started.
    ///
    /// The frame the writer gets is the thing that must not change: BGRA display
    /// frames before, the wire record buffer after, inside one open writer.
    @Test func aTakeFinishesTheWayItOpened() async throws {
        let root = TestMedia.scratchDirectory("LUTBakeLatchOff")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: false,
                        record: true, intensity: 1)

        let take = try await record(pipeline) {
            // the operator changes their mind halfway through
            pipeline.setLUT(nil, preview: false, record: false, intensity: 1)
        }
        let frames: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(frames.count >= 6, "only \(frames.count) frames decoded")
        #expect(frames.allSatisfy { isRed($0) },
                "the take stopped carrying the look partway: \(frames)")
    }

    /// …and arming it mid-take bakes nothing into the take that is rolling. The
    /// NEXT one bakes, which is what makes this a latch rather than an off
    /// switch.
    @Test func armingTheBakeMidTakeLeavesTheRollingTakeClean() async throws {
        let root = TestMedia.scratchDirectory("LUTBakeLatchOn")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)

        let take = try await record(pipeline) {
            pipeline.setLUT(try? CubeLUT.parse(Self.redCube), preview: false,
                            record: true, intensity: 1)
        }
        let frames: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(frames.count >= 6, "only \(frames.count) frames decoded")
        #expect(frames.allSatisfy { isNeutral($0) },
                "a bake armed mid-take reached the file: \(frames)")

        let next = try await record(pipeline)
        let after: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: next.url)
        #expect(after.allSatisfy { isRed($0) },
                "the take after the arm was still clean: \(after)")
    }

    /// A look SWAPPED mid-take does not reach the file either.
    ///
    /// The flag alone is not enough to latch: with the bake left on, changing
    /// the cube would have put two grades in one file — and the `lutKey` tag,
    /// written once at open, would name the first of them. So the filter and the
    /// name are latched with the flag.
    @Test func aLookSwappedMidTakeDoesNotReachTheFile() async throws {
        let root = TestMedia.scratchDirectory("LUTBakeLatchSwap")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: false,
                        record: true, intensity: 1)

        let take = try await record(pipeline) {
            pipeline.setLUT(try? CubeLUT.parse(Self.blueCube), preview: false,
                            record: true, intensity: 1)
        }
        let frames: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(frames.count >= 6, "only \(frames.count) frames decoded")
        #expect(frames.allSatisfy { isRed($0) },
                "the swapped look reached the open take: \(frames)")
        #expect(!frames.contains { isBlue($0) },
                "a second grade landed in one file: \(frames)")
    }

    /// The same latch, with the LUT on the PREVIEW as well.
    ///
    /// This is the path that reuses the already-looked display frame instead of
    /// running a second CoreImage pass, so it is the one that could leak the new
    /// look into an open file by handing over a buffer the preview had already
    /// re-graded. Identity of the filter is what stops it.
    @Test func aPreviewedLookIsAlsoLatchedForTheFile() async throws {
        let root = TestMedia.scratchDirectory("LUTBakeLatchPreviewed")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.setLUT(try CubeLUT.parse(Self.redCube), preview: true,
                        record: true, intensity: 1)

        let take = try await record(pipeline) {
            pipeline.setLUT(try? CubeLUT.parse(Self.blueCube), preview: true,
                            record: true, intensity: 1)
        }
        let frames: [ChromaProbe.Pixel] =
            await ChromaProbe.screenPixels(of: take.url)
        #expect(frames.count >= 6, "only \(frames.count) frames decoded")
        #expect(frames.allSatisfy { isRed($0) },
                "the preview's new look reached the open take: \(frames)")
    }
}
