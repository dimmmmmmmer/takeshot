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

    var body: some View {
        ZStack {
            locus
            if showsOtherGamut {
                triangle(otherPrimaries.colorPrimaries, opacity: 0.3,
                         width: 0.7, label: Self.name(of: otherPrimaries))
            }
            triangle(primaries.colorPrimaries, opacity: 0.62, width: 1,
                     label: Self.name(of: primaries))
            whitePoint
            ForEach(Self.labelledWavelengths, id: \.self) { nanometres in
                wavelengthLabel(nanometres)
            }
        }
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
    private var locus: some View {
        Path { path in
            let points = CIE1931.spectralLocus.map(point)
            guard let first = points.first else { return }
            path.move(to: first)
            for next in points.dropFirst() { path.addLine(to: next) }
            path.closeSubpath()
        }
        .stroke(.white.opacity(0.5 * brightness), lineWidth: 0.8)
    }

    private func triangle(_ gamut: ColorPrimaries, opacity: Double,
                          width: CGFloat, label: String) -> some View {
        let corners = gamut.triangle.map(point)
        return ZStack {
            Path { path in
                guard let first = corners.first else { return }
                path.move(to: first)
                for next in corners.dropFirst() { path.addLine(to: next) }
                path.closeSubpath()
            }
            .stroke(.white.opacity(opacity * brightness), lineWidth: width)
            // INSIDE the triangle at its red corner, pushed toward the white
            // point. Outside it collided with the locus's own wavelength
            // numbers, which are pushed the other way along the same radius —
            // measured on a render: "2020" landed on top of "620".
            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3 + opacity * 0.5 * brightness))
                .shadow(color: .black.opacity(0.9), radius: 1)
                .position(inward(from: corners.first ?? center, by: 15))
        }
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
    private var whitePoint: some View {
        let at = point(ColorPrimaries.d65)
        let arm: CGFloat = 4
        return Path { path in
            path.move(to: CGPoint(x: at.x - arm, y: at.y))
            path.addLine(to: CGPoint(x: at.x + arm, y: at.y))
            path.move(to: CGPoint(x: at.x, y: at.y - arm))
            path.addLine(to: CGPoint(x: at.x, y: at.y + arm))
        }
        .stroke(.white.opacity(0.75 * brightness), lineWidth: 0.9)
    }

    /// A wavelength number just outside the locus, pushed away from the white
    /// point along its own radius so it never sits on the curve it names.
    @ViewBuilder
    private func wavelengthLabel(_ nanometres: Int) -> some View {
        if let locusPoint = CIE1931.locusPoint(atWavelength: nanometres) {
            let at = point(locusPoint)
            let white = point(ColorPrimaries.d65)
            let dx = at.x - white.x, dy = at.y - white.y
            let length = max(1, (dx * dx + dy * dy).squareRoot())
            Text(String(nanometres))
                .font(.system(size: 6, weight: .medium))
                .foregroundStyle(.white.opacity(0.25 + 0.35 * brightness))
                .shadow(color: .black.opacity(0.9), radius: 1)
                .position(x: at.x + dx / length * 9, y: at.y + dy / length * 9)
        }
    }
}
