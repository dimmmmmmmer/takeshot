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
    @Environment(\.scopeGridBrightness) private var brightness

    /// The I axis: 123° counter-clockwise from the +Cb axis. Stated as the
    /// angle rather than as a hand-measured end point, because the number is
    /// the standard and the end point is a consequence of it. Internal so a
    /// test can pin it — the line moving by a couple of degrees is invisible
    /// on screen and turns a correct white balance into a reported error.
    static let skinToneAngle = 123.0 * Double.pi / 180

    var body: some View {
        ZStack {
            rings
            axes
            ForEach(VectorscopeView.targets100) { target in
                fullAmplitudeTick(target)
            }
            ForEach(VectorscopeView.targets75) { target in
                targetBox(target)
            }
        }
    }

    /// The outer boundary plus the three quiet saturation rings inside it.
    private var rings: some View {
        ZStack {
            ForEach([0.25, 0.5, 0.75], id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(0.16 * brightness),
                                  lineWidth: 0.5)
                    .frame(width: side * ring, height: side * ring)
                    .position(center)
            }
            Circle()
                .strokeBorder(.white.opacity(0.42 * brightness), lineWidth: 0.7)
                .frame(width: side, height: side)
                .position(center)
        }
    }

    /// The neutral cross and, when it is wanted, the skin-tone line.
    private var axes: some View {
        Path { p in
            p.move(to: CGPoint(x: center.x - side / 2, y: center.y))
            p.addLine(to: CGPoint(x: center.x + side / 2, y: center.y))
            p.move(to: CGPoint(x: center.x, y: center.y - side / 2))
            p.addLine(to: CGPoint(x: center.x, y: center.y + side / 2))
            if skinToneLine {
                p.move(to: center)
                // view coordinates put +y downward, so the Cr component of the
                // angle is subtracted rather than added
                p.addLine(to: CGPoint(
                    x: center.x + cos(Self.skinToneAngle) * side / 2,
                    y: center.y - sin(Self.skinToneAngle) * side / 2))
            }
        }
        .stroke(.white.opacity(0.28 * brightness), lineWidth: 0.5)
    }

    private func point(_ target: VectorscopeView.VectorTarget) -> CGPoint {
        CGPoint(x: center.x - side / 2 + target.x * side,
                y: center.y - side / 2 + target.y * side)
    }

    private func targetBox(_ target: VectorscopeView.VectorTarget) -> some View {
        let at = point(target)
        return ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.55 * brightness), lineWidth: 0.7)
                .frame(width: 9, height: 9)
                .position(at)
            Text(target.id)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4 + 0.35 * brightness))
                .shadow(color: .black.opacity(0.9), radius: 1)
                .position(x: at.x + 11, y: at.y - 8)
        }
    }

    /// A short tick along the hue's own radius, ending at the 100 % point.
    private func fullAmplitudeTick(
        _ target: VectorscopeView.VectorTarget) -> some View {
        let at = point(target)
        let dx = at.x - center.x, dy = at.y - center.y
        return Path { p in
            p.move(to: CGPoint(x: center.x + dx * 0.9, y: center.y + dy * 0.9))
            p.addLine(to: at)
        }
        .stroke(.white.opacity(0.4 * brightness), lineWidth: 1)
    }
}
