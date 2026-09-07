import CaptureCore
import CoreGraphics
import SwiftUI

/// The histogram's code axis: `ScopeAxis` stood on its side, with the numbers
/// sitting on the rules they name.
///
/// It is here rather than in `HistogramView` because it is the same axis — the
/// owner's complaint was that the histogram's numbers ignored the graticule
/// control every other scope obeys, and the reason they did is that they were a
/// hand-built `HStack` of `Spacer()`s with two hard-coded opacities in it,
/// nowhere near the `ScopeAxis` the rest of the panel is placed by.
///
/// "Stood on its side" is not "flipped", though, and the difference only shows
/// on a wire frame: a percent mark rides with the nominal pair, a code mark
/// does not. `ScopeAxis.horizontalTicks` owns that distinction — see the
/// reasoning there.
///
/// It carries NO excursion shading, and that is the other half of the owner's
/// "unexplained limit lines — at the left and right of the histogram".
///
/// On a level scope the excursion band is a wide horizontal strip with a
/// labelled rule along its inner edge, and naming the far end of it (see
/// `ScopeAxis.excursionTicks`) turns it into a range the operator can read. On
/// a code axis the same band is a strip 6 to 8 % of the box WIDE: there is no
/// room in it for a number, the histogram used to draw one copy per stacked
/// channel row, and only the bottom row carried any numbers at all — so on the
/// default RGB histogram it was six tinted strips and nothing to explain them.
/// The bins to the left of the 0 mark and to the right of the 100 mark say the
/// same thing, and that is how Resolve and Baselight draw a histogram too.
struct ScopeCodeAxisMarks: View {
    let nominal: ScopeNominalRange
    /// The traced frame's transfer — see `ScopeLevelGraticule`.
    var transfer: SignalTransfer = .sdr
    @Environment(\.scopeGridBrightness) private var brightness
    @Environment(\.scopeScaleMode) private var mode

    var body: some View {
        // **One `Canvas`**, like `ScopeLevelGraticule` and for the same reason:
        // this was a `GeometryReader` around two `ForEach`es — a stroked `Path`
        // per rule and a `Text` per number, each with its own `.shadow` and so
        // its own offscreen pass — rebuilt on every scope publish under the
        // histogram it explains.
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let axis = ScopeAxis(
                nominal: nominal,
                mode: ScopeScaleMode.resolved(mode, transfer: transfer),
                transfer: transfer)
            draw(axis, in: size, context: context)
        }
    }

    private func draw(_ axis: ScopeAxis, in size: CGSize,
                      context: GraphicsContext) {
        var context = context
        for tick in axis.horizontalTicks {
            rule(at: tick.unit, in: size, opacity: tick.weight.opacity,
                 context: &context)
        }
        // in code mode, where the numbers are codes and neither of them is
        // 0 %, the nominal pair is drawn at full weight
        for x in axis.extraNominalXs {
            rule(at: x, in: size, opacity: ScopeTick.Weight.nominal.opacity,
                 context: &context)
        }
        // The shadow once, around every number, instead of once per number.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
            for tick in axis.horizontalTicks {
                let text = Text(tick.label)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3 + brightness * 0.45))
                layer.draw(text, at: CGPoint(x: labelCentre(tick, in: size),
                                             y: size.height
                                                - scopeLabelHeight / 2 - 1))
            }
        }
    }

    /// The 0.45 is what keeps the same tick weights the level scopes use from
    /// shouting here: these rules run ACROSS the shape being measured rather
    /// than along it, so the loudest of them lands at the flat 0.3 the
    /// histogram's marks were drawn at, and the rest sit under it.
    private func rule(at x: Double, in size: CGSize, opacity: Double,
                      context: inout GraphicsContext) {
        let position = size.width * x
        var path = Path()
        path.move(to: CGPoint(x: position, y: 0))
        path.addLine(to: CGPoint(x: position, y: size.height))
        context.stroke(path,
                       with: .color(.white.opacity(opacity * 0.45 * brightness)),
                       lineWidth: 0.5)
    }

    /// Centred on the mark, and clamped at both ends so the first and last
    /// number stay inside the box instead of hanging off its corners — the
    /// same inset the label frame used to give them.
    private func labelCentre(_ tick: ScopeTick, in size: CGSize) -> CGFloat {
        let x = size.width * tick.unit
        return min(size.width - Self.labelWidth / 2,
                   max(Self.labelWidth / 2, x))
    }

    /// Wide enough for "1023" at 8 pt, and the same box whatever the number is
    /// so the marks are not nudged by the width of their own label.
    private static let labelWidth: CGFloat = 34
}
