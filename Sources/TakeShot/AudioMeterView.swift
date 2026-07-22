import SwiftUI

/// Vertical audio-channel peak meters (dBFS from -60 to 0).
/// Green up to -12, yellow up to -3, red beyond.
struct AudioMeterView: View {
    let levels: [Float]
    var enabled: [Bool]?

    private let range: ClosedRange<Float> = -60...0

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                GeometryReader { _ in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.black.opacity(0.55))
                        SegmentedMeterBar(level: level)
                            .animation(.linear(duration: 0.07), value: level)
                    }
                }
                .frame(width: 5)
                .opacity((enabled?.indices.contains(index) == true && enabled![index] == false) ? 0.25 : 1)
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }

    private func fraction(of level: Float) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// Classic segmented meter: green up to -12 dB, only the -12…-3 band is yellow,
/// only what's above -3 is red.
struct SegmentedMeterBar: View {
    let level: Float

    private static let range: ClosedRange<Float> = -60...0
    private static let yellowMark: CGFloat = 0.8   // -12 dB
    private static let redMark: CGFloat = 0.95     // -3 dB

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let f = Self.fraction(level)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if f > Self.redMark {
                    Rectangle().fill(Color.red)
                        .frame(height: h * (f - Self.redMark))
                }
                if f > Self.yellowMark {
                    Rectangle().fill(Color.yellow)
                        .frame(height: h * (min(f, Self.redMark) - Self.yellowMark))
                }
                Rectangle().fill(Color.green)
                    .frame(height: h * min(f, Self.yellowMark))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    static func fraction(_ level: Float) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
