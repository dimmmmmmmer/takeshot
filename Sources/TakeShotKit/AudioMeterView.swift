import SwiftUI

/// Vertical audio-channel peak meters (dBFS from -60 to 0).
/// Green up to -10, yellow -10…-5, red above -5.
struct AudioMeterView: View {
    let levels: [Float]
    var enabled: [Bool]?

    private let range: ClosedRange<Float> = -60...0

    /// The whole bank in ONE `Canvas`.
    ///
    /// It was a `ForEach` of `GeometryReader`s, one per channel, each holding a
    /// `SegmentedMeterBar` with its own implicit animation — sixteen laid-out,
    /// animating subtrees for a 16-channel SDI embed, re-evaluated every time
    /// `LiveSignal` published. That is roughly 25 times a second on its own,
    /// and `live.volume` lives on the SAME object, so every tick of the volume
    /// slider republished it too: dragging the popover's slider re-laid-out the
    /// whole meter bank per frame, which is what made it lag (owner: "по клику
    /// на иконку громкоговорителя ползунок выпадающий лагает").
    ///
    /// A `Canvas` has no child views to lay out and no animations to schedule:
    /// the bank is one draw call against a rect it is handed. The bars are
    /// still what they were — same widths, same spacing, same three bands, same
    /// dimming for a channel that is not being recorded.
    ///
    /// What is deliberately gone is the 0.07 s per-bar smoothing. It was
    /// interpolating a LAYOUT, which is the expensive kind, and at 25 updates a
    /// second the trace is already smooth; a meter that lags the sound it
    /// describes is worse than one that does not.
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            Self.draw(levels: levels, enabled: enabled,
                      in: CGRect(origin: .zero, size: size), context: context)
        }
        // **Asks for the ideal width and ACCEPTS the squeezed one.** The bars
        // want 5pt and can be pushed to 3, which is what keeps the codec and
        // the folder beside them readable instead of ellipsized at the app's
        // minimum window — a fixed width here made the left-hand group 3pt too
        // wide in Russian, and `ViewFooterTests` caught it.
        //
        // The drawing already works from whatever rect it is handed, so the
        // squeeze costs nothing but this frame.
        .frame(minWidth: Self.width(for: levels.count, bar: Self.minimumBarWidth),
               idealWidth: Self.width(for: levels.count),
               maxWidth: Self.width(for: levels.count))
        .padding(4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }

    /// 5pt is the width the bars want; they can be squeezed to 3. A 16-channel
    /// embed is 118pt of the footer's left-hand group at the ideal width, and
    /// at the app's minimum window that is more than the group has — a bar that
    /// gives up 2pt keeps the codec and the folder beside it readable instead
    /// of ellipsized.
    static let idealBarWidth: CGFloat = 5
    static let minimumBarWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2

    static func width(for channels: Int,
                      bar: CGFloat = idealBarWidth) -> CGFloat {
        guard channels > 0 else { return 0 }
        return CGFloat(channels) * bar + CGFloat(channels - 1) * barSpacing
    }

    /// One pass over the channels. A free function of its inputs so the layout
    /// arithmetic can be asserted without rendering anything.
    static func draw(levels: [Float], enabled: [Bool]?, in rect: CGRect,
                     context: GraphicsContext) {
        var context = context
        guard !levels.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let count = CGFloat(levels.count)
        let barWidth = max(minimumBarWidth,
                           (rect.width - (count - 1) * barSpacing) / count)
        for (index, level) in levels.enumerated() {
            let x = rect.minX + CGFloat(index) * (barWidth + barSpacing)
            let column = CGRect(x: x, y: rect.minY,
                                width: barWidth, height: rect.height)
            let dimmed = enabled?.indices.contains(index) == true
                && enabled?[index] == false
            context.opacity = dimmed ? 0.25 : 1
            let track = Path(roundedRect: column, cornerRadius: 2)
            context.fill(track, with: .color(.black.opacity(0.55)))
            var bar = context
            bar.clip(to: track)
            Self.fill(level: level, in: column, context: bar)
        }
        context.opacity = 1
    }

    /// The three bands of one bar, drawn from the bottom up.
    private static func fill(level: Float, in column: CGRect,
                             context: GraphicsContext) {
        let f = SegmentedMeterBar.fraction(level)
        guard f > 0 else { return }
        let band: (CGFloat, CGFloat, Color) -> Void = { from, to, colour in
            guard to > from else { return }
            let rect = CGRect(x: column.minX,
                              y: column.maxY - to * column.height,
                              width: column.width,
                              height: (to - from) * column.height)
            context.fill(Path(rect), with: .color(colour))
        }
        band(0, min(f, SegmentedMeterBar.yellowMark), .green)
        band(SegmentedMeterBar.yellowMark,
             min(f, SegmentedMeterBar.redMark), .yellow)
        band(SegmentedMeterBar.redMark, f, .red)
    }

    private func fraction(of level: Float) -> CGFloat {
        AudioMeterScale.fraction(of: level, in: range)
    }
}

/// Classic segmented meter: green up to -10 dB, only the -10…-5 band is yellow,
/// only what's above -5 is red.
struct SegmentedMeterBar: View {
    let level: Float

    private static let range: ClosedRange<Float> = -60...0
    /// -10 dB and -5 dB as fractions of the bar. Read by
    /// `AudioMeterView.draw` too, so the footer's bank and the audio
    /// panel's single bars cannot come to disagree about where yellow
    /// starts — which is a judgement an operator makes at a glance.
    static let yellowMark: CGFloat = 50.0 / 60.0
    static let redMark: CGFloat = 55.0 / 60.0

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
