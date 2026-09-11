import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation

/// One clip's frame path: the picture's own levels, then the burn-ins (and the
/// downscale, when the source is larger than the daily) composited onto each
/// decoded frame.
///
/// Built once per item — the overlay pre-renders its static strips here, and
/// only the timecode text is re-drawn frame to frame (see `DailiesOverlay`).
final class DailiesFrameComposer {
    private let overlay: DailiesOverlay
    /// nil — the timecode burn-in is off and no clock is computed at all.
    private let timeline: DailiesTimeline?
    private let outputSize: CGSize
    /// The source's own levels lookup; nil — the picture is left alone.
    private let levels: [UInt8]?
    /// What the source file said its codes mean. Read at probe time, so a
    /// mid-run anything cannot change the answer under the frame loop.
    private let colorimetry: WireColorimetry
    /// Scaled-path frames come from here rather than fresh allocations.
    private let pool = PixelBufferPool()
    /// **The look being baked into the proxy**, as the same `CIColorCube`
    /// filter the live path and the player build from a `.cube`
    /// (`CubeLUT.makeFilter`) — one look, one implementation, so a daily
    /// cannot come out graded differently from the review it was made from.
    ///
    /// nil is every daily this app made before the option existed, and every
    /// run with the switch off: the frame is handed on untouched, byte for
    /// byte (`anSDRTakeIsUntouchedByAllOfThis`).
    private let look: CIFilter?
    private let lookIntensity: Double
    /// **The source's gamut, converted into Rec.709**, as one more cube on the
    /// same stage as the look (`CubeLUT.gamut`). nil for a source that is
    /// already on Rec.709 primaries, which is every 709 camera original and
    /// every take this app records off an SDR wire — by far the ordinary case,
    /// and it pays nothing.
    private let gamut: CIFilter?
    /// Its own pool, not the scaling one: a graded frame is still in use as
    /// the SOURCE of the scaled blit, so the two must never be handed the same
    /// buffer.
    private let lookPool = PixelBufferPool()
    /// Built once per item rather than per frame, and told not to cache: this
    /// runs over every frame of a clip at `.utility` while a shoot may be
    /// going on, and the intermediates are a frame-sized allocation each.
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    init(item: DailiesItem, burnins: DailiesBurnins,
         facts: DailiesSourceFacts, look: CubeLUT? = nil,
         lookIntensity: Double = 1) throws {
        overlay = DailiesOverlay(size: facts.outputSize,
                                 texts: burnins.overlayTexts(for: item))
        timeline = facts.timeline
        outputSize = facts.outputSize
        levels = facts.levels
        colorimetry = facts.colorimetry
        // **A source that already carries a look is not graded again.** The
        // take was recorded with it burned in, says so in its own metadata,
        // and a second pass would put two grades in one file — permanently,
        // in a proxy an editor will cut with. The same rule the player states
        // as `PlaybackLook.baked` outranking everything.
        self.look = facts.bakedLook == nil ? look?.makeFilter() : nil
        self.lookIntensity = lookIntensity
        // **Built here, and a failure to build it fails the ITEM.**
        //
        // The proxy declares Rec.709 unconditionally (`DailiesEngine
        // .videoSettings`), so a frame that did not go through this cube would
        // be Rec.2020 codes in a file that says 709 — a picture every player
        // draws too saturated, with nothing on screen to say why. That is the
        // one outcome worth failing an item over, and it is the same argument
        // the baked look already makes about its own render.
        //
        // A SWITCH and not `exceedsRec709`, so that a third set of primaries
        // ever added to `SignalPrimaries` is a compile error here rather than
        // a silent Rec.2020 conversion applied to something else.
        switch facts.colorimetry.primaries {
        case .rec709:
            gamut = nil
        case .rec2020:
            guard let cube = CubeLUT.rec2020ToRec709,
                  let filter = cube.makeCodeFilter() else {
                throw DailiesAbort.failed(
                    "cannot build the Rec.709 gamut conversion")
            }
            gamut = filter
        }
    }

    /// One decoded frame as the proxy should hold it: levelled, burned in, and
    /// tagged for what its codes now are.
    ///
    /// The ORDER is the whole trap. The lookup is the PICTURE's and only the
    /// picture's, so it runs while the frame is still nothing but picture —
    /// after the strips exist it would tone map them too, and a burn-in whose
    /// white has been rolled down a shoulder is a grey strip that no longer
    /// reads over a blown-out sky, which is the one thing burn-ins are for.
    func compose(_ source: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        if let levels {
            // In place, like the burn-ins below: the decoder hands a fresh
            // buffer per frame and this path is the only thing looking at it.
            StudioSwing.map(source, into: source, table: levels)
        }
        // **The look, then the strips.** The same order and the same reason
        // as the levels lookup above: a grade is the PICTURE's, and applied
        // over the burn-ins it would take the plates and their white with it.
        let frame = try burnedIn(try graded(source), pts: pts)
        // The codes MEAN something else now — an HDR take reaches here on a
        // Rec.709 curve — and a writer-bound buffer that still claims PQ is
        // the tag mismatch this project has already been bitten by: the
        // encoder colour-converts on it, and the file inherits the claim.
        // Always, and the same preset the encode settings state — the two
        // halves of one claim. A buffer tagged differently from the settings
        // is the mismatch VideoToolbox colour-converts on, and an untagged one
        // hands the encoder whatever the decoder attached (or, out of the
        // scaling pool, nothing at all). See `DailiesEngine.videoSettings`.
        ColorTags.tag(frame, preset: DailiesEngine.proxyPreset)
        return frame
    }

    /// The frame with the look baked in, or the frame.
    ///
    /// Raw code values on both ends — `.colorSpace: NSNull()` going in and
    /// `destination.colorSpace = nil` coming out — because a `.cube` is
    /// defined on gamma-encoded codes and every other path in this app renders
    /// it the same way. A colour-managed render here would make the daily
    /// disagree with the picture the operator approved.
    ///
    /// A failed render THROWS rather than handing back the clean frame: a
    /// proxy that says it carries the look and does not is the one outcome
    /// nobody can see and everybody would trust. The item fails, the report
    /// names it, and the rest of the queue runs.
    private func graded(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard look != nil || gamut != nil else { return source }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let destination = lookPool.buffer(width: width, height: height)
        else { throw DailiesAbort.failed("cannot allocate a frame for the look") }
        let input = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
        var image = input
        if let look {
            look.setValue(image, forKey: kCIInputImageKey)
            guard let output = look.outputImage else {
                throw DailiesAbort.failed("the look produced no picture")
            }
            // The intensity mixes the LOOK against the frame it was applied
            // to, so it is spent here — before the gamut stage, which is not
            // a look and has no intensity to be at.
            image = CapturePipeline.mix(source: image, filtered: output,
                                        intensity: lookIntensity)
        }
        if let gamut {
            gamut.setValue(image, forKey: kCIInputImageKey)
            guard let output = gamut.outputImage else {
                throw DailiesAbort.failed("the gamut conversion produced no picture")
            }
            image = output
        }
        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil
        guard let task = try? ciContext.startTask(toRender: image, to: target),
              (try? task.waitUntilCompleted()) != nil else {
            throw DailiesAbort.failed("the look could not be rendered")
        }
        return destination
    }

    /// The frame with its burn-ins: drawn straight onto the decoded buffer
    /// when no scaling is needed (the decoder hands a fresh buffer per frame,
    /// so there is nothing to preserve), or into a pool buffer through one
    /// scaled blit when the source is larger than 1080p.
    private func burnedIn(_ source: CVPixelBuffer,
                          pts: CMTime) throws -> CVPixelBuffer {
        let timecodeText = timeline?.text(atSeconds: pts.seconds)
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        if CVPixelBufferGetWidth(source) == width,
           CVPixelBufferGetHeight(source) == height {
            CVPixelBufferLockBaseAddress(source, [])
            defer { CVPixelBufferUnlockBaseAddress(source, []) }
            guard let context = Self.bgraContext(for: source) else {
                throw DailiesAbort.failed("cannot draw on the frame")
            }
            overlay.draw(in: context, timecodeText: timecodeText)
            return source
        }
        guard let destination = pool.buffer(width: width, height: height) else {
            throw DailiesAbort.failed("cannot allocate a \(width)x\(height) frame")
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let sourceImage = Self.bgraContext(for: source)?.makeImage(),
              let context = Self.bgraContext(for: destination) else {
            throw DailiesAbort.failed("cannot draw on the frame")
        }
        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0,
                                             width: width, height: height))
        overlay.draw(in: context, timecodeText: timecodeText)
        return destination
    }

    /// A CG context over a locked BGRA pixel buffer (the caller holds the
    /// lock for the context's whole lifetime).
    private static func bgraContext(for buffer: CVPixelBuffer) -> CGContext? {
        CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue)
    }
}
