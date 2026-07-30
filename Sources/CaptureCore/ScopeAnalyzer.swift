@preconcurrency import CoreVideo
import Foundation

/// One frame's worth of scope data: per-channel waveform density maps, RGB/luma
/// histograms and a vectorscope density map. Computed on the CPU from a fixed
/// sampling grid, on the scope queue — ~14 ms per 1080p frame, whatever the
/// content, which is what makes a ~15 Hz update rate affordable.
///
/// Colorimetry: gamma-encoded R'G'B' code values (the standard scope domain),
/// BT.709 luma Y' = 0.2126 R' + 0.7152 G' + 0.0722 B', full-range chroma
/// Cb = (B'−Y')/1.8556, Cr = (R'−Y')/1.5748 — the same math positions the
/// vectorscope graticule targets, so a 75% bar lands exactly on its box.
public struct ScopeData: Sendable {
    /// Waveform trace resolution.
    public static let waveWidth = 512
    public static let waveHeight = 256
    /// Vectorscope resolution (square).
    public static let vectorSize = 256
    /// Grayscale density maps, row-major `waveWidth * waveHeight`;
    /// row 0 is 100% (top of the scope).
    public let waveformY: [UInt8]
    public let waveformR: [UInt8]
    public let waveformG: [UInt8]
    public let waveformB: [UInt8]
    /// Luma waveform colored by the image: RGBA `waveWidth * waveHeight * 4`,
    /// brightness = trace density, chroma = mean color of contributing pixels.
    public let waveformYColor: [UInt8]
    /// 256-bin histograms.
    public let histR: [Int]
    public let histG: [Int]
    public let histB: [Int]
    public let histY: [Int]
    /// Vectorscope density: x = Cb (right = +), y = Cr (top = +), center at
    /// (vectorSize/2, vectorSize/2), full-range chroma ±127 maps to ±half-size.
    public let vector: [UInt8]
    /// Monotonic frame counter — views cache derived images against it so a
    /// window resize doesn't rebuild them.
    public let sequence: Int

}

/// Computes scope data from capture/playback pixel buffers.
/// Supports 32BGRA, 2vuy and 420v frames.
public enum ScopeAnalyzer {
    /// Full-range BT.709 chroma of gamma-encoded R'G'B' — shared by the
    /// analysis and the vectorscope graticule so targets are exact.
    public static func chroma(r: Double, g: Double, b: Double)
        -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
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
    public static func analyze(_ pixelBuffer: CVPixelBuffer,
                               region: ScopeRegion = .full) -> ScopeData? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            return PackedPlane(pixelBuffer).flatMap {
                analyzed(BGRAReader(plane: $0), region: region)
            }
        case kCVPixelFormatType_422YpCbCr8: // '2vuy': Cb Y0 Cr Y1
            return PackedPlane(pixelBuffer).flatMap {
                analyzed(TwoVUYReader(plane: $0), region: region)
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: // '420v'
            return BiPlanar420Reader(pixelBuffer).flatMap {
                analyzed($0, region: region)
            }
        default:
            return nil
        }
    }

    // MARK: - the sampling grid

    /// Fixed sampling grid: identical column population for any frame size
    /// (resolution-dependent striding caused vertical banding).
    static let gridCols = ScopeData.waveWidth
    static let gridRows = 270

    /// One sample as the accumulator takes it: full-range gamma-encoded R'G'B',
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

    /// Walk the grid once, accumulating every sample. The three formats differ
    /// only in how a pixel is fetched, so this is the whole per-frame pass.
    ///
    /// The grid always has the same shape — only the window it is stretched
    /// over changes with `region`, so a punched-in scope has exactly the same
    /// trace density as a full-frame one.
    private static func analyzed<Reader: FrameReader>(
        _ reader: Reader, region: ScopeRegion) -> ScopeData? {
        guard reader.width > 1, reader.height > 0 else { return nil }
        let window = region.pixels(width: reader.width, height: reader.height)
        let acc = Accumulator()
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

    /// The one interleaved plane 32BGRA and 2vuy are both stored in: same
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

    /// 32BGRA — already full-range R'G'B', byte order B G R A.
    private struct BGRAReader: PackedPlaneReader {
        let plane: PackedPlane

        func sample(x: Int, y: Int) -> Sample {
            let p = plane.row(y) + x * 4
            return Sample(r: Int(p[2]), g: Int(p[1]), b: Int(p[0]))
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

    /// BT.709 video-range YCbCr → full-range R'G'B', shared by both YUV
    /// readers. The wire chroma/luma ride along as `native*` values so illegal
    /// excursions are plotted as-is instead of being folded into the RGB gamut
    /// by the clamp.
    fileprivate static func videoRangeSample(luma: Int, cb: Int, cr: Int) -> Sample {
        let yv = (luma - 16) * 298
        return Sample(r: clamp((yv + 459 * cr) >> 8),
                      g: clamp((yv - 137 * cr - 55 * cb) >> 8),
                      b: clamp((yv + 541 * cb) >> 8),
                      nativeChroma: (Double(cb) * 255 / 224,
                                     Double(cr) * 255 / 224),
                      nativeLuma: clamp(yv >> 8))
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }
}

/// The frame size of a packed-plane reader is the plane's — stated once so the
/// readers themselves are nothing but their pixel unpacking.
extension ScopeAnalyzer.PackedPlaneReader {
    var width: Int { plane.width }
    var height: Int { plane.height }
}
