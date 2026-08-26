@preconcurrency import CoreVideo
import Foundation

/// One frame's worth of scope data: per-channel waveform density maps, RGB/luma
/// histograms, a vectorscope density map and a CIE chromaticity map. Computed on
/// the CPU from a fixed sampling grid, on the scope queue — ~25 ms per 1080p
/// frame in release on an idle machine, whatever the content and whatever the
/// frame size, against a stride interval of 80 ms at 25 fps and 67 ms at 60.
/// That is what makes a ~15 Hz update rate affordable.
///
/// The chromaticity map cost about 2 ms of that when it was added — measured as
/// a PAIRED A/B in release, one line toggled and the two arms run alternately
/// three times over, because the machine drifts by more than the effect between
/// one run and the next: the best 1080p pass was 23.6-24.1 ms without the map
/// and 25.5-26.6 ms with it, across all four source formats. That is ~7 ns per
/// grid sample for three table lookups, a 3×3 and a split deposit, and it is
/// this small only because it is one more accumulation in the SAME walk — a
/// second pass over the frame would have cost the walk again.
///
/// It is 2.5 % of the 80 ms stride interval at 25 fps, and the delivered rate
/// is unchanged: 20 of 20 offered passes still land.
///
/// It was ~12 ms while the trace maps were 512 columns wide. Doubling them
/// doubled the sampling grid and every sweep over it, and the horizontal blur
/// that came out at the same time gave 8 % of it back; the delivered rate is
/// unchanged (20 of 20 offered passes land at 25 fps) because the budget is a
/// stride interval, and 23 ms is a third of the tightest one. See
/// `ScopeData.waveWidth` for what the width buys.
///
/// Colorimetry: gamma-encoded R'G'B' code values (the standard scope domain),
/// BT.709 luma Y' = 0.2126 R' + 0.7152 G' + 0.0722 B', full-range chroma
/// Cb = (B'−Y')/1.8556, Cr = (R'−Y')/1.5748 — the same math positions the
/// vectorscope graticule targets, so a 75% bar lands exactly on its box.
///
/// The samples themselves are 10-bit (0…1023) whatever the source is. An 8-bit
/// frame is bit-replicated up, which is exact at both ends and costs a table
/// lookup; a 10-bit wire frame — `'r210'` or `'v210'` — keeps every code it
/// arrived with, and for `'v210'` the analyzer's scale and the source's are the
/// same scale, which for once means no conversion in either direction. The trace
/// maps are 512 rows for the same reason: quantizing a 10-bit signal onto 256
/// rows puts it straight back where it started, and a near-flat gradient drawn
/// on 256 rows is the "8-bit, undetailed" staircase the operator sees.
public struct ScopeData: Sendable {
    /// Waveform trace resolution.
    ///
    /// 512 rows is retina for the box the scopes are drawn in (~300 pt tall on
    /// a 2x display) — anything less is upscaled and the trace gains stairs
    /// that are not in the signal.
    ///
    /// The map is TWICE as wide as it is tall, and that is not symmetry for its
    /// own sake. A parade draws the same map three times across a box, so one
    /// map column lands inside a device pixel and the picture is a downscale; a
    /// waveform draws one map across the whole box, so at 1024 columns a
    /// 472 pt box (the scopes window's two-up layout) is 1:1 and a full-width
    /// one is a mild stretch. At 512 the waveform was interpolating every
    /// column across two to four device pixels while the parade beside it was
    /// sharpening — same data, and the operator saw a thick hazy trace next to
    /// a clean one. Measured horizontal detail reaching the screen in a 472 pt
    /// box went from 0.35 of the parade's to 1.05 of it.
    public static let waveWidth = 1024
    public static let waveHeight = 512
    /// Vectorscope resolution (square). Deliberately NOT raised with the
    /// waveform: the grid puts ~138 k samples on this map and 256² already
    /// gives it two per cell. At 384² most cells would hold less than one, and
    /// a vectorscope drawn from a sparser map does not gain detail — it gains
    /// gaps.
    ///
    /// What it needed instead was to stop rounding each sample to a cell, and
    /// that is `Accumulator.addToVector`: a sample is split between the four
    /// cells around it, so the trace has a position finer than the grid it is
    /// stored on. That is where "low res" was actually coming from — a whole
    /// cell is about four device pixels in the two-up layout, and every trace
    /// was quantised to one. Rendered side by side on a hue sweep, the ring's
    /// edges lose their staircase entirely.
    ///
    /// 384² was then rendered from the same frame for comparison and NOT
    /// taken: the ring is crisper, but thinner and speckled inside from the
    /// support each cell loses, which is a trade rather than an improvement,
    /// and it wants a real signal and the owner's eye rather than a synthetic
    /// one and mine. The evidence is here so that decision starts from it.
    public static let vectorSize = 256
    /// CIE chromaticity map resolution (square), and the same size as the
    /// vectorscope's for the same reason: the grid puts ~138 k samples on it,
    /// and a map fine enough to hold fewer than one sample per cell does not
    /// gain detail, it gains gaps. Where a sample lands INSIDE its cell is
    /// carried by the split deposit both maps share, not by the cell count.
    public static let cieSize = 256
    /// The xy square the map covers, both axes on the same scale.
    ///
    /// 0…0.85 holds the whole spectral locus with room to spare — its extremes
    /// are x = 0.7347 at 700 nm and y = 0.8338 at 520 nm — and holds it on ONE
    /// scale in both directions, which a chromaticity diagram has to be drawn
    /// on: the distance between two points is the only thing the chart says
    /// beyond where they are, and a stretched axis makes that distance a lie in
    /// one direction. Square also means the box is square, which is what
    /// `ScopeGridLayout` already assumes of this scope.
    public static let cieSpan = 0.85
    /// Where a chromaticity sits inside the map's square, 0…1 from the LEFT and
    /// from the TOP — so y is flipped, as on every map here (row 0 is the high
    /// end).
    ///
    /// The analyzer deposits through this and the graticule draws the spectral
    /// locus, both gamut triangles and the white point through it, so a corner
    /// and the trace that should land on it are placed by one function. It is
    /// the vectorscope's rule (`ScopeAnalyzer.chroma` positions both ends of
    /// that scope) applied to the scope that needs it more: nobody can tell by
    /// eye that a chromaticity is a percent off.
    public static func cieUnit(_ point: Chromaticity) -> (x: Double, y: Double) {
        (point.x / cieSpan, 1 - point.y / cieSpan)
    }

    /// Grayscale density maps, row-major `waveWidth * waveHeight`;
    /// row 0 is the highest code value (the top of the scope).
    public let waveformY: [UInt8]
    public let waveformR: [UInt8]
    public let waveformG: [UInt8]
    public let waveformB: [UInt8]
    /// Luma waveform colored by the image: RGBA `waveWidth * waveHeight * 4`,
    /// brightness = trace density, chroma = mean color of contributing pixels.
    public let waveformYColor: [UInt8]
    /// 256-bin histograms, on the same vertical scale as the traces: bin `i`
    /// covers 10-bit codes `4i…4i+3`.
    public let histR: [Int]
    public let histG: [Int]
    public let histB: [Int]
    public let histY: [Int]
    /// Vectorscope density: x = Cb (right = +), y = Cr (top = +), center at
    /// (vectorSize/2, vectorSize/2), full-range chroma ±511 maps to ±half-size.
    public let vector: [UInt8]
    /// CIE 1931 chromaticity density, row-major `cieSize * cieSize`: column 0 is
    /// x = 0, row 0 is y = `cieSpan`. Placed by `cieUnit`.
    public let cie: [UInt8]
    /// Where 0 % and 100 % sit on the trace maps. `.full` for an already
    /// expanded frame; a wire frame leaves room for the excursions.
    public let nominal: ScopeNominalRange
    /// What the traced codes MEAN. `.sdr` for everything that is not a PQ or
    /// HLG wire frame, and the scales are then exactly what they always were.
    ///
    /// Carried on the DATA rather than read from settings by the views, because
    /// a scope's axis has to describe the frame it is drawn from: a pass that
    /// was analyzed before the camera switched to PQ must not be labelled in
    /// nits for one refresh.
    public let transfer: SignalTransfer
    /// What the traced codes mean as a COLOUR — the primaries the chromaticity
    /// map was computed against, and the gamut the chart draws loudest.
    ///
    /// Carried on the data for the same reason `transfer` is: the frame states
    /// it, a take latches what it opened with, and a chart labelled Rec.2020
    /// over a map computed from Rec.709 would be wrong in the one way nobody
    /// looking at the picture can catch.
    public let primaries: SignalPrimaries
    /// Monotonic frame counter — views cache derived images against it so a
    /// window resize doesn't rebuild them.
    public let sequence: Int

}

/// Computes scope data from capture/playback pixel buffers.
/// Supports 32BGRA, r210, R12B, v210, 2vuy and 420v frames.
public enum ScopeAnalyzer {
    /// The internal sample scale: everything the accumulator sees is a 10-bit
    /// code, whatever the source carried.
    static let sampleLevels = 1024

    /// 8-bit code → 10-bit, by bit replication: 0 stays 0 and 255 becomes 1023,
    /// so the scale is filled end to end with no gain error. It agrees with a
    /// multiply by 1023/255 to within a code everywhere (16 → 64 exactly,
    /// 235 → 943, which is what 235·1023/255 rounds to as well — nominal white
    /// in 10 bits is 940, and the three codes between them are the price of a
    /// signal that only ever had 8), but it is a shift and an or, and it runs
    /// `gridCols * gridRows * 3` times a frame.
    ///
    /// The difference does not reach a graticule: a widened frame has already
    /// been through the levels stage and is read as `.full`, where the nominal
    /// pair is the top and bottom of the map rather than 64 and 940.
    @inline(__always)
    static func widened(_ code: Int) -> Int { (code << 2) | (code >> 6) }

    /// Full-range BT.709 chroma of gamma-encoded R'G'B' — shared by the
    /// analysis and the vectorscope graticule so targets are exact. Scale-free:
    /// the caller's units come back out.
    public static func chroma(r: Double, g: Double, b: Double,
                              primaries: SignalPrimaries = .rec709)
        -> (cb: Double, cr: Double) {
        let weights = primaries.rgbToXYZ.lumaWeights
        let y = weights.r * r + weights.g * g + weights.b * b
        // The denominators FOLLOW from the weights — 2(1 − Yb) for Cb and
        // 2(1 − Yr) for Cr — which is how 709 gets 1.8556 and 1.5748 and how
        // 2020 gets 1.8814 and 1.4746. Writing them as constants beside
        // derived weights is how the two halves of one matrix come apart.
        return ((b - y) / (2 * (1 - weights.b)),
                (r - y) / (2 * (1 - weights.r)))
    }

    private static let sequenceLock = NSLock()
    nonisolated(unsafe) private static var sequenceCounter = 0

    static func nextSequence() -> Int {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequenceCounter += 1
        return sequenceCounter
    }

    /// `region` is the part of the frame to analyze — the punched-in crop the
    /// viewer is showing, or `.full` for the whole frame.
    ///
    /// `wireLevels` only means anything for a WIRE frame — 'r210', 'R12B' or
    /// 'v210' — those being the formats that reach the analyzer before the levels
    /// stage has touched them. Every other format arrives already expanded and is
    /// read as `.full`.
    /// `colorimetry` likewise only means anything for a wire frame: it picks the
    /// YCbCr matrix (Rec.2020 codes luma with different weights) and rides out
    /// on `ScopeData.transfer` so the axis can be labelled in cd/m². It changes
    /// no trace and no sample — an instrument plots the codes that arrived,
    /// whatever curve they were encoded with.
    ///
    /// The CIE chromaticity map is the one exception, and necessarily so: a
    /// chromaticity is a function of LINEAR light and of the primaries the
    /// codes are stated against, so that map — and only that map — is computed
    /// through both halves of this value. See `Accumulator.addToCIE`.
    public static func analyze(_ pixelBuffer: CVPixelBuffer,
                               region: ScopeRegion = .full,
                               wireLevels: ScopeWireLevels = .full,
                               colorimetry: WireColorimetry = .sdr) -> ScopeData? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            return PackedPlane(pixelBuffer).flatMap {
                analyzed(BGRAReader(plane: $0), region: region, levels: .full)
            }
        case TenBitConverter.r210:
            return PackedPlane(pixelBuffer).flatMap {
                analyzed(R210Reader(plane: $0), region: region,
                         levels: wireLevels, colorimetry: colorimetry)
            }
        case R12BPacking.pixelFormat: // 'R12B', 12-bit RGB
            return PackedPlane(pixelBuffer).flatMap {
                // a stride too short for whole 36-byte blocks would be read
                // past the end of each row — refuse the frame instead
                guard CVPixelBufferGetBytesPerRow(pixelBuffer)
                    >= R12BPacking.blockRowBytes(width: $0.width) else { return nil }
                return analyzed(R12BReader(plane: $0), region: region,
                                levels: wireLevels, colorimetry: colorimetry)
            }
        case V210Packing.pixelFormat: // 'v210', 10-bit YCbCr 4:2:2
            return PackedPlane(pixelBuffer).flatMap {
                // a stride too short for whole 16-byte blocks would be read
                // past the end of each row — refuse the frame instead
                guard CVPixelBufferGetBytesPerRow(pixelBuffer)
                    >= V210Packing.blockRowBytes(width: $0.width) else { return nil }
                return analyzed(V210Reader(plane: $0, levels: wireLevels,
                                           primaries: colorimetry.primaries),
                                region: region, levels: wireLevels,
                                colorimetry: colorimetry)
            }
        case kCVPixelFormatType_422YpCbCr8: // '2vuy': Cb Y0 Cr Y1
            return PackedPlane(pixelBuffer).flatMap {
                analyzed(TwoVUYReader(plane: $0), region: region, levels: .full)
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: // '420v'
            return BiPlanar420Reader(pixelBuffer).flatMap {
                analyzed($0, region: region, levels: .full)
            }
        default:
            return nil
        }
    }

    // MARK: - the sampling grid

    /// Fixed sampling grid: identical column population for any frame size
    /// (resolution-dependent striding caused vertical banding).
    ///
    /// One grid column per map column, so widening the map narrows the step
    /// between neighbouring samples — and the trace is drawn as the segment
    /// between them, so a finer step is also a THINNER trace, not just a
    /// sharper one.
    static let gridCols = ScopeData.waveWidth
    static let gridRows = 270

    /// One sample as the accumulator takes it: 10-bit gamma-encoded R'G'B',
    /// plus the wire chroma/luma for YUV sources (nil for RGB ones — see
    /// `Accumulator.add`).
    struct Sample {
        let r: Int
        let g: Int
        let b: Int
        var nativeChroma: (cb: Double, cr: Double)?
        var nativeLuma: Int?
    }

    /// How one source format hands over a pixel. A protocol rather than a
    /// closure so the walk below specializes per format: it runs
    /// `gridCols * gridRows` times per frame and every sample goes through here.
    protocol FrameReader {
        var width: Int { get }
        var height: Int { get }
        func sample(x: Int, y: Int) -> Sample
    }

    /// Walk the grid once, accumulating every sample. The formats differ only
    /// in how a pixel is fetched, so this is the whole per-frame pass.
    ///
    /// The grid always has the same shape — only the window it is stretched
    /// over changes with `region`, so a punched-in scope has exactly the same
    /// trace density as a full-frame one.
    private static func analyzed<Reader: FrameReader>(
        _ reader: Reader, region: ScopeRegion, levels: ScopeWireLevels,
        colorimetry: WireColorimetry = .sdr) -> ScopeData? {
        guard reader.width > 1, reader.height > 0 else { return nil }
        let window = region.pixels(width: reader.width, height: reader.height)
        let acc = Accumulator(levels: levels, colorimetry: colorimetry)
        for gy in 0..<gridRows {
            let y = window.y + gy * window.height / gridRows
            for gx in 0..<gridCols {
                let sample = reader.sample(
                    x: window.x + gx * window.width / gridCols, y: y)
                acc.add(col: gx, r: sample.r, g: sample.g, b: sample.b,
                        nativeChroma: sample.nativeChroma,
                        nativeLuma: sample.nativeLuma)
            }
        }
        return acc.finish()
    }

    // MARK: - the source formats

    /// The one interleaved plane 32BGRA, r210 and 2vuy are all stored in: same
    /// lookup, same frame size, only the bytes under (x, y) differ.
    struct PackedPlane {
        let base: UnsafePointer<UInt8>
        let rowBytes: Int
        let width: Int
        let height: Int

        init?(_ pixelBuffer: CVPixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            self.base = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        }

        func row(_ y: Int) -> UnsafePointer<UInt8> { base + y * rowBytes }
    }

    /// A reader over such a plane: the plane states the frame size, the
    /// conforming type only says how to unpack one pixel.
    protocol PackedPlaneReader: FrameReader {
        var plane: PackedPlane { get }
    }

    /// 32BGRA — already full-range R'G'B', byte order B G R A, widened to the
    /// analyzer's 10-bit sample scale.
    private struct BGRAReader: PackedPlaneReader {
        let plane: PackedPlane

        func sample(x: Int, y: Int) -> Sample {
            let p = plane.row(y) + x * 4
            return Sample(r: widened(Int(p[2])), g: widened(Int(p[1])),
                          b: widened(Int(p[0])))
        }
    }

    /// 'r210' — the 10-bit RGB the board actually delivers, big-endian
    /// 2:10:10:10. This is the parallel reader the scopes exist for: it sees
    /// the wire codes BEFORE `TenBitConverter` expands them into the 8-bit
    /// display buffer, so nothing has been quantized to 256 levels and nothing
    /// outside 64…940 has been clamped away yet.
    private struct R210Reader: PackedPlaneReader {
        let plane: PackedPlane

        func sample(x: Int, y: Int) -> Sample {
            // rows of an r210 buffer are 4-byte aligned by construction, but
            // loadUnaligned costs nothing here and cannot trap on a stride the
            // board picked
            let word = UInt32(bigEndian: UnsafeRawPointer(plane.row(y) + x * 4)
                .loadUnaligned(as: UInt32.self))
            return Sample(r: Int((word >> 20) & 0x3FF),
                          g: Int((word >> 10) & 0x3FF),
                          b: Int(word & 0x3FF))
        }
    }

    /// 'R12B' — Blackmagic's 12-bit RGB wire format, eight pixels to 36 bytes.
    /// The sibling of `R210Reader`: same job, same place in the pipeline
    /// (before the split, so nothing has been quantized to 256 levels and
    /// nothing outside the nominal pair has been clamped away), one bit depth
    /// up. The bit layout itself is not repeated here — both readers of this
    /// format go through `R12BPacking`.
    private struct R12BReader: PackedPlaneReader {
        let plane: PackedPlane

        func sample(x: Int, y: Int) -> Sample {
            let pixel = R12BPacking.pixel(plane.row(y), x: x)
            return Sample(r: narrowed(pixel.r), g: narrowed(pixel.g),
                          b: narrowed(pixel.b))
        }
    }

    /// 12-bit code → the analyzer's 10-bit sample scale, ROUNDED rather than
    /// truncated, so the mapping is unbiased and the reference codes are exact:
    /// nominal black 256 → 64 and nominal white 3760 → 940, which is what the
    /// graticule needs if a 12-bit source's 0 % line is to sit where a 10-bit
    /// source's does.
    ///
    /// The two bits dropped here are a deliberate limit, not an oversight, and
    /// it is worth being plain about it: the trace maps are `waveHeight` = 512
    /// rows and the histograms are 256 bins, so the analyzer cannot DISPLAY
    /// more than about nine bits of distinct levels however many it is given.
    /// A 12-bit sample scale would move every graticule, every histogram bin
    /// and the scopes window's "1023" code axis for no visible detail. What the
    /// wire tap is for — precision beyond the 8-bit display buffer, and the
    /// excursions outside the nominal pair — is intact at 10 bits. The full 12
    /// bits do reach the FILE, which is where they are worth something.
    @inline(__always)
    static func narrowed(_ code: Int) -> Int {
        min(sampleLevels - 1, (code + 2) >> 2)
    }

    /// 'v210' — 10-bit YCbCr 4:2:2, the standard professional SDI signal. The
    /// third wire reader, and the only one whose depth matches the analyzer's own
    /// sample scale exactly: nothing is widened and nothing is narrowed, so every
    /// code the camera sent is the code that lands on the trace.
    ///
    /// Same place in the pipeline as its two RGB siblings — before the split, so
    /// nothing has been quantized to 256 levels and nothing outside the nominal
    /// pair has been clamped away. The bit layout is not repeated here: both
    /// readers of this format go through `V210Packing`.
    ///
    /// The chroma is NEAREST — the pair's coded samples, not an interpolation.
    /// The picture path interpolates and says why; an instrument must not, because
    /// the samples an upsampler invents are not in the signal, and a vectorscope
    /// exists to show what arrived. This is also exactly what the 8-bit '2vuy'
    /// reader below has always done.
    private struct V210Reader: PackedPlaneReader {
        let plane: PackedPlane
        /// The matrix onto R'G'B' — carried rather than shared with the converter
        /// instance because the analyzer is handed a frame and a levels reading,
        /// not a pipeline.
        let matrix: WireYCbCr

        init(plane: PackedPlane, levels: ScopeWireLevels,
             primaries: SignalPrimaries = .rec709) {
            self.plane = plane
            matrix = WireYCbCr(levels: levels, primaries: primaries)
        }

        func sample(x: Int, y: Int) -> Sample {
            let pixel = V210Packing.pixel(plane.row(y), x: x)
            let rgb = matrix.rgb(luma: pixel.luma, cb: pixel.cb, cr: pixel.cr)
            // The parade gets R'G'B' on the WIRE's swing, which is the same
            // domain the r210 reader hands over — so a 10-bit YCbCr source and a
            // 10-bit RGB source draw the same trace for the same picture. Luma
            // and chroma ride along unclamped so an illegal excursion is plotted
            // as itself instead of being folded into the RGB gamut.
            return Sample(r: rgb.r, g: rgb.g, b: rgb.b,
                          nativeChroma: matrix.chromaDifference(cb: pixel.cb,
                                                                cr: pixel.cr),
                          nativeLuma: pixel.luma)
        }
    }

    /// '2vuy' — one Cb Y0 Cr Y1 macropixel covers two columns.
    private struct TwoVUYReader: PackedPlaneReader {
        let plane: PackedPlane

        func sample(x: Int, y: Int) -> Sample {
            let macropixel = x & ~1 // whole Cb Y0 Cr Y1 group
            let p = plane.row(y) + (macropixel / 2) * 4
            return videoRangeSample(luma: Int(p[1]),
                                    cb: Int(p[0]) - 128, cr: Int(p[2]) - 128)
        }
    }

    /// Biplanar 4:2:0 video-range: luma plane + interleaved CbCr plane.
    private struct BiPlanar420Reader: FrameReader {
        let luma: UnsafePointer<UInt8>
        let chroma: UnsafePointer<UInt8>
        let lumaRowBytes: Int
        let chromaRowBytes: Int
        let width: Int
        let height: Int

        init?(_ pixelBuffer: CVPixelBuffer) {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
            else { return nil }
            luma = UnsafePointer(yBase.assumingMemoryBound(to: UInt8.self))
            chroma = UnsafePointer(cBase.assumingMemoryBound(to: UInt8.self))
            lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        }

        func sample(x: Int, y: Int) -> Sample {
            // both axes land on the even pixel the chroma pair belongs to
            let pixelX = x & ~1
            let pixelY = y & ~1
            let chromaRow = chroma + (pixelY / 2) * chromaRowBytes
            return videoRangeSample(
                luma: Int((luma + pixelY * lumaRowBytes)[pixelX]),
                cb: Int(chromaRow[(pixelX / 2) * 2]) - 128,
                cr: Int(chromaRow[(pixelX / 2) * 2 + 1]) - 128)
        }
    }

    /// BT.709 video-range YCbCr → full-range R'G'B' on the 10-bit sample scale,
    /// shared by both YUV readers. The `>> 6` is the usual `>> 8` of the 8-bit
    /// conversion followed by the `<< 2` onto this scale, folded into one shift.
    /// The wire chroma/luma ride along as `native*` values so illegal
    /// excursions are plotted as-is instead of being folded into the RGB gamut
    /// by the clamp.
    fileprivate static func videoRangeSample(luma: Int, cb: Int, cr: Int) -> Sample {
        let yv = (luma - 16) * 298
        return Sample(r: clamp((yv + 459 * cr) >> 6),
                      g: clamp((yv - 137 * cr - 55 * cb) >> 6),
                      b: clamp((yv + 541 * cb) >> 6),
                      nativeChroma: (Double(cb) * 1023 / 224,
                                     Double(cr) * 1023 / 224),
                      nativeLuma: clamp(yv >> 6))
    }

    private static func clamp(_ v: Int) -> Int { min(sampleLevels - 1, max(0, v)) }
}

/// The frame size of a packed-plane reader is the plane's — stated once so the
/// readers themselves are nothing but their pixel unpacking.
extension ScopeAnalyzer.PackedPlaneReader {
    var width: Int { plane.width }
    var height: Int { plane.height }
}
