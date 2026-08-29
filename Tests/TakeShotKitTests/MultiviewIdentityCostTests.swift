import CaptureCore
@preconcurrency import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **What the identity costs**, counted and timed.
///
/// Split from `MultiviewIdentityTests` because it asks a different kind of
/// question: that suite is about what is drawn and where, this one is about how
/// often it is drawn and what the pass costs when it is. The caching rule is a
/// claim about cost, so it is asserted as a number of rasters rather than
/// described in a comment; the timings beside it are opt-in and assert nothing,
/// like every other benchmark in this project.
@Suite struct MultiviewIdentityCostTests {

    /// **A still nameplate is drawn ONCE, however many frames go by.**
    ///
    /// This is the caching rule as a number rather than as a comment, and it is
    /// what makes the wiring's design legal: `pushGridIdentities` restates every
    /// tile's whole identity on every timecode tick — 25 times a second — rather
    /// than working out which of the label, the lamp and the clock moved.
    /// Restating is only free if an unchanged statement rasterizes nothing, so
    /// that is asserted directly.
    ///
    /// The second half is the invalidation, and note there is no invalidation
    /// STEP: the key is what is drawn, so a REC press is simply a key that was
    /// never in the table. A cache that had to be told about the press could be
    /// told late, or not at all.
    @Test func aStillNameplateIsDrawnOnceAndAChangedOneTwice() {
        TileBadge.resetForTesting()
        let metrics = TileTypeMetrics(tileHeight: 540)
        for _ in 0..<50 {
            _ = TileBadge.nameplate(for: .camera(label: "A CAM",
                                                 recording: false, signalPresent: true),
                                    metrics: metrics, maximumWidth: 900)
        }
        #expect(TileBadge.rasterCount == 1,
                "50 restatements drew \(TileBadge.rasterCount) bitmaps")
        _ = TileBadge.nameplate(for: .camera(label: "A CAM", recording: true, signalPresent: true),
                                metrics: metrics, maximumWidth: 900)
        #expect(TileBadge.rasterCount == 2, "the REC press did not redraw")
        _ = TileBadge.nameplate(for: .camera(label: "B CAM", recording: true, signalPresent: true),
                                metrics: metrics, maximumWidth: 900)
        #expect(TileBadge.rasterCount == 3, "the rename did not redraw")
        // and the tile getting bigger is a different picture too — the type
        // size is a fraction of the cell, so a multicam change resizes it
        _ = TileBadge.nameplate(for: .camera(label: "B CAM", recording: true, signalPresent: true),
                                metrics: TileTypeMetrics(tileHeight: 1080),
                                maximumWidth: 900)
        #expect(TileBadge.rasterCount == 4, "a resized cell reused its bitmap")
    }

    /// **A clock costs one raster per distinct value, and nothing at all while
    /// it is not moving.**
    ///
    /// The second half is the one worth having. A PAUSED comparison is exactly
    /// the case `MultiviewComposer.Pacing.everyFrame` exists for — every tile's
    /// arrival composes, because a stepped grid has no clock to pace to — so it
    /// is also the case that composes most redundantly. Its timecodes are
    /// frozen by definition, so that is precisely where the clock cache hits
    /// every time.
    @Test func aClockIsDrawnOncePerValueAndFreeWhileItIsFrozen() {
        TileBadge.resetForTesting()
        let metrics = TileTypeMetrics(tileHeight: 540)
        // a paused comparison: the same four values, over and over
        for _ in 0..<40 {
            for tile: Int in 0..<4 {
                _ = TileBadge.clock(text: "01:00:0\(tile):12", metrics: metrics,
                                    maximumWidth: 900)
            }
        }
        #expect(TileBadge.rasterCount == 4,
                "160 frozen composes drew \(TileBadge.rasterCount) clocks")
        // and a rolling one pays per tick, which is the honest other half
        for frame: Int in 0..<10 {
            _ = TileBadge.clock(text: String(format: "01:00:00:%02d", frame),
                                metrics: metrics, maximumWidth: 900)
        }
        #expect(TileBadge.rasterCount == 14,
                "a rolling clock drew \(TileBadge.rasterCount - 4) of 10")
    }

    // MARK: - through the composer

    /// **The identity is really composited, and it does not disturb the picture
    /// it sits on.**
    ///
    /// Both halves, because on its own each is satisfied by the failure the
    /// other one catches. The middle of every tile must arrive at its own code
    /// value exactly as before — these buffers hold 709-encoded codes and the
    /// display path's whole contract is that nothing here shifts them — and a
    /// point INSIDE the nameplate must be darkened by the plate, which is what
    /// says a badge was drawn at all rather than the composite quietly handing
    /// back the picture it was given.
    ///
    /// The plate is an alpha composite of one constant colour, so its code is
    /// arithmetic and not typography: 0x40 under 55 % black is about 0x1D on
    /// any machine. That is why this may be read where a glyph may not.
    @Test func theIdentityLeavesTheTileCodesAlone() async throws {
        // FOUR tiles, so each 16:9 source fills its own 16:9 cell exactly and
        // there are no letterbox bars. That is not a detail: with two tiles the
        // cells are 8:9, the picture is barred top and bottom, and the
        // nameplate sits over the BAR — where a sample cannot tell a plate over
        // black from black. A planted "never composite the badge" passed
        // against exactly that before this was noticed.
        let codes: [UInt8] = [0x40, 0xC0, 0x60, 0xA0]
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        composer.setCameraCount(4)
        for camera: Int in 0..<4 {
            composer.setIdentity(.camera(label: "CAM \(camera)",
                                         recording: camera == 0,
                                         signalPresent: true),
                                 camera: camera)
            composer.setClock("01:00:00:0\(camera)", camera: camera)
        }
        for camera: Int in 1..<4 {
            composer.offer(try ComposerProbe.buffer(code: codes[camera],
                                                    width: 640, height: 360),
                           camera: camera, framesPerSecond: 0)
        }
        composer.offer(try ComposerProbe.buffer(code: codes[0], width: 640,
                                                height: 360),
                       camera: 0, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count > 0 })
        let out: CVPixelBuffer = try #require(composed.latest)

        for camera: Int in 0..<4 {
            check(out, camera: camera, code: Int(codes[camera]), in: canvas)
        }
        composer.stop()
    }

    /// One tile of the composed frame: its picture untouched in the middle, and
    /// BOTH badge corners darkened by a plate.
    ///
    /// The two corners are checked separately on purpose. A composite that drew
    /// the names and silently dropped every timecode would satisfy every other
    /// assertion in this file — the clocks are pushed, cached and rasterized on
    /// their own, so nothing else notices whether they reach the picture.
    private func check(_ out: CVPixelBuffer, camera: Int, code: Int,
                       in canvas: CGRect) {
        let cell = MultiviewComposer.cell(camera: camera, cameras: 4,
                                          in: canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        // the sampler reads top row first; the layout is bottom-left origin
        func row(_ ciY: CGFloat) -> Int { Int(canvas.height - 1 - ciY) }
        /// One inset in from a plate's left edge: inside it, and short of where
        /// the lamp and the text begin, so no glyph can be what is read.
        func inside(_ origin: CGPoint) -> Int {
            ComposerProbe.level(of: out, atX: Int(origin.x + metrics.textInset / 2),
                                y: row(origin.y + metrics.plateHeight / 2))
        }
        let middle: Int = ComposerProbe.level(of: out, atX: Int(cell.midX),
                                              y: row(cell.midY))
        #expect(middle == code, "camera \(camera)'s middle read \(middle)")

        let under = inside(metrics.nameplateOrigin(in: cell,
                                                   height: metrics.plateHeight))
        #expect(under < code,
                "camera \(camera) read \(under), no nameplate on the picture")
        let below = inside(metrics.clockOrigin(in: cell))
        #expect(below < code,
                "camera \(camera) read \(below), no clock on the picture")
    }

    /// **The single-camera pass-through survives exactly as far as "nothing to
    /// say", and that is the price of the label stated as a test.**
    ///
    /// An anonymous single camera is handed straight back — 0.010 ms, no render
    /// at all — and that has to keep being true, because it is the ordinary rig.
    /// The moment it has a name it cannot be: the only buffer that could be
    /// handed back is the CLEAN picture other consumers are sharing, and burning
    /// a label into that is the one thing `LivePicture` exists to prevent. So
    /// the second half asserts the cost rather than hiding it.
    @Test func aSingleCameraIsHandedBackUntilItHasANameToShow() async throws {
        let composed = ComposedFrames()
        let composer = MultiviewComposer { buffer, rate in
            composed.record(buffer, rate: rate)
        }
        let source: CVPixelBuffer = try ComposerProbe.buffer(code: 0x77,
                                                             width: 320,
                                                             height: 180)
        composer.offer(source, camera: 0, framesPerSecond: 25)
        #expect(await ControllerWait.untilWritten { composed.count > 0 })
        #expect(composed.latest === source,
                "an anonymous single camera cost a render pass")

        composer.setIdentity(.camera(label: "A CAM", recording: true, signalPresent: true), camera: 0)
        composed.arm()
        composer.offer(source, camera: 0, framesPerSecond: 25)
        composed.waitForFrame()
        let labelled: CVPixelBuffer = try #require(composed.latest)
        #expect(labelled !== source,
                "a named single camera was handed back unlabelled")
        #expect(CVPixelBufferGetWidth(labelled) == 320,
                "the labelled canvas left camera 0's raster")
        composer.stop()
    }

    /// **A camera that goes away takes its name with it.**
    ///
    /// The worse half of a stale tile. A picture left behind at least looks like
    /// a picture; a NAME left behind sits over whatever tile inherits that cell
    /// and asserts it is a camera that is no longer in the session — which is
    /// the one failure a labelling feature can introduce that not labelling
    /// could not.
    ///
    /// Read off the composer's held state rather than out of the picture,
    /// because a name is glyphs and glyphs are what this suite may not read.
    @Test func aCameraThatGoesAwayTakesItsNameWithIt() {
        let composer = MultiviewComposer { _, _ in }
        composer.setCameraCount(3)
        composer.setIdentity(.camera(label: "A", recording: false, signalPresent: true), camera: 0)
        composer.setIdentity(.camera(label: "B", recording: true, signalPresent: true), camera: 1)
        composer.setIdentity(.camera(label: "C", recording: false, signalPresent: true), camera: 2)
        composer.setClock("01:00:00:00", camera: 2)
        #expect(composer.heldIdentity(camera: 2) != nil)

        composer.setCameraCount(2)
        #expect(composer.heldIdentity(camera: 2) == nil,
                "C's name outlived C")
        #expect(composer.heldClock(camera: 2) == nil,
                "C's clock outlived C")
        #expect(composer.heldIdentity(camera: 1)
                    == .camera(label: "B", recording: true, signalPresent: true),
                "the reshape took a camera that was still there")
        composer.stop()
    }

    // MARK: - the cost

    /// **What the identity adds to a compose**, in the four states that
    /// actually occur, against the same pass with no identity at all.
    ///
    ///     TAKESHOT_BENCH=1 scripts/test.sh --filter MultiviewIdentity
    ///
    /// Opt-in and asserting on nothing, like every other timing in this
    /// project: the suite shares a machine with whatever else is building on
    /// it. The MINIMUM is the number to compare across builds, being the run
    /// that got a whole core to itself.
    ///
    /// The four states are the ones the caching rule is about:
    ///
    /// - **anonymous** — the pass exactly as it was before this change, which
    ///   is the baseline every other row is read against;
    /// - **settled** — names and lamps up, clocks frozen. Every badge is a
    ///   cache hit, so what is measured is the COMPOSITE alone: two more
    ///   layers per tile in the CoreImage graph and nothing else. This is a
    ///   paused comparison, and it is also a live grid between timecode ticks;
    /// - **rolling** — the clock changes on every single compose, so every
    ///   tile pays one fresh CoreText line per frame on top of the composite.
    ///   This is the live grid at rate;
    /// - **dark** — rolling, and every board is also showing the "no signal"
    ///   legend. One MORE composited layer per tile, and it is the worst case
    ///   there is. Its badge is a cache hit throughout, however fast the boards
    ///   flap, because the key is what is drawn and the legend's picture does
    ///   not change with the state that decides whether to draw it — so what
    ///   this row measures is the composite and nothing else.
    ///
    /// The figures to compare against are the ones already in CLAUDE.md for
    /// this same pass: one camera 0.010 ms (the pass-through, not a render),
    /// two cameras 0.72 ms at 1080p and 1.44 at UHD, four cameras 0.87 and
    /// 1.96 — and 6.0 ms at 1080p / 21.2 at UHD for the H.264 encode that
    /// follows every one of them.
    @Test(.enabled(if: ComposerProbe.timed))
    func whatTheIdentityAddsPerFrame() async throws {
        for (name, width, height) in [("1080p", 1920, 1080),
                                      ("UHD", 3840, 2160)] {
            for cameras: Int in [1, 2, 4] {
                for state in ["anonymous", "settled", "rolling", "dark"] {
                    try time(name, width: width, height: height,
                             cameras: cameras, state: state)
                }
            }
        }
    }

    /// One row of the table: `cameras` tiles at `width` x `height`, in one of
    /// the four states, timed over twenty runs after five warm ones.
    private func time(_ name: String, width: Int, height: Int, cameras: Int,
                      state: String) throws {
                    let composed = ComposedFrames()
                    let composer = MultiviewComposer { buffer, rate in
                        composed.record(buffer, rate: rate)
                    }
                    composer.setCameraCount(cameras)
                    if state != "anonymous" {
                        for camera: Int in 0..<cameras {
                            composer.setIdentity(
                                .camera(label: "CAM \(camera)",
                                        recording: camera == 0,
                                        signalPresent: state != "dark"),
                                camera: camera)
                            composer.setClock("10:00:00:00", camera: camera)
                        }
                    }
                    for camera: Int in 1..<max(1, cameras) {
                        composer.offer(try ComposerProbe.buffer(
                            code: 0x80, width: width, height: height),
                                       camera: camera, framesPerSecond: 25)
                    }
                    let lead: CVPixelBuffer = try ComposerProbe.buffer(
                        code: 0x40, width: width, height: height)
                    var samples: [Double] = []
                    for run: Int in 0..<25 {
                        if state == "rolling" || state == "dark" {
                            for camera: Int in 0..<cameras {
                                composer.setClock(
                                    String(format: "10:00:%02d:%02d",
                                           run / 25, run % 25),
                                    camera: camera)
                            }
                        }
                        // Signalled rather than polled: a poll interval is tens
                        // of milliseconds and would BE the measurement.
                        composed.arm()
                        let start = DispatchTime.now().uptimeNanoseconds
                        composer.offer(lead, camera: 0, framesPerSecond: 25)
                        composed.waitForFrame()
                        let elapsed = Double(
                            DispatchTime.now().uptimeNanoseconds - start)
                            / 1_000_000
                        if run >= 5 { samples.append(elapsed) } // warm it
                    }
                    samples.sort()
                    print(String(
                        format: "IDENTITYBENCH %@ x%d %@: min %.3f ms  median %.3f ms",
                        name, cameras, state, samples[0],
                        samples[samples.count / 2]))
                    composer.stop()
    }
}
