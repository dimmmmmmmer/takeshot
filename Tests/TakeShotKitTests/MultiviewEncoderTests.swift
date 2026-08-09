import AppKit
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The encoder on its own: the downscale, the JPEG, and the pace — no server,
/// no socket, a known frame in and bytes out.
@Suite @MainActor struct MultiviewEncoderTests {
    /// What the sink was handed, lock-boxed off the encoder's queue.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(camera: Int, jpeg: Data)] = []

        func record(_ camera: Int, _ jpeg: Data) {
            lock.withLock { frames.append((camera, jpeg)) }
        }

        var count: Int { lock.withLock { frames.count } }
        var cameras: Set<Int> { lock.withLock { Set(frames.map(\.camera)) } }
        var lastJPEG: Data? { lock.withLock { frames.last?.jpeg } }
    }

    /// The promised downscale: long edge to whichever rung of the ladder the
    /// page's layout asks for, aspect kept, and a frame already smaller passes
    /// through unscaled.
    @Test func aFrameIsDownscaledToThePhoneCeiling() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let full = MediaFixtures.pixelBuffer(level: 0x60, width: 1920,
                                             height: 1080)
        let rungs: [(edge: CGFloat, tile: CGSize)] = [
            (MultiviewEncoder.soloEdge, CGSize(width: 1280, height: 720)),
            (MultiviewEncoder.pairEdge, CGSize(width: 960, height: 540)),
            (MultiviewEncoder.gridEdge, CGSize(width: 640, height: 360)),
        ]
        for rung in rungs {
            let jpeg = try #require(MultiviewEncoder.jpeg(from: full,
                                                          context: context,
                                                          maxEdge: rung.edge))
            #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
            let image = try #require(NSBitmapImageRep(data: jpeg))
            #expect(image.pixelsWide == Int(rung.tile.width), "edge \(rung.edge)")
            #expect(image.pixelsHigh == Int(rung.tile.height), "edge \(rung.edge)")
        }

        let small = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        let smallJPEG = try #require(
            MultiviewEncoder.jpeg(from: small, context: context,
                                  maxEdge: MultiviewEncoder.gridEdge))
        let smallImage = try #require(NSBitmapImageRep(data: smallJPEG))
        #expect(smallImage.pixelsWide == 320,
                "a frame under the ceiling was upscaled")
    }

    /// The ladder itself: one camera fills the phone, two split it, three or
    /// more land in a 2-across grid, and a tile never grows as the grid does.
    ///
    /// A count of zero can reach this — the taps are installed before the first
    /// status names a camera — and has to answer as one would, not as a grid.
    @Test func theTileLadderFollowsThePagesLayout() {
        #expect(MultiviewEncoder.maximumEdge(cameras: 0)
            == MultiviewEncoder.soloEdge)
        #expect(MultiviewEncoder.maximumEdge(cameras: 1)
            == MultiviewEncoder.soloEdge)
        #expect(MultiviewEncoder.maximumEdge(cameras: 2)
            == MultiviewEncoder.pairEdge)
        for count in 3...9 {
            #expect(MultiviewEncoder.maximumEdge(cameras: count)
                == MultiviewEncoder.gridEdge, "\(count) cameras")
        }
        #expect(MultiviewEncoder.soloEdge > MultiviewEncoder.pairEdge)
        #expect(MultiviewEncoder.pairEdge > MultiviewEncoder.gridEdge)
    }

    /// The downscale band-limits the frame instead of folding what it drops
    /// back on top of it.
    ///
    /// This is what an affine transform does not do, and it was the real fault
    /// behind "poor resolution": `transformed(by:)` resamples with the
    /// sampler's own two-tap filter, so on the way from 1920 to 640 everything
    /// above the target's Nyquist comes back as moire. The subject is a zone
    /// plate — local frequency rising with radius — and the band measured is
    /// the one past the target's Nyquist, which a filtered reduction returns as
    /// flat grey.
    ///
    /// 1920 down to the grid rung is a 3x reduction, so the target's Nyquist
    /// sits a third of the way out and the band from 1.5x to 2.4x of it is
    /// unambiguously stopband. Measured through the app's own encode: the
    /// affine transform 18.9 codes of standard deviation, Lanczos 1.5.
    @Test func theDownscaleBandLimitsInsteadOfFoldingDetailBack() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let plate = MultiviewFixtures.zonePlate(width: 1920, height: 1080)
        let jpeg = try #require(
            MultiviewEncoder.jpeg(from: plate, context: context,
                                  maxEdge: MultiviewEncoder.gridEdge))
        let image = try #require(NSBitmapImageRep(data: jpeg))
        let spread = try MultiviewFixtures.pastNyquistSpread(image, from: 0.5,
                                                             to: 0.8)
        print(String(format: "MULTIVIEWBENCH aliasing: sd %.2f codes", spread))
        // Wide of the 1.5 measured and a long way under the 18.9 the affine
        // transform produced: what is being caught is a reduction that stopped
        // filtering, not a code of encoder drift.
        #expect(spread < 6,
                "the reduction folded past-Nyquist detail back: \(spread)")
    }

    /// The frame's own edge survives the reduction.
    ///
    /// Lanczos reaches three output pixels past each side, and off the edge of
    /// an unclamped CIImage is transparent black: a flat 128 field came back
    /// with its corner at 112 before the clamp went in. On a picture that is a
    /// dark vignette on every tile.
    @Test func theReducedFrameIsNotDarkenedAtItsEdge() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let grey: UInt8 = 0x80
        let flat = MediaFixtures.pixelBuffer(level: grey, width: 1920,
                                             height: 1080)
        let jpeg = try #require(
            MultiviewEncoder.jpeg(from: flat, context: context,
                                  maxEdge: MultiviewEncoder.gridEdge))
        let image = try #require(NSBitmapImageRep(data: jpeg))
        for (label, x, y) in [("corner", 0, 0),
                              ("top edge", image.pixelsWide / 2, 0),
                              ("centre", image.pixelsWide / 2,
                               image.pixelsHigh / 2)] {
            let level: Int = try MultiviewFixtures.level(image, x: x, y: y)
            #expect(abs(level - Int(grey)) <= 6,
                    "\(label) came back at \(level) for \(grey)")
        }
    }

    /// The tile is the app's own picture, not a re-grade of it (owner item
    /// 13a).
    ///
    /// The display path's contract is that the buffer holds 709-encoded code
    /// values and every surface says so rather than converting them. The
    /// encoder used to read the buffer without naming a space — CoreImage then
    /// guesses, and guesses sRGB for a buffer carrying no colour attachments —
    /// and write 709, which turns the guess into a gamma conversion the app
    /// performs nowhere else. A known grey has to come back as itself.
    @Test func aKnownGreyEncodesBackAsItself() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let grey: UInt8 = 0x80
        let frame = MediaFixtures.pixelBuffer(level: grey, width: 320,
                                              height: 180)
        let jpeg = try #require(
            MultiviewEncoder.jpeg(from: frame, context: context,
                                  maxEdge: MultiviewEncoder.gridEdge))
        let image = try #require(NSBitmapImageRep(data: jpeg))
        // The raw samples, not `colorAt` — that answers in a colour space, and
        // converting the answer is the very operation under test.
        let level: Int = try MultiviewFixtures.level(image,
                                                     x: image.pixelsWide / 2,
                                                     y: image.pixelsHigh / 2)
        // JPEG moves a flat field by a code or two at any quality; the sRGB
        // reading the encoder used to take moves 0x80 by about twenty.
        #expect(abs(level - Int(grey)) <= 6,
                "the encoder re-graded the frame: \(level) for \(grey)")
    }

    /// Latest-wins under the pace: a burst of offers produces the first pass
    /// at once and at most ONE coalesced pass behind it — never a pass per
    /// offer, which is what would make a 25 fps wire cost 25 encodes.
    @Test func aBurstOfOffersCoalescesToThePace() async throws {
        let sink = FrameSink()
        let encoder = MultiviewEncoder { camera, jpeg in
            sink.record(camera, jpeg)
        }
        let frame = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        for _ in 0..<25 { encoder.offer(frame, camera: 0) }

        let encoded = await ControllerWait.until { sink.count >= 1 }
        #expect(encoded, "nothing came out of the encoder")
        // Full-budget wait covering the pace interval with room to spare: the
        // burst may add one trailing pass and may never add a third.
        _ = await ControllerWait.until({ sink.count > 2 }, timeout: .seconds(2))
        #expect(sink.count <= 2,
                "25 offers in one burst encoded \(sink.count) times")
    }

    /// The cameras pace independently — B-cam's frames never wait out A-cam's
    /// interval.
    @Test func camerasAreEncodedIndependently() async throws {
        let sink = FrameSink()
        let encoder = MultiviewEncoder { camera, jpeg in
            sink.record(camera, jpeg)
        }
        let frame = MediaFixtures.pixelBuffer(level: 0x60, width: 320,
                                              height: 180)
        encoder.offer(frame, camera: 0)
        encoder.offer(frame, camera: 1)
        let both = await ControllerWait.until { sink.cameras == [0, 1] }
        #expect(both, "the second camera waited on the first one's pace")
    }

    /// The count the controller hands over is what sizes the tile, and it
    /// takes effect on a running encoder — a multicam switch mid-shift
    /// reshapes the grid on the phone without a reconnect.
    @Test func theCameraCountSizesTheTile() async throws {
        let sink = FrameSink()
        let encoder = MultiviewEncoder { camera, jpeg in
            sink.record(camera, jpeg)
        }
        let frame = MediaFixtures.pixelBuffer(level: 0x60, width: 1920,
                                              height: 1080)
        for (count, expected) in [(1, 1280), (4, 640)] {
            encoder.setCameraCount(count)
            let before: Int = sink.count
            encoder.offer(frame, camera: 0)
            let arrived = await ControllerWait.until { sink.count > before }
            #expect(arrived, "\(count) cameras: nothing came out")
            let jpeg = try #require(sink.lastJPEG)
            let image = try #require(NSBitmapImageRep(data: jpeg))
            #expect(image.pixelsWide == expected,
                    "\(count) cameras encoded \(image.pixelsWide) across")
        }
    }
}

/// Subjects for the reduction the tiles go through, and the one measurement
/// that says whether it filtered or aliased.
enum MultiviewFixtures {
    /// A zone plate: local spatial frequency rises with the radius, from DC at
    /// the centre to the source's own Nyquist at the edge. Anything past the
    /// TARGET's Nyquist is what a reduction must remove — an unfiltered one
    /// folds it back as moire rings instead.
    static func zonePlate(width: Int, height: Int) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let buffer = out else {
            fatalError("could not allocate a \(width)x\(height) plate")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            return buffer
        }
        let base = address.assumingMemoryBound(to: UInt8.self)
        let rowBytes: Int = CVPixelBufferGetBytesPerRow(buffer)
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                let dx: Double = Double(x) - cx
                let dy: Double = Double(y) - cy
                // 480 puts the source's own Nyquist at the horizontal edge, so
                // the target's Nyquist for a 3x reduction sits a third of the
                // way out and the band below is comfortably past it.
                let phase: Double = .pi * 480 * (dx * dx + dy * dy) / (cx * cx)
                let value: Double = 0.5 + 0.45 * cos(phase)
                let code = UInt8(max(0, min(255, value * 255)))
                row[x * 4] = code
                row[x * 4 + 1] = code
                row[x * 4 + 2] = code
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// A deterministic stand-in for a frame of footage: seven octaves of value
    /// noise at 1/f, which is roughly the amplitude spectrum real pictures
    /// have, with a low-frequency colour cast over it.
    ///
    /// The spectrum is the whole point. What a JPEG costs is almost entirely a
    /// function of it, and the fixtures the rest of the suite uses — a flat
    /// field, the demo source's colour bars — have next to none, so they encode
    /// to a couple of kilobytes at any setting and would say every quality and
    /// every size cost the same. Deterministic so the byte counts asserted
    /// against it are a fact about the constants rather than about a run.
    static func naturalFrame(width: Int, height: Int) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let buffer = out else {
            fatalError("could not allocate a \(width)x\(height) frame")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            return buffer
        }
        let base = address.assumingMemoryBound(to: UInt8.self)
        let rowBytes: Int = CVPixelBufferGetBytesPerRow(buffer)
        let luma: [[Double]] = (0..<octaves).map { octave in
            noiseGrid(seed: 0x9E37 &+ UInt64(octave) &* 7717,
                      side: 1 << (octave + 1))
        }
        let castR: [Double] = noiseGrid(seed: 0xBEEF, side: 8)
        let castB: [Double] = noiseGrid(seed: 0xF00D, side: 8)
        for y in 0..<height {
            let row = base + y * rowBytes
            let fy = Double(y) / Double(height)
            for x in 0..<width {
                let fx = Double(x) / Double(width)
                // Studio-swing-ish excursion, so the encoder sees the range a
                // display buffer really carries.
                let level: Double = 0.06 + octaveSum(luma, fx, fy) * 0.86
                let red: Double = level
                    * (0.85 + 0.30 * noiseAt(castR, side: 8, fx, fy))
                let blue: Double = level
                    * (0.85 + 0.30 * noiseAt(castB, side: 8, fx, fy))
                row[x * 4] = code(blue)
                row[x * 4 + 1] = code(level)
                row[x * 4 + 2] = code(red)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// How many octaves `naturalFrame` sums. Seven puts the finest one at a
    /// 128-cell lattice across a 1080p frame — about 15 px, which is where a
    /// real picture still has plenty of energy and JPEG still spends bytes.
    private static let octaves = 7

    /// The octaves at one point, normalized to 0...1 with each half the
    /// amplitude of the one below it — the 1/f falloff that makes this look
    /// like a picture to an encoder rather than like noise.
    private static func octaveSum(_ grids: [[Double]],
                                  _ fx: Double, _ fy: Double) -> Double {
        var value = 0.0
        var amplitude = 0.5
        var total = 0.0
        for octave in 0..<octaves {
            value += amplitude * noiseAt(grids[octave],
                                         side: 1 << (octave + 1), fx, fy)
            total += amplitude
            amplitude *= 0.5
        }
        return value / total
    }

    private static func code(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value * 255)))
    }

    /// `side * side` values in 0..<1 from a fixed seed — xorshift, so the same
    /// grid comes out on every machine and every release.
    private static func noiseGrid(seed: UInt64, side: Int) -> [Double] {
        var state: UInt64 = seed | 1
        return (0..<(side * side)).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 100_000) / 100_000
        }
    }

    /// One grid, sampled with smoothstep interpolation and wrapped — which is
    /// what turns a lattice of random values into an octave of noise.
    private static func noiseAt(_ grid: [Double], side: Int,
                                _ fx: Double, _ fy: Double) -> Double {
        let x: Double = fx * Double(side)
        let y: Double = fy * Double(side)
        let x0: Int = Int(x) % side
        let y0: Int = Int(y) % side
        let x1: Int = (x0 + 1) % side
        let y1: Int = (y0 + 1) % side
        let tx: Double = smoothstep(x - Double(Int(x)))
        let ty: Double = smoothstep(y - Double(Int(y)))
        let top: Double = grid[y0 * side + x0] * (1 - tx)
            + grid[y0 * side + x1] * tx
        let bottom: Double = grid[y1 * side + x0] * (1 - tx)
            + grid[y1 * side + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    private static func smoothstep(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    /// One decoded sample, by pixel.
    ///
    /// The stride is `bitsPerPixel`, NOT `samplesPerPixel`: a JPEG decoded into
    /// an `NSBitmapImageRep` here reports three samples in THIRTY-TWO bits, so
    /// stepping three bytes per pixel walks off the row a quarter faster than
    /// the picture does. On a flat field that reads the same everywhere and
    /// hides itself; on a picture it silently samples the wrong place, which is
    /// exactly how the aliasing measurement below first came back as noise.
    static func level(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> Int {
        let base = try #require(image.bitmapData)
        let stride: Int = image.bitsPerPixel / 8
        return Int(base[y * image.bytesPerRow + x * stride])
    }

    /// Standard deviation, in codes, over the annulus of a reduced zone plate
    /// whose detail was past the target's Nyquist. A filtered reduction returns
    /// flat grey there and answers near zero; an aliased one returns the moire
    /// and answers in the teens.
    ///
    /// The band is given in radii normalized to the output's half WIDTH, on
    /// both axes, so it means one frequency however it is measured from the
    /// centre. Which radii are past Nyquist depends on the reduction, so the
    /// caller states them.
    static func pastNyquistSpread(_ image: NSBitmapImageRep,
                                  from inner: Double,
                                  to outer: Double) throws -> Double {
        let base = try #require(image.bitmapData)
        let stride: Int = image.bitsPerPixel / 8
        let cx = Double(image.pixelsWide) / 2
        let cy = Double(image.pixelsHigh) / 2
        var values: [Double] = []
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let dx: Double = (Double(x) - cx) / cx
                let dy: Double = (Double(y) - cy) / cx
                let radius: Double = (dx * dx + dy * dy).squareRoot()
                guard radius > inner, radius < outer else { continue }
                values.append(Double(base[y * image.bytesPerRow + x * stride]))
            }
        }
        guard !values.isEmpty else { return 0 }
        let mean: Double = values.reduce(0, +) / Double(values.count)
        let variance: Double = values
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }
}
