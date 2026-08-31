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

/// The images the scope views draw, built once per analyzed frame.
///
/// A SwiftUI view body runs on every state change in its window — a brightness
/// slider tick, a resize, a hover, another scope's channel switch — and each run
/// used to copy every density map into a fresh CGImage and re-colour the
/// vectorscope's 65 k cells on the main thread. The maps only change when a new
/// frame is analyzed, and `ScopeData.sequence` says exactly when that was.
///
/// Measured, this is worth 0.2 ms a render for the vectorscope and about
/// 0.01 ms for a waveform map: not the reason the scopes felt sluggish (that was
/// the analyzer — see `ScopeAnalyzer+Accumulator`), but main-thread work in the
/// middle of a drag, and a slider that redraws the panel has no business
/// re-colouring a density map to do it.
///
/// **And building them stays here, on the main actor, deliberately.** An audit
/// read this as the last per-frame scope work on the main thread and proposed
/// moving it to the producer. Measured on 1080p analyzer output, every one of
/// the six: lumaColor 0.047 ms, red 0.012, green 0.013, blue 0.020, vector
/// 0.096, cie 0.108 — **0.30 ms for all six together**, once per ANALYZED
/// frame, which is about 12.5 a second. That is 0.4 % of the main thread with
/// every scope open at once, and moving it to the producer would cost the
/// laziness: the cache builds only the maps a visible surface asks for, and a
/// producer cannot know which those are. Not worth it, and the numbers are
/// here so it does not get proposed a third time.
///
/// One cache for the whole app on purpose: every surface showing scopes at a
/// given moment is showing the SAME `ScopeData`, so the main window, a
/// fullscreen mirror and the separate window share the work instead of
/// tripling it.
@MainActor
enum ScopeImageCache {
    /// Which density map the image was built from.
    enum Map: Hashable {
        case lumaColor
        case red
        case green
        case blue
        case vector
        case cie
    }

    private static var sequence = -1
    private static var images: [Map: CGImage] = [:]

    static func image(_ map: Map, from data: ScopeData) -> CGImage? {
        if data.sequence != sequence {
            sequence = data.sequence
            images.removeAll(keepingCapacity: true)
        }
        if let cached = images[map] { return cached }
        guard let built = build(map, from: data) else { return nil }
        images[map] = built
        return built
    }

    /// The vectorscope's colored density map.
    static func vector(from data: ScopeData) -> CGImage? {
        image(.vector, from: data)
    }

    private static func build(_ map: Map, from data: ScopeData) -> CGImage? {
        switch map {
        case .lumaColor: return rgbaImage(from: data.waveformYColor)
        case .red: return grayscaleImage(from: data.waveformR)
        case .green: return grayscaleImage(from: data.waveformG)
        case .blue: return grayscaleImage(from: data.waveformB)
        case .vector: return VectorscopeView.coloredVector(data)
        case .cie: return CIEChartView.coloredChart(data)
        }
    }
}
