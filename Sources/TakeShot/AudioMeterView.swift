import SwiftUI

/// Вертикальные пиковые метры аудиоканалов (dBFS от -60 до 0).
/// Зелёный до -12, жёлтый до -3, дальше красный.
struct AudioMeterView: View {
    let levels: [Float]
    var enabled: [Bool]? = nil

    private let range: ClosedRange<Float> = -60...0

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                GeometryReader { geo in
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

/// Классический сегментный метр: зелёный до -12 dB, жёлтым красится только
/// участок -12…-3, красным — только то, что выше -3.
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
