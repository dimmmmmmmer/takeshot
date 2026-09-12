import CoreGraphics
import CoreImage
import CoreVideo
import Metal
import Foundation
import Testing

@testable import CaptureCore

/// **The operator's reframe is a VIEW, and every surface that mirrors the
/// viewer has to carry it.**
///
/// The nine sizing controls used to be applied in `MetalPreviewLayer`, once per
/// mounted surface — which works for windows and for nothing else. The
/// hardware playout, the phone multiview, the director's monitor and every
/// browser stream are handed a pixel buffer rather than a layer, so a picture
/// the operator had rotated, flipped, desqueezed or punched into went out
/// unreframed: the whole unit was watching a framing nobody had chosen. That is
/// the same gap the exposure aids were moved into the display stage to close
/// (`AssistIntegrityTests`, owner item 7); this is the geometry half of it.
///
/// And the rule that comes with that place applies unchanged: it must reach the
/// recorded file, the still grab and the scopes' measurement NOWHERE AT ALL.
/// A reframe is destructive in a way a false colour is not — a zoom throws
/// footage away permanently — so the file stays what the camera sent until
/// something explicitly asks otherwise.
///
/// Same shape as `AssistIntegrityTests` on purpose: the two live one line
/// apart in the same function and are held to the same rule.
struct SizingReachTests {
    /// Push frames until one comes back that is not the source, and answer with
    /// it — `AssistIntegrityTests.presentedDecorated`'s shape, and for its
    /// reason: a fixed count either flakes or wastes a second.
    private func presentedDecorated(_ pipeline: CapturePipeline,
                                    _ source: CVPixelBuffer) async throws
        -> CVPixelBuffer {
        let collector = PreviewCollector()
        pipeline.setOnDisplayFrame { collector.record($0[.decorated]) }
        defer { pipeline.setOnDisplayFrame(nil) }
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

    // MARK: - it reaches the mirror

    /// **The director's monitor sees what the operator framed.**
    ///
    /// A horizontal flip and a two-sided frame: the bright half has to have
    /// changed ends in the buffer the playout mirror is handed. Nothing about
    /// a window is involved — this is the frame itself.
    @Test func theReframeReachesTheHardwarePlayoutMirror() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(SizingProbe.flipped())
        let source = SizingProbe.sided()
        let shown = try await presentedDecorated(pipeline, source)

        #expect(shown !== source, "the playout was handed the untouched frame")
        // the source is dark at 0.1 and bright at 0.9; flipped, the other way
        #expect(PreviewProbe.level(of: source, atFractionX: 0.1) < 100)
        #expect(PreviewProbe.level(of: shown, atFractionX: 0.1) > 150,
                "the left of the mirrored frame is still the left of the source")
        #expect(PreviewProbe.level(of: shown, atFractionX: 0.9) < 100,
                "the right of the mirrored frame is still the right of the source")
    }

    /// **A session with nothing set pays nothing.** The stage's fast path is
    /// what keeps a reframe that does not exist from costing a CoreImage pass
    /// on the display queue of every idle shoot — and it is the same predicate
    /// that keeps a take at its wire codes.
    @Test func nothingSetDrawsNothingAtAll() {
        let stage = AssistStage()
        stage.setAssist(ViewAssist())
        #expect(stage.rendered(SizingProbe.sided()) == nil,
                "an untouched assist spent a render anyway")
        var barely = ViewAssist()
        barely.flipH = true
        #expect(stage.currentAssist.sizing.isIdentity)
        stage.setAssist(barely)
        #expect(stage.rendered(SizingProbe.sided()) != nil,
                "a flip alone did not wake the stage")
    }

    /// **A late frame loses the aids and keeps its framing.**
    ///
    /// The display stage drops its work when a frame arrives past its own
    /// interval, on the rule that an operator would rather lose a zebra for
    /// one frame than watch the picture stutter. A reframe is not an aid: a
    /// frame that skipped it would put the picture somewhere else for a
    /// sixtieth of a second and then back, on the director's monitor as well,
    /// which is the jump the rule exists to prevent rather than an instance
    /// of it.
    @Test func aLateFrameLosesTheAidsAndKeepsItsFraming() {
        let stage = AssistStage()
        var both = SizingProbe.flipped()
        both.colorTool = .falseColor
        stage.setAssist(both)
        let dropped = stage.lateDrops
        // **Levels false colour would actually repaint.** 40 and 200 are both
        // inside its GRAY RAMP, so a frame of those comes back neutral whether
        // the tool ran or not and proves nothing about it — the same trap
        // `AssistIntegrityTests` documents at its flat 140. These two land in
        // the skin band and in the top warning band, which are saturated.
        let metered = { SizingProbe.sided(left: 140, right: 250) }
        let shown = stage.rendered(metered(), deadline: 0)
        let frame = shown ?? metered()
        #expect(shown != nil, "a reframed frame was dropped for being late")
        #expect(stage.lateDrops == dropped + 1, "the drop was not counted")
        // flipped — the bright half changed ends…
        #expect(PreviewProbe.level(of: frame, atFractionX: 0.1) > 220,
                "the late frame lost its framing")
        // …and NOT metered. Read on HUE, across the whole row: false colour
        // repaints every pixel in a saturated band, and nothing in a frame of
        // two greys is saturated. A single channel could match a band's by
        // coincidence; three cannot.
        for fraction in [0.1, 0.3, 0.6, 0.9] {
            let pixel = ChromaProbe.pixel(of: frame, atFractionX: fraction)
            #expect(abs(pixel.r - pixel.g) <= 3 && abs(pixel.g - pixel.b) <= 3,
                    "a late frame was metered at \(fraction): \(pixel)")
        }
        // With nothing to keep, a late frame is passed through as it always was.
        var toolOnly = ViewAssist()
        toolOnly.colorTool = .falseColor
        stage.setAssist(toolOnly)
        #expect(stage.rendered(metered(), deadline: 0) == nil,
                "a late frame with no framing to keep was rendered anyway")
    }

    /// **The meters read the camera, not the bars the reframe makes.**
    ///
    /// The stage draws the geometry LAST, after everything that measures, and
    /// that is a contract rather than an order of convenience. False colour,
    /// zebra and peaking answer for CODE VALUES: run them after a reframe and
    /// they meter resampled pixels and — visible in one look — paint the black
    /// the letterbox put there as if the camera had sent a crushed shadow. A
    /// director's monitor with purple bars down both sides of the picture is
    /// the shape that mistake takes on set.
    @Test func theToolsMeterTheCameraAndNotTheBars() throws {
        let stage = AssistStage()
        var assist = ViewAssist()
        // half height: the picture shrinks into the raster and leaves bars
        assist.height = 0.5
        assist.colorTool = .falseColor
        stage.setAssist(assist)
        let shown = try #require(stage.rendered(SizingProbe.sided(left: 140,
                                                           right: 140)))
        // the PICTURE is metered — 140 is 0.549, inside the skin band…
        let middle = SizingProbe.pixel(of: shown, atX: 0.5, atY: 0.5)
        #expect(abs(middle.r - 242) < 12 && abs(middle.g - 153) < 12
            && abs(middle.b - 179) < 12,
                "the tool never ran, so this proves nothing: \(middle)")
        // …and the bar is the letterbox, not the purple false colour paints
        // over a crushed black
        let bar = SizingProbe.pixel(of: shown, atX: 0.5, atY: 0.05)
        #expect(bar.r < 20 && bar.g < 20 && bar.b < 20,
                "the bars the reframe made were metered: \(bar)")
    }

    // MARK: - and it reaches the deliverables nowhere

    /// The recorded take is what the camera sent, whatever the operator has
    /// dialled in. A reframe THROWS FOOTAGE AWAY — see
    /// `PictureSizing.isCropping` — so it stays out of the file until
    /// something asks for it by name.
    @Test func aTakeRecordedWithAReframeHoldsTheOriginalPixels() async throws {
        let root = TestMedia.scratchDirectory("SizingTake")
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = CaptureSettings()
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual
        settings.capture.videoLevels = "full"
        settings.capture.preRollFrames = 0
        settings.capture.codec = .proResProxy
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180, frameRate: 25,
                                            timecodeFPS: 25, name: "1080p25"))
        pipeline.setViewAssist(SizingProbe.flipped())
        let takes = TakeCollector()
        pipeline.onTakeFinished = { takes.append($0) }
        let mirrored = EventCollector<Int>()
        pipeline.setOnDisplayFrame {
            mirrored.append(PreviewProbe.level(of: $0[.decorated],
                                               atFractionX: 0.1))
        }
        defer { pipeline.setOnDisplayFrame(nil) }

        let source = SizingProbe.sided(width: 320, height: 180)
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
        // the operator IS looking at a flipped picture, or this proves nothing
        #expect(mirrored.all.contains { $0 > 150 },
                "the reframe never reached the screen")

        let frame = try #require(await ChromaProbe.firstFrame(of: take.url),
                                 "the take decoded no frames")
        let left = ChromaProbe.pixel(of: frame, atFractionX: 0.1)
        let right = ChromaProbe.pixel(of: frame, atFractionX: 0.9)
        #expect(left.g < 100, "the take came back flipped: left is \(left)")
        #expect(right.g > 150, "the take came back flipped: right is \(right)")
    }

    /// The still grab, the same question: it is taken off the frame before the
    /// display stage exists, so it is the camera's framing.
    @Test func aGrabTakenWithAReframeHoldsTheOriginalPixels() async throws {
        let pipeline = PreviewProbe.makePipeline()
        pipeline.setViewAssist(SizingProbe.flipped())
        let grabs = EventCollector<Data?>()
        let mirrored = EventCollector<Int>()
        pipeline.setOnDisplayFrame {
            mirrored.append(PreviewProbe.level(of: $0[.decorated],
                                               atFractionX: 0.1))
        }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.grabNextFrame { grabs.append($0) }

        let source = SizingProbe.sided()
        var index = 0
        await TestWait.untilWritten {
            guard !mirrored.all.contains(where: { $0 > 150 }) else { return true }
            index += 1
            PreviewProbe.push(pipeline, source, frame: index)
            return false
        }
        await TestWait.until { !grabs.isEmpty && !mirrored.isEmpty }

        #expect(mirrored.all.contains { $0 > 150 },
                "the reframe never reached the screen, so this proves nothing")
        let png = try #require(grabs.first ?? nil, "no PNG came back")
        let left = try #require(ChromaProbe.pixel(inPNG: png, atFractionX: 0.1),
                                "the grab could not be decoded")
        let right = try #require(ChromaProbe.pixel(inPNG: png, atFractionX: 0.9),
                                 "the grab could not be decoded")
        #expect(left.g < 110, "the grab came back flipped: left is \(left)")
        #expect(right.g > 140, "the grab came back flipped: right is \(right)")
    }

}

/// The frames and the assists both sizing suites shoot with.
enum SizingProbe {
    /// A frame that is DARK on the left and BRIGHT on the right, so a
    /// horizontal flip is a thing a test can see. A flat frame proves nothing
    /// about geometry — it is the same picture whichever way round it is.
    static func sided(width: Int = 64, height: Int = 32,
                      left: UInt8 = 40, right: UInt8 = 200) -> CVPixelBuffer {
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    let level = x < width / 2 ? left : right
                    row[x * 4] = level
                    row[x * 4 + 1] = level
                    row[x * 4 + 2] = level
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The pixel at a fraction ACROSS and DOWN the frame — `ChromaProbe`'s
    /// reader only ever looks at the middle row, and the whole point here is
    /// what is above the picture.
    static func pixel(of buffer: CVPixelBuffer, atX fractionX: Double,
                      atY fractionY: Double) -> ChromaProbe.Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return ChromaProbe.Pixel(r: -1, g: -1, b: -1)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = min(width - 1, max(0, Int(Double(width) * fractionX)))
        let y = min(height - 1, max(0, Int(Double(height) * fractionY)))
        let row = base.assumingMemoryBound(to: UInt8.self) + y * rowBytes
        return ChromaProbe.Pixel(r: Int(row[x * 4 + 2]), g: Int(row[x * 4 + 1]),
                                 b: Int(row[x * 4]))
    }

    static func flipped() -> ViewAssist {
        var assist = ViewAssist()
        assist.flipH = true
        return assist
    }

}
