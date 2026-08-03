import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The rule the whole assist feature turns on: an operator aid is a VIEW.
///
/// It has to reach every surface that mirrors the viewer — the windows, the
/// director's monitor, the hardware playout, the phone multiview — which is
/// owner item 7, and is why the aids moved out of the per-sink preview layer
/// and into the shared display stage. And it must reach the recorded file, the
/// still grab and the scopes' measurement NOWHERE AT ALL: a false colour is a
/// meter, and a take that comes back from post rendered in nine flat colours is
/// the worst possible outcome of switching one on.
///
/// This suite is the same shape as `ChromaKeyIntegrityTests` on purpose. The two
/// tools sit one stage apart in the same place and are held to the same rule, so
/// a change that breaks one should read as breaking the other.
struct AssistIntegrityTests {
    /// A pipeline that can record, on a scratch folder of its own.
    private func recordingPipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .manual // this suite starts its own take
        settings.videoLevels = "full"    // pass the test frame's codes through
        settings.preRollFrames = 0
        settings.codec = .proResProxy    // the suite encodes in real time
        return CapturePipeline(config: .init(settings: settings, takeNumber: 1))
    }

    /// Everything switched on that paints on the picture. False colour alone
    /// would prove the point; all of them together is what an operator actually
    /// has on, and it is the combination that has to stay off the deliverable.
    ///
    /// The legend is in here too, at the bottom of the frame, since the owner
    /// ruled it has to be burned in with the rest (see `AssistLegend`). It is
    /// the one aid that paints where nothing else does — a matte and a false
    /// colour repaint the whole picture, a legend puts nine saturated swatches
    /// in one band of it — so the take and the grab are read there as well as
    /// in the middle.
    private func loudAssist() -> ViewAssist {
        var assist = ViewAssist()
        assist.colorTool = .falseColor
        assist.zebraOn = true
        assist.zebraThreshold = 0.5
        assist.peakingOn = true
        assist.guides = AssistGuides(ratio: 2.39, safeAreas: true)
        assist.legend = AssistLegend(size: .large, placement: .bottom)
        return assist
    }

    /// The frame the legend tests shoot: big enough that a legend is drawn on
    /// it at all (a 64x32 probe frame has no room for one), small enough to
    /// encode in real time.
    private static let width = 640
    private static let height = 360

    /// A pipeline whose format is the size above — `PreviewProbe.makePipeline`
    /// announces 64x32, which is smaller than the smallest legend there is.
    private func legendPipeline() -> CapturePipeline {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.handleFormat(CaptureFormat(width: Self.width,
                                            height: Self.height, frameRate: 25,
                                            timecodeFPS: 25, name: "test"))
        return pipeline
    }

    /// The flat level the suite shoots.
    ///
    /// 140, not 128, and that is the whole test: 128 is 0.502 of full scale,
    /// which lands in one of false colour's GRAY RAMP gaps — the frame comes
    /// back visually identical and "the aids reached the screen" reads as false
    /// when it is true. 140 is 0.549, inside the pink skin band, and above the
    /// 0.5 zebra threshold as well, so both tools have visible work to do.
    private static let flat: UInt8 = 140
    /// How far a channel has to move before it counts as metered. Well above
    /// ProRes's few codes of DCT ringing and far below any warning band.
    private static let metered = 24

    /// Push frames at the live pace until one comes back decorated.
    ///
    /// Not one frame and one wait: the display stage drops the EFFECT on a
    /// frame it reaches late, and the first pass through a CoreImage graph
    /// compiles kernels — on a loaded machine that first frame legitimately
    /// misses its 40 ms budget. A suite that asserted on it would be red for a
    /// reason that has nothing to do with the code under test.
    ///
    /// And not a fixed dozen frames either. Twelve times 40 ms is a wall-clock
    /// window, which is the one thing this suite's waits are not allowed to be:
    /// the CI runner went red on it with NOTHING presented at all, because
    /// compiling that graph there costs more than the half second the window
    /// allowed. This polls for the outcome on the same I/O-sized budget as
    /// `TestWait.untilWritten`, and still returns the moment a decorated frame
    /// arrives.
    private func presentedDecorated(_ pipeline: CapturePipeline,
                                    _ source: CVPixelBuffer) async throws
        -> CVPixelBuffer {
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        // read first, push second: a poll that pushed and then answered would
        // leave a frame in flight behind it, and the caller that goes on to
        // stall the display queue needs it empty
        var decorated: CVPixelBuffer?
        var index = 0
        await TestWait.untilWritten {
            if let last = collector.last, last !== source { decorated = last }
            guard decorated == nil else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        return try #require(decorated ?? collector.last,
                            "nothing was presented at all")
    }

    // MARK: - it reaches the mirrors

    /// The hardware playout mirror is fed off `setOnDisplayFrame`, which is the
    /// path that had no aids on it at all: it never mounts a preview layer, so
    /// the per-sink chain could not reach it by construction.
    @Test func theAidsReachTheHardwarePlayoutMirror() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(loudAssist())
        let source = PreviewProbe.frame(Self.flat)
        let shown = try await presentedDecorated(pipeline, source)

        #expect(shown !== source, "the playout was handed the untouched frame")
        #expect(Self.isMetered(shown),
                "the frame reached the mirror unmetered: \(Self.rowDescription(of: shown))")
    }

    /// The legend goes with it. It was left behind as a SwiftUI overlay when
    /// the rest of the aids moved into the display stage, on the reasoning that
    /// a key to the picture is chrome rather than a mark on it; the owner
    /// overruled that, and the case is this one — a director's monitor showing
    /// nine flat colours with no key to them.
    ///
    /// A flat frame under false colour is ONE colour everywhere, so a swatch
    /// from the other end of the palette can only have come from the legend.
    @Test func theLegendReachesTheHardwarePlayoutMirror() async throws {
        let pipeline = legendPipeline()
        var assist = ViewAssist()
        assist.colorTool = .falseColor
        assist.legend = AssistLegend(size: .large, placement: .bottom)
        pipeline.setViewAssist(assist)
        let source = LegendProbe.frame(Self.flat, width: Self.width,
                                     height: Self.height)
        let shown = try await presentedDecorated(pipeline, source)

        let grid = LegendProbe.pixels(of: shown)
        for band in [AssistFilters.band(0.01), AssistFilters.band(1)] {
            #expect(LegendProbe.contains(band, in: grid),
                    "the playout mirror has no \(band) swatch on it")
        }
    }

    /// The camera grid on a phone is the ONE display consumer that must not get
    /// the aids. It is what the crew watches, not what the operator judges
    /// exposure on: false colour there tells a gaffer the scene is on fire, and
    /// a frameline matte reads as the actual frame. The owner asked for them off
    /// (item 13), so the grid is handed the clean frame while the viewer and the
    /// hardware monitor — asserted just above — get the decorated one.
    /// The legend is on that list too, and it is drawn at a size the grid
    /// cannot hide: the frame here is 640x360 rather than the 64x32 probe
    /// frame, because a legend needs room to exist before its absence proves
    /// anything.
    @Test func theAidsStayOffTheCameraGrid() async throws {
        let pipeline = legendPipeline()
        pipeline.setViewAssist(loudAssist())
        let collector = PreviewCollector()
        pipeline.setOnMultiviewFrame { collector.record($0) }
        defer { pipeline.setOnMultiviewFrame(nil) }

        // polled, not a fixed dozen frames: see `presentedDecorated` for the
        // runner that presented nothing inside that window
        let source = LegendProbe.frame(Self.flat, width: Self.width,
                                     height: Self.height)
        var index = 0
        await TestWait.untilWritten {
            guard collector.last == nil else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }

        let shown = try #require(collector.last, "nothing reached the grid")
        #expect(!Self.isMetered(shown),
                "the aids reached the crew's phones: \(Self.rowDescription(of: shown))")
        #expect(LegendProbe.firstColoredPixel(of: shown) == nil,
                "a legend swatch reached the crew's phones")
    }

    /// Framelines on their own — no exposure tool — still cost a pass. They are
    /// drawn rather than computed, so `anyToolActive` is false for them and a
    /// stage that asked only that question would skip them.
    @Test func theGuidesAloneReachTheMirror() async throws {
        let pipeline = PreviewProbe.makePipeline()
        var assist = ViewAssist()
        assist.guides = AssistGuides(ratio: 2.39)
        pipeline.setViewAssist(assist)

        let source = PreviewProbe.frame(0xB0)
        let shown = try await presentedDecorated(pipeline, source)
        #expect(shown !== source, "a frameline alone drew nothing")
        // 2.39 on a 2:1 test frame mattes the top and bottom and leaves the
        // middle alone: the picture is not dimmed, the bars around it are
        let middle = PreviewProbe.level(of: shown, atFractionX: 0.5)
        #expect(middle == 0xB0, "the frameline dimmed the picture: \(middle)")
        let top = Self.level(of: shown, atFractionX: 0.5, row: 1)
        #expect(top < 0xB0, "the matte outside the frameline is missing: \(top)")
    }

    /// With nothing switched on the stage costs nothing and changes nothing —
    /// the frame that goes out is the very buffer that came in.
    @Test func anIdleAssistPassesTheFrameThroughUntouched() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(ViewAssist())
        let source = PreviewProbe.frame(0x40)
        let shown = try await ChromaProbe.presented(pipeline, source)
        #expect(shown === source, "an idle assist stage copied the frame")
    }

    // MARK: - it reaches no deliverable

    /// The still grab is a deliverable: it comes off the frame before the
    /// display stage exists, so the grey is still grey in the PNG.
    ///
    /// Shot at 640x360 rather than on the 64x32 probe frame: the legend is one
    /// of the aids switched on here, and a frame too small to hold one would
    /// make its absence from the grab mean nothing.
    @Test func aGrabTakenWithTheAidsOnHoldsTheOriginalPixels() async throws {
        let pipeline = legendPipeline()
        pipeline.setViewAssist(loudAssist())
        let grabs = EventCollector<Data?>()
        let shown = EventCollector<Bool>()
        pipeline.setOnDisplayFrame { shown.append(Self.isMetered($0)) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.grabNextFrame { grabs.append($0) }

        // polled, not a fixed dozen frames: see `presentedDecorated`
        let source = LegendProbe.frame(Self.flat, width: Self.width,
                                     height: Self.height)
        var index = 0
        await TestWait.untilWritten {
            guard !shown.contains(true) else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        await TestWait.until { !grabs.isEmpty && !shown.isEmpty }

        // the operator IS looking at a metered picture…
        #expect(shown.contains(true),
                "the aids never reached the screen, so this proves nothing")
        // …and the still they just made is not
        let png = try #require(grabs.first ?? nil, "no PNG came back")
        // Read on HUE and on level, not on exact codes: the still is tagged
        // Rec.709 and the probe draws it into device RGB, which moves a flat
        // 140 to a flat 151. That conversion cannot turn a pixel pink, and both
        // things an aid would have done here — the skin band's (242,153,179),
        // a white zebra stripe — fail one of the two checks outright.
        for fraction in [0.1, 0.5, 0.9] {
            let pixel = try #require(
                ChromaProbe.pixel(inPNG: png, atFractionX: fraction),
                "the grab could not be decoded")
            #expect(Self.isNeutral(pixel),
                    "an aid tinted the grab at \(fraction): \(pixel)")
            #expect(abs(pixel.g - Int(Self.flat)) <= 20,
                    "the grab is at \(pixel.g), not the \(Self.flat) that was shot")
        }
        // The legend is not on the middle row and never will be, so it is read
        // for over the WHOLE still: every band of it is saturated, and nothing
        // in a flat grey frame is.
        let colored = try #require(LegendProbe.coloredPixels(inPNG: png),
                                   "the grab could not be decoded")
        #expect(colored.isEmpty,
                "a legend swatch was baked into the grab: \(colored.prefix(3))")
    }

    /// The recorded take, the same question, through a real encoder.
    @Test func aTakeRecordedWithTheAidsOnHoldsTheOriginalPixels() async throws {
        let root = TestMedia.scratchDirectory("AssistTake")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = recordingPipeline(root: root)
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "1080p25"))
        pipeline.setViewAssist(loudAssist())
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let shown = EventCollector<Bool>()
        pipeline.setOnDisplayFrame { shown.append(Self.isMetered($0)) }
        defer { pipeline.setOnDisplayFrame(nil) }

        let source = LegendProbe.frame(Self.flat, width: 320, height: 180)
        let driver = SignalDriver(pipeline: pipeline)
        var timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        pipeline.toggleManualRecord()
        for _ in 0..<12 {
            timecode = timecode.advanced(by: 1)
            try await driver.push(timecode, pixelBuffer: source)
        }
        pipeline.toggleManualRecord()
        await TestWait.untilWritten { takes.first != nil }

        let take = try #require(takes.first, "no take was finished")
        await TestWait.fileExists(at: take.url)
        #expect(shown.contains(true),
                "the aids never reached the screen, so this proves nothing")

        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        // inside the 2.39 frameline, where a false colour would have repainted
        // the picture pink had an aid got into the encoder
        for fraction in [0.1, 0.5, 0.9] {
            let pixel = ChromaProbe.pixel(of: frame, atFractionX: fraction)
            #expect(Self.isFlat(pixel, tolerance: 10),
                    "an aid was baked into the take at \(fraction): \(pixel)")
        }
        // …and the band the frameline's matte would have darkened
        let top = Self.level(of: frame, atFractionX: 0.5, row: 4)
        #expect(abs(top - Int(Self.flat)) < 10,
                "the frameline matte was baked into the take: \(top)")
        // …and the band along the bottom where the legend is drawn. Read as
        // colour rather than as level: ProRes moves a flat grey by a code or
        // two, and a swatch by a hundred in one channel.
        #expect(LegendProbe.firstColoredPixel(of: frame) == nil,
                "a legend swatch was encoded into the take")
    }

    /// The frame published for the compare provider — what a pinned reference
    /// and the difference compare are taken from — is the clean one too.
    @Test func theCompareProviderNeverSeesTheAids() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(loudAssist())
        let source = PreviewProbe.frame(Self.flat)
        _ = try await presentedDecorated(pipeline, source)

        let clean = try #require(pipeline.currentPreviewBuffer())
        #expect(clean === source, "the provider was handed a metered frame")
        let preLUT = try #require(pipeline.currentPreLUTPreviewBuffer())
        #expect(preLUT === source)
    }

    // MARK: - degradation

    /// Graceful degradation, the same contract the chroma key has: a frame that
    /// reaches the display stage already stale is shown at once WITHOUT the
    /// aids rather than held up while the GPU decorates a picture that is out
    /// of date before it lands.
    @Test func aLateFrameLosesTheAidsAndNotTheFrame() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(loudAssist())
        let source = PreviewProbe.frame(Self.flat)

        let decorated = try await presentedDecorated(pipeline, source)
        #expect(decorated !== source,
                "the aids are not working at all, so the late case proves nothing")
        let settledDrops = pipeline.assistStage.lateDrops

        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.displayQueue.async { Thread.sleep(forTimeInterval: 0.2) }
        PreviewProbe.push(pipeline, source, frame: 20)
        await TestWait.until { collector.count > 0 }

        let late = try #require(collector.last)
        #expect(late === source, "a stale frame was still decorated")
        #expect(pipeline.assistStage.lateDrops == settledDrops + 1,
                "the drop was not counted: \(pipeline.assistStage.lateDrops)")
    }
}

/// How this suite reads a frame back. In an extension rather than in the
/// suite's own body: the tests above are what the file is about, and a page
/// of pixel arithmetic between them is what pushed the type past the length
/// at which nobody reads one top to bottom.
extension AssistIntegrityTests {
    /// Whether a pixel is still the flat level the frame was shot at.
    private static func isFlat(_ pixel: ChromaProbe.Pixel,
                               tolerance: Int) -> Bool {
        let level = Int(flat)
        return abs(pixel.r - level) < tolerance && abs(pixel.g - level) < tolerance
            && abs(pixel.b - level) < tolerance
    }

    /// Whether a pixel is still grey. Every exposure tool this suite switches
    /// on paints in colour, so neutrality survives a colour-space round trip
    /// where an exact code value does not.
    private static func isNeutral(_ pixel: ChromaProbe.Pixel) -> Bool {
        abs(pixel.r - pixel.g) <= 3 && abs(pixel.g - pixel.b) <= 3
    }

    /// Whether ANY pixel along the middle row moved off the flat level.
    ///
    /// A whole row rather than one sample, because the tools do not all repaint
    /// the same pixels: false colour repaints every one, zebra repaints
    /// stripes, and a single probe can land between two stripes and report a
    /// metered frame as clean.
    private static func isMetered(_ buffer: CVPixelBuffer) -> Bool {
        row(of: buffer).contains { abs($0 - Int(flat)) > metered }
    }

    /// The middle row's blue channel, for a failure message that says what the
    /// frame actually looked like.
    private static func rowDescription(of buffer: CVPixelBuffer) -> String {
        let values = row(of: buffer)
        return "min \(values.min() ?? -1), max \(values.max() ?? -1)"
    }

    private static func row(of buffer: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let start = base.assumingMemoryBound(to: UInt8.self)
            + (height / 2) * rowBytes
        return (0..<width).map { Int(start[$0 * 4]) }
    }

    // A flat frame at an arbitrary size is `LegendProbe.frame` (PreviewProbe's
    // is 64x32, which is too small to hold a legend), and so are the two
    // colour readings this suite makes of a take and a grab.

    /// The blue channel at `fraction` across a named ROW, counted from the top.
    /// `PreviewProbe.level` always reads the middle row; the frameline matte is
    /// only visible outside it.
    private static func level(of buffer: CVPixelBuffer, atFractionX fraction: Double,
                              row rowIndex: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fraction)))
        let y = min(height - 1, max(0, rowIndex))
        let row = base.assumingMemoryBound(to: UInt8.self) + y * rowBytes
        return Int(row[x * 4])
    }
}
