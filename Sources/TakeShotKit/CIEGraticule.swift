import CaptureCore
import CoreGraphics
import SwiftUI

/// The chromaticity chart's graticule, and what each part of it is for.
///
/// A chromaticity map with nothing on it is unreadable — a cloud of colour in a
/// square, with no way to tell whether it is inside anything. Every mark here
/// answers a question an operator asks out loud:
///
/// - **The spectral locus** — the horseshoe — is the boundary of colour itself:
///   nothing real can sit outside it, so it is what turns the square into a
///   diagram. Drawn from `CIE1931.spectralLocus`, the published 2° observer at
///   5 nm, and closed with the **line of purples** from 380 nm to 700 nm, which
///   is straight because no single wavelength makes a purple.
/// - **The gamut triangles** are the answer to "will this survive delivery".
///   The frame's OWN primaries are drawn bright — that is the container the
///   codes are actually stated in, and nothing can be outside it, which makes
///   it the reference edge rather than a warning line. The other gamut is drawn
///   quiet, and is the one that can be crossed: a Rec.2020 camera pointed at a
///   saturated practical puts trace outside the Rec.709 triangle, and that is
///   footage that will change colour when it is delivered to a 709 master.
/// - **D65** is where neutral must land. A white card that plots off it is a
///   white-balance error, and being able to see that against a fixed cross is
///   the same job the vectorscope's centre does one axis at a time.
/// - **Wavelength ticks** at 480, 500, 520, 560, 600 and 620 nm name the
///   horseshoe. Without them the locus is a shape; with them it is a spectrum,
///   and "the trace is running up toward 520" is a sentence about the picture.
///
/// Everything is placed through `ScopeData.cieUnit`, the same function the
/// analyzer deposits samples through — so a primary's corner and a full-
/// amplitude sample of that primary land on the same point by construction.
/// Every opacity is multiplied by the panel's graticule-brightness control.
struct CIEGraticule: View {
    let side: CGFloat
    let center: CGPoint
    /// The analyzed frame's primaries: which triangle is the loud one.
    let primaries: SignalPrimaries
    let showsOtherGamut: Bool
    @Environment(\.scopeGridBrightness) private var brightness

    /// The wavelengths the locus is labelled at, nm. Five, spread along the arc
    /// — measured on a render rather than chosen: 620 was in the list and sat
    /// on top of the 600, because the locus's red end crowds four decades of
    /// wavelength into a tenth of its length.
    static let labelledWavelengths = [480, 500, 520, 560, 600]

    /// The gamut the frame is NOT in — the triangle that can be crossed.
    var otherPrimaries: SignalPrimaries { Self.other(than: primaries) }

    /// Stated once, because the box header's chip names this gamut and the
    /// graticule draws it: two spellings of "the other one" is how a chip ends
    /// up labelled 709 over a 2020 triangle.
    static func other(than primaries: SignalPrimaries) -> SignalPrimaries {
        primaries == .rec2020 ? .rec709 : .rec2020
    }

    /// **One `Canvas`, like every other scope graticule.**
    ///
    /// This was the last one still drawn as a view TREE, and it was the
    /// heaviest of them: a stroked `Path` rebuilt from all 65 spectral-locus
    /// points, two gamut triangles each a `Path` plus its own `.shadow`ed
    /// `Text`, a white-point cross, and a `ForEach` over five more shadowed,
    /// `.position`ed `Text`s — about seven separate shadows, each forcing its
    /// own offscreen pass, laid out and rasterized on the main thread on every
    /// scope publish. Twelve and a half of those a second, on the thread that
    /// also lays out the window.
    ///
    /// The other four graticules were converted for exactly this, and measured
    /// — a box went from 8.49 ms to 3.85, a four-up grid from 20.3 to 10.7
    /// against a 16.7 ms frame (`ViewScopePanelCostTests`). This one slipped
    /// past because the rule's test enumerates FILE NAMES and the chart was
    /// added after the list was written, and the bench's box table has no row
    /// for it either — so neither the rule nor the instrument could see the
    /// one scope that broke it. Both are fixed with this.
    ///
    /// The chart is realistically a WINDOW scope: the in-player overlay draws
    /// exactly one kind, and the grid is where several get switched on. That
    /// is why the cost showed up as "the scopes window lags" rather than as
    /// the overlay lagging (owner: "все что я писал лечится если выключить
    /// отдельное окно скопов").
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            draw(in: context)
        }
    }

    private func draw(in context: GraphicsContext) {
        // Taken as a value and never rebound: every call here is non-mutating,
        // and `var context = context` is a warning on the CI toolchain and
        // silence on this one (the vectorscope's copy really is mutated — it
        // hands `&context` to its ring helper). The runner is a second
        // COMPILER, and a warning is a build failure there.
        context.stroke(locusPath, with: .color(.white.opacity(0.5 * brightness)),
                       lineWidth: 0.8)
        if showsOtherGamut {
            context.stroke(trianglePath(otherPrimaries.colorPrimaries),
                           with: .color(.white.opacity(0.3 * brightness)),
                           lineWidth: 0.7)
        }
        context.stroke(trianglePath(primaries.colorPrimaries),
                       with: .color(.white.opacity(0.62 * brightness)),
                       lineWidth: 1)
        context.stroke(whitePointPath,
                       with: .color(.white.opacity(0.75 * brightness)),
                       lineWidth: 0.9)
        // The shadow ONCE, around every label on the chart, instead of once
        // per label — a per-`Text` shadow is an offscreen pass apiece, and
        // there are seven of them here.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
            if showsOtherGamut {
                drawGamutLabel(otherPrimaries, opacity: 0.3, in: &layer)
            }
            drawGamutLabel(primaries, opacity: 0.62, in: &layer)
            for nanometres in Self.labelledWavelengths {
                drawWavelength(nanometres, in: &layer)
            }
        }
    }

    /// A gamut's short name, inside its own triangle at the red corner and
    /// pushed toward the white point. Outside it collided with the locus's own
    /// wavelength numbers, which are pushed the other way along the same
    /// radius — measured on a render: "2020" landed on top of "620".
    private func drawGamutLabel(_ gamut: SignalPrimaries, opacity: Double,
                                in layer: inout GraphicsContext) {
        let corners = gamut.colorPrimaries.triangle.map(point)
        let text = Text(Self.name(of: gamut))
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.white.opacity(0.3 + opacity * 0.5 * brightness))
        layer.draw(text, at: inward(from: corners.first ?? center, by: 15))
    }

    /// A wavelength number just outside the locus, pushed away from the white
    /// point along its own radius so it never sits on the curve it names.
    private func drawWavelength(_ nanometres: Int,
                                in layer: inout GraphicsContext) {
        guard let locusPoint = CIE1931.locusPoint(atWavelength: nanometres)
        else { return }
        let at = point(locusPoint)
        let white = point(ColorPrimaries.d65)
        let dx = at.x - white.x, dy = at.y - white.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        let text = Text(String(nanometres))
            .font(.system(size: 6, weight: .medium))
            .foregroundStyle(.white.opacity(0.25 + 0.35 * brightness))
        layer.draw(text, at: CGPoint(x: at.x + dx / length * 9,
                                     y: at.y + dy / length * 9))
    }

    /// Short names, not localized on purpose — "709" and "2020" are what the
    /// crew says out loud in every language on the call sheet, the same rule
    /// `WireColorimetry.badge` follows.
    static func name(of primaries: SignalPrimaries) -> String {
        primaries == .rec2020 ? "2020" : "709"
    }

    /// A chromaticity as a point in the canvas.
    func point(_ chromaticity: Chromaticity) -> CGPoint {
        let unit = ScopeData.cieUnit(chromaticity)
        return CGPoint(x: center.x - side / 2 + CGFloat(unit.x) * side,
                       y: center.y - side / 2 + CGFloat(unit.y) * side)
    }

    /// The horseshoe plus the line of purples, as one closed path.
    private var locusPath: Path {
        var path = Path()
        let points = CIE1931.spectralLocus.map(point)
        guard let first = points.first else { return path }
        path.move(to: first)
        for next in points.dropFirst() { path.addLine(to: next) }
        path.closeSubpath()
        return path
    }

    private func trianglePath(_ gamut: ColorPrimaries) -> Path {
        var path = Path()
        let corners = gamut.triangle.map(point)
        guard let first = corners.first else { return path }
        path.move(to: first)
        for next in corners.dropFirst() { path.addLine(to: next) }
        path.closeSubpath()
        return path
    }

    /// A point moved `distance` from `at` toward the white point — where a
    /// label sits so it stays on its own side of a corner.
    private func inward(from at: CGPoint, by distance: CGFloat) -> CGPoint {
        let white = point(ColorPrimaries.d65)
        let dx = white.x - at.x, dy = white.y - at.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: at.x + dx / length * distance,
                       y: at.y + dy / length * distance)
    }

    /// D65, as a small cross rather than a dot: a dot on a chart this dense
    /// disappears under the trace it is there to be compared with.
    private var whitePointPath: Path {
        let at = point(ColorPrimaries.d65)
        let arm: CGFloat = 4
        var path = Path()
        path.move(to: CGPoint(x: at.x - arm, y: at.y))
        path.addLine(to: CGPoint(x: at.x + arm, y: at.y))
        path.move(to: CGPoint(x: at.x, y: at.y - arm))
        path.addLine(to: CGPoint(x: at.x, y: at.y + arm))
        return path
    }
}
