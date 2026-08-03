import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// Tolerance and softness do DIFFERENT jobs, proved in pixels.
///
/// The complaint (owner item 35) was that the two controls felt like one, and
/// it was right about the arithmetic. The feather used to run from `tolerance`
/// to `tolerance + softness`, so widening the softness pushed the outer edge of
/// the key outward and swallowed more of the screen — which is the tolerance's
/// job. Over the shipped ranges (tolerance ≤ 0.6, softness ≤ 0.4) the softness
/// alone could move that edge by two thirds of what the tolerance could, and on
/// a screen with any spread of shades that reads as the same control twice.
///
/// The feather is centred on the tolerance now. The three properties below are
/// what "different jobs" means, and each of them fails against the old curve:
///
///   1. the half-keyed boundary sits at the tolerance, whatever the softness is
///   2. moving the tolerance moves the boundary by exactly as much
///   3. moving the softness leaves the amount keyed alone and changes only how
///      abruptly the matte gets there
struct ChromaKeyControlSeparationTests {
    /// A key on digital green with the two controls set.
    private func key(tolerance: Double, softness: Double) -> ChromaKey {
        var key = ChromaProbe.magentaKey()
        key.spill = 0 // the despill is a separate control and would blur this
        key.tolerance = tolerance
        key.softness = softness
        return key
    }

    /// How much of a sweep out from the screen color survives as subject — the
    /// "how much is keyed" number, as an area under the matte rather than a
    /// single reading, so a boundary that moved by a hair still shows up.
    private func keptFraction(_ key: ChromaKey, steps: Int = 601,
                              reach: Double = 0.6) -> Double {
        var total = 0.0
        for step in 0..<steps {
            total += key.matte(atDistance: Double(step) / Double(steps - 1) * reach)
        }
        return total / Double(steps)
    }

    // MARK: - 1: the boundary is the tolerance

    /// Whatever the softness, the pixel exactly at the tolerance is half keyed.
    /// This is the property the old curve did not have — there the tolerance was
    /// the point at which the matte STARTED to move, so every softness put the
    /// half-keyed point somewhere else.
    @Test func theHalfKeyedPointIsTheToleranceAtEverySoftness() {
        for tolerance in [0.1, 0.2, 0.35, 0.5] {
            for softness in [0.1, 0.5, 0.9, 1.0] {
                let key = key(tolerance: tolerance, softness: softness)
                let matte = key.matte(atDistance: tolerance)
                // not exact: the distance is walked back out through a chroma
                // triple, so the reading carries a square root's worth of slack
                #expect(abs(matte - 0.5) < 0.005,
                        "t=\(tolerance) s=\(softness) is \(matte) at its own boundary")
            }
            // and with no feather at all the boundary is a step, in the same
            // place: keyed just inside it, subject just outside
            let hard = key(tolerance: tolerance, softness: 0)
            #expect(hard.matte(atDistance: tolerance - 0.002) == 0)
            #expect(hard.matte(atDistance: tolerance + 0.002) == 1)
        }
    }

    /// The screen color itself is ALWAYS fully keyed, however wide the feather
    /// is — a relative feather cannot reach back past zero, which an absolute
    /// one centred on the tolerance could.
    @Test func theScreenColorIsFullyKeyedAtEverySoftness() {
        for softness in [0.0, 0.5, 1.0] {
            let key = key(tolerance: 0.05, softness: softness)
            #expect(key.matte(for: ChromaProbe.digitalGreen) == 0,
                    "softness \(softness) left the screen color partly opaque")
        }
    }

    // MARK: - 2: the tolerance moves the boundary

    /// The boundary lands where the tolerance is put, to within the resolution
    /// of the sweep, and more tolerance keeps more of the frame.
    @Test func theToleranceIsTheOnlyControlThatMovesTheBoundary() {
        var previousKept = Double.infinity
        for tolerance in [0.1, 0.2, 0.3, 0.4] {
            let key = key(tolerance: tolerance, softness: 0.5)
            // the crossing point of the matte, found on the sweep
            let crossing = stride(from: 0.0, through: 0.6, by: 0.001)
                .first { key.matte(atDistance: $0) >= 0.5 } ?? -1
            #expect(abs(crossing - tolerance) < 0.002,
                    "tolerance \(tolerance) put the boundary at \(crossing)")

            let kept = keptFraction(key)
            #expect(kept < previousKept,
                    "widening to \(tolerance) did not key more of the frame")
            previousKept = kept
        }
    }

    // MARK: - 3: the softness does not move it

    /// Softness leaves the amount keyed where it is. The area under the matte
    /// is unchanged to within a fraction of a percent across the whole range —
    /// a symmetric ramp gives back on one side exactly what it takes on the
    /// other — while the WIDTH of the transition goes from nothing to the full
    /// span of the key.
    @Test func theSoftnessChangesTheEdgeAndNotTheAmountKeyed() {
        let tolerance = 0.3
        let hard = key(tolerance: tolerance, softness: 0)
        let baseline = keptFraction(hard)
        var previousWidth = -1.0

        for softness in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let key = key(tolerance: tolerance, softness: softness)
            let kept = keptFraction(key)
            #expect(abs(kept - baseline) < 0.002,
                    "softness \(softness) keyed \(kept) against \(baseline)")

            // how far the matte takes to get from 10% to 90%
            let range = key.featherRange
            let width = range.upperBound - range.lowerBound
            #expect(abs(width - 2 * tolerance * softness) < 0.000_001)
            #expect(width > previousWidth,
                    "softness \(softness) did not widen the edge")
            previousWidth = width
        }
    }

    /// And the two are not interchangeable on a REAL sweep of shades: a screen
    /// that comes back over a spread of chroma distances is keyed by the
    /// tolerance and feathered by the softness, and swapping which one is moved
    /// gives measurably different pictures.
    ///
    /// The numbers here are the whole argument for the change. Against the old
    /// curve the two columns were near enough identical, which is exactly what
    /// the operator was reporting.
    @Test func theTwoControlsProduceDifferentPictures() {
        let base = key(tolerance: 0.3, softness: 0.3)
        // the same amount of "more" applied to each control
        let widerTolerance = key(tolerance: 0.42, softness: 0.3)
        let softerEdge = key(tolerance: 0.3, softness: 0.9)

        let baseKept = keptFraction(base)
        let toleranceKept = keptFraction(widerTolerance)
        let softnessKept = keptFraction(softerEdge)

        #expect(baseKept - toleranceKept > 0.15,
                "the tolerance barely changed what is keyed: \(toleranceKept)")
        #expect(abs(baseKept - softnessKept) < 0.002,
                "the softness changed what is keyed: \(softnessKept)")

        // …and the softness is the control that changes how many shades land in
        // between rather than on one side or the other
        func partialCount(_ key: ChromaKey) -> Int {
            stride(from: 0.0, through: 0.6, by: 0.001).count {
                let matte = key.matte(atDistance: $0)
                return matte > 0.001 && matte < 0.999
            }
        }
        #expect(partialCount(softerEdge) > partialCount(base) * 2,
                "the softness did not widen the transition")

        // The tolerance carries the feather along with it — a wider key wants a
        // proportionally wider edge, and that is deliberate — but the RATIO it
        // is set to is the softness's alone, and only the softness changes it.
        func relativeWidth(_ key: ChromaKey) -> Double {
            let range = key.featherRange
            return (range.upperBound - range.lowerBound) / key.tolerance
        }
        #expect(abs(relativeWidth(widerTolerance) - relativeWidth(base)) < 1e-9,
                "the tolerance changed the edge the softness had been set to")
        #expect(relativeWidth(softerEdge) - relativeWidth(base) > 1,
                "the softness did not change the edge")
    }

    // MARK: - through the renderer

    /// The separation reaches the screen, not just the arithmetic: a frame of
    /// graded shades keyed twice, once with more tolerance and once with more
    /// softness, comes back with a different number of fully-replaced pixels
    /// from the first and the same number from the second.
    @Test func theSeparationSurvivesTheCubeAndTheGPU() async throws {
        // a horizontal ramp from the screen color out towards grey: every
        // column is a different chroma distance, which is the axis both
        // controls act on
        let width = 128
        let height = 8
        let buffer = TestMedia.pixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    let mix = Double(x) / Double(width - 1)
                    let color = ChromaKey.RGB(mix * 0.5, 1 - mix * 0.5, mix * 0.5)
                    row[x * 4] = ChromaProbe.byte(color.blue)
                    row[x * 4 + 1] = ChromaProbe.byte(color.green)
                    row[x * 4 + 2] = ChromaProbe.byte(color.red)
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        /// How much of the ramp survived as subject, read off the rendered
        /// frame: 0 = the whole ramp was keyed away, 1 = none of it was.
        ///
        /// Read through the MATTE view, which paints the alpha itself as a
        /// black-and-white picture, so every pixel is the matte and nothing
        /// else. (The composited view would work too, but there the cube's
        /// entries are premultiplied — the green channel carries `source ·
        /// matte`, and the lattice interpolates the product rather than the
        /// factor the test is about.) Summed over the whole ramp rather than
        /// read at the crossing: the cube is a 32³ lattice and one reading in
        /// the middle of a feather carries the error of the two points it sits
        /// between.
        func survivingFraction(_ key: ChromaKey) async throws -> Double {
            var matteView = key
            matteView.background = .matte
            let pipeline = PreviewProbe.makePipeline()
            pipeline.setChromaKey(matteView)
            let shown = try await ChromaProbe.presented(pipeline, buffer)
            var total = 0.0
            for x in 0..<width {
                let pixel = ChromaProbe.pixel(
                    of: shown, atFractionX: (Double(x) + 0.5) / Double(width))
                total += Double(pixel.g) / 255
            }
            return total / Double(width)
        }

        let base = try await survivingFraction(key(tolerance: 0.3, softness: 0.3))
        let wider = try await survivingFraction(key(tolerance: 0.42, softness: 0.3))
        let softer = try await survivingFraction(key(tolerance: 0.3, softness: 0.9))

        // this ramp reaches 0.596 of chroma distance, so a boundary at 0.3
        // leaves just under half of it standing
        #expect(abs(base - 0.5) < 0.04, "the base key left \(base) of the ramp")
        #expect(base - wider > 0.15,
                "more tolerance took \(base - wider) more of the ramp")
        #expect(abs(base - softer) < 0.02,
                "more softness changed what is keyed by \(abs(base - softer))")
    }
}
