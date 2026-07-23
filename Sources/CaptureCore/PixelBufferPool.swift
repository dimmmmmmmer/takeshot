import CoreVideo
import Foundation

/// A reusable pixel-buffer pool (BGRA by default) that rebuilds itself when the
/// frame size changes. Shared by the LUT/levels/preview stages so the pool
/// setup lives in one place.
final class PixelBufferPool {
    private let format: OSType
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init(format: OSType = kCVPixelFormatType_32BGRA) {
        self.format = format
    }

    /// Vend a fresh buffer of the given size (rebuilds the pool on size change).
    func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || self.width != width || self.height != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                    attrs as CFDictionary, &newPool)
            pool = newPool
            self.width = width
            self.height = height
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }

    /// Drop the pool so the next `buffer(width:height:)` rebuilds it.
    func reset() { pool = nil }
}
