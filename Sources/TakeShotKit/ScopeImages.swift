import CaptureCore
import CoreGraphics
import Foundation

/// Grayscale CGImage from an analyzer density map.
func grayscaleImage(from bytes: [UInt8],
                    width: Int = ScopeData.waveWidth,
                    height: Int = ScopeData.waveHeight) -> CGImage? {
    guard bytes.count == width * height,
          let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8,
                   bitsPerPixel: 8, bytesPerRow: width,
                   space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)
}

/// RGBA CGImage from analyzer bytes.
func rgbaImage(from bytes: [UInt8],
               width: Int = ScopeData.waveWidth,
               height: Int = ScopeData.waveHeight) -> CGImage? {
    guard bytes.count == width * height * 4,
          let provider = CGDataProvider(data: Data(bytes) as CFData) else {
        return nil
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8,
                   bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(
                       rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: true, intent: .defaultIntent)
}
