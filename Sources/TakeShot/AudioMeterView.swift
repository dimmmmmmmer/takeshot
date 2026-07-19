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
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(for: level))
                            .frame(height: geo.size.height * fraction(of: level))
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

    /// Вся полоса — одним цветом по громкости: зелёный до -12, жёлтый до -3, красный выше.
    static func color(for level: Float) -> Color {
        level >= -3 ? .red : level >= -12 ? .yellow : .green
    }

    private func fraction(of level: Float) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
