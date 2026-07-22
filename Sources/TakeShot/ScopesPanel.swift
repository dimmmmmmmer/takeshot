import CaptureCore
import CoreGraphics
import SwiftUI

/// Scopes overlay: luma waveform + RGB histogram computed from the visible
/// frame (live or playback — whichever mode is active).
struct ScopesPanel: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        HStack(spacing: 10) {
            if let data = controller.scopeData {
                ScopeBox(title: L("scope_waveform")) {
                    WaveformView(data: data)
                }
                ScopeBox(title: L("scope_histogram")) {
                    HistogramView(data: data)
                }
            } else {
                Text(L("scope_waiting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, height: 140)
            }
        }
        .padding(10)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.white.opacity(0.12)))
    }
}

/// Titled container for a single scope.
private struct ScopeBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            content
                .frame(width: 224, height: 126)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Luma waveform: the analyzer's density map tinted green, with 0/50/100% lines.
private struct WaveformView: View {
    let data: ScopeData

    var body: some View {
        ZStack {
            if let image = Self.grayscaleImage(from: data.waveform) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .colorMultiply(Color(red: 0.35, green: 1.0, blue: 0.5))
            }
            // reference lines at 100 / 50 / 0%
            GeometryReader { geo in
                Path { p in
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = geo.size.height * fraction
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
            }
        }
    }

    /// 256×256 grayscale CGImage from the analyzer's density bytes.
    static func grayscaleImage(from bytes: [UInt8]) -> CGImage? {
        let size = ScopeData.size
        guard bytes.count == size * size,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(width: size, height: size, bitsPerComponent: 8,
                       bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// RGB histogram: three overlaid filled paths in screen blend.
private struct HistogramView: View {
    let data: ScopeData

    var body: some View {
        GeometryReader { geo in
            let peak = max(1, [data.histR.max() ?? 1, data.histG.max() ?? 1,
                               data.histB.max() ?? 1].max() ?? 1)
            ZStack {
                channelPath(data.histR, peak: peak, in: geo.size)
                    .fill(Color.red.opacity(0.7)).blendMode(.screen)
                channelPath(data.histG, peak: peak, in: geo.size)
                    .fill(Color.green.opacity(0.7)).blendMode(.screen)
                channelPath(data.histB, peak: peak, in: geo.size)
                    .fill(Color.blue.opacity(0.7)).blendMode(.screen)
            }
        }
    }

    private func channelPath(_ bins: [Int], peak: Int, in size: CGSize) -> Path {
        Path { p in
            let step = size.width / CGFloat(bins.count)
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, count) in bins.enumerated() {
                let h = size.height * CGFloat(count) / CGFloat(peak)
                p.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - h))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}
