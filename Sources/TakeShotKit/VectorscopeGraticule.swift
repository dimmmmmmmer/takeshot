import CaptureCore
import CoreGraphics
import SwiftUI

/// The vectorscope's graticule, and the reasoning behind every part of it.
///
/// The scope was bare: three rings, a cross, six 7pt squares and a line. What a
/// colourist reads a vectorscope for is *where a hue sits relative to a known
/// reference*, and the references are the colour-bar targets — so those get the
/// weight, and everything else stays quiet enough to read a trace through.
///
/// - **The outer circle** is the boundary of the scale: the density map covers
///   full-range chroma ±511 across ±half the box, so the inscribed circle is
///   the radius a chroma of 511 reaches. Drawing it is what turns a square of
///   colour into a scope, and it was the one piece missing — its absence is
///   most of why the thing looked unfinished. It is a boundary, NOT a "100 %
///   bars" ring: the six full-amplitude hues sit at 1.004 (B, Yl), 1.026
///   (R, Cy) and 1.191 (G, Mg) of that radius, so two of them ride it, two
///   just clear it and green and magenta are a fifth outside. That is the
///   Cb/Cr plane, not an error, and it is why the 100 % set is marked
///   individually below instead of being implied by the circle.
/// - **Percentage rings** at 25/50/75 % of that radius, faint: they are for
///   judging how far a cast has moved, not for reading a value off, so they
///   must never compete with the targets.
/// - **75 % target boxes** for the six colour-bar hues. Boxes rather than dots
///   because a box states a tolerance, which is the question being asked ("is
///   this bar in its box?"). Positioned through `ScopeAnalyzer.chroma`, the
///   same function the analyzer plots samples with — the two cannot drift.
/// - **100 % marks** as short radial ticks rather than boxes: these targets sit
///   on the outer circle or past it — four of the six land within a couple of
///   points of the square's own edge — and a box there would be half outside
///   the scope. A tick pointing out along the hue's own angle says "this hue,
///   full amplitude" without covering the trace.
/// - **The skin-tone line** is the I axis, 123° from +Cb. It is not a
///   decoration: flesh of every complexion falls along it, so a face that sits
///   off it is a white-balance error rather than a taste question. Drawn only
///   to the 100 % circle, and only when the operator wants it — on bars or a
///   chart it is a line across the middle of the measurement.
///
/// Every opacity here is multiplied by the panel's graticule-brightness
/// control, which the vectorscope used to ignore.
struct VectorscopeGraticule: View {
    let side: CGFloat
    let center: CGPoint
    let skinToneLine: Bool
    /// Which matrix the signal is coded in. The targets are a fact about it,
    /// not a constant — see `VectorscopeView.targets(atAmplitude:primaries:)`.
    var primaries: SignalPrimaries = .rec709
    @Environment(\.scopeGridBrightness) private var brightness

    /// The I axis: 123° counter-clockwise from the +Cb axis. Stated as the
    /// angle rather than as a hand-measured end point, because the number is
    /// the standard and the end point is a consequence of it. Internal so a
    /// test can pin it — the line moving by a couple of degrees is invisible
    /// on screen and turns a correct white balance into a reported error.
    static let skinToneAngle = 123.0 * Double.pi / 180

    var body: some View {
        // **One `Canvas` for the whole graticule**, for the reason
        // `ScopeLevelGraticule` is one and measured on the same instrument.
        // It was a `ZStack` of four `Circle`s, a `Path`, and two `ForEach`es
        // over six targets each — a stroked rectangle and a shadowed `Text`
        // apiece, about twenty child views, every one of them laid out and
        // drawn again on every scope publish. Twelve and a half of those a
        // second, on the thread that also lays out the window.
        //
        // Measured before this change (release, one box at 440x300,
        // `ViewScopePanelCostTests`): **7.19 ms** a redraw for the vectorscope
        // against 2.34 for the waveform, which draws one image and this
        // graticule's simpler cousin. The image is the same in both; the
        // difference was here.
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            draw(in: context)
        }
    }

    private func draw(in context: GraphicsContext) {
        var context = context
        // the boundary and the three quiet saturation rings. `strokeBorder`
        // strokes INSIDE the frame, so each radius loses half a line width —
        // kept exactly, or every ring moves by a quarter point.
        for ring in [0.25, 0.5, 0.75] {
            stroke(circleOf: side * ring, lineWidth: 0.5,
                   opacity: 0.16, in: &context)
        }
        stroke(circleOf: side, lineWidth: 0.7, opacity: 0.42, in: &context)

        var axes = Path()
        axes.move(to: CGPoint(x: center.x - side / 2, y: center.y))
        axes.addLine(to: CGPoint(x: center.x + side / 2, y: center.y))
        axes.move(to: CGPoint(x: center.x, y: center.y - side / 2))
        axes.addLine(to: CGPoint(x: center.x, y: center.y + side / 2))
        if skinToneLine {
            axes.move(to: center)
            // view coordinates put +y downward, so the Cr component of the
            // angle is subtracted rather than added
            axes.addLine(to: CGPoint(
                x: center.x + cos(Self.skinToneAngle) * side / 2,
                y: center.y - sin(Self.skinToneAngle) * side / 2))
        }
        context.stroke(axes, with: .color(.white.opacity(0.28 * brightness)),
                       lineWidth: 0.5)

        // A short tick along each hue's own radius, ending at the 100 % point.
        var ticks = Path()
        for target in VectorscopeView.targets100(primaries) {
            let at = point(target)
            let dx = at.x - center.x, dy = at.y - center.y
            ticks.move(to: CGPoint(x: center.x + dx * 0.9,
                                   y: center.y + dy * 0.9))
            ticks.addLine(to: at)
        }
        context.stroke(ticks, with: .color(.white.opacity(0.4 * brightness)),
                       lineWidth: 1)

        // The six 75 % boxes, one path — a box states a tolerance, which is
        // the question a colourist is asking of a bar.
        var boxes = Path()
        for target in VectorscopeView.targets75(primaries) {
            let at = point(target)
            boxes.addRect(CGRect(x: at.x - 4.5 + 0.35, y: at.y - 4.5 + 0.35,
                                 width: 9 - 0.7, height: 9 - 0.7))
        }
        context.stroke(boxes, with: .color(.white.opacity(0.55 * brightness)),
                       lineWidth: 0.7)

        // The shadow once, around every label, instead of once per label —
        // a per-`Text` shadow is an offscreen pass apiece.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
            for target in VectorscopeView.targets75(primaries) {
                let at = point(target)
                let text = Text(target.id)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4 + 0.35 * brightness))
                layer.draw(text, at: CGPoint(x: at.x + 11, y: at.y - 8))
            }
        }
    }

    /// A ring of `diameter` centred on the scope, stroked inside its own edge
    /// exactly as `Circle().strokeBorder` did.
    private func stroke(circleOf diameter: CGFloat, lineWidth: CGFloat,
                        opacity: Double, in context: inout GraphicsContext) {
        let inset = diameter - lineWidth
        let rect = CGRect(x: center.x - inset / 2, y: center.y - inset / 2,
                          width: inset, height: inset)
        context.stroke(Path(ellipseIn: rect),
                       with: .color(.white.opacity(opacity * brightness)),
                       lineWidth: lineWidth)
    }

    private func point(_ target: VectorscopeView.VectorTarget) -> CGPoint {
        CGPoint(x: center.x - side / 2 + target.x * side,
                y: center.y - side / 2 + target.y * side)
    }
}
