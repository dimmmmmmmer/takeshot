import CaptureCore
import CoreGraphics
import SwiftUI

/// How a level scope labels its axis.
enum ScopeScaleMode: String, CaseIterable {
    /// 0…100 %, the scale an operator judges exposure on.
    case percent = "100"
    /// 10-bit code values, the scale an engineer judges a signal on.
    case tenBitCode = "1023"

    init(setting: String) { self = ScopeScaleMode(rawValue: setting) ?? .percent }
}

/// One graticule line and the number that belongs to it.
struct ScopeTick: Identifiable {
    /// How loudly the line is drawn — the nominal pair is the reference the
    /// operator actually judges against, so it outranks everything else.
    enum Weight {
        case nominal
        case major
        case minor

        var opacity: Double {
            switch self {
            case .nominal: return 0.7
            case .major: return 0.45
            case .minor: return 0.22
            }
        }

        /// The weight a percent mark carries. Stated once because the vertical
        /// ladder and the histogram's horizontal one draw the same percentages,
        /// and two copies of "which of these is the loud one" is how a scope
        /// ends up emphasising a different line from the scope beside it.
        static func ofPercent(_ percent: Int) -> Weight {
            if percent == 0 || percent == 100 { return .nominal }
            return percent == 50 ? .major : .minor
        }
    }

    /// Position ALONG the axis the tick belongs to, 0…1: down the canvas for a
    /// level scope, left to right for the histogram's code axis.
    let unit: Double
    let label: String
    let weight: Weight
    /// Whether the tick draws a rule as well as a number.
    ///
    /// The two ends of the map do not. The edge of the canvas is already the
    /// edge of the scale, and a rule drawn on it is a hairline hard against the
    /// frame — which is the kind of mark these numbers exist to explain away,
    /// not to add another of.
    var drawsRule = true
    var id: Double { unit }
}

/// The vertical mapping every level scope is drawn through: the waveform, the
/// parade, their value numbers, and — turned on its side — the histogram's code
/// axis.
///
/// One type because the four used to place their own marks: the waveform drew
/// lines at fixed fractions of its height, the value scale spread numbers with
/// `Spacer()`s beside the box, and the histogram had a third set hard-coded. As
/// long as the map's top row was 100 % and its bottom row 0 %, three different
/// spellings of the same arithmetic agreed by accident. They stop agreeing the
/// moment the analyzer reads the 10-bit WIRE, where 100 % is not the top of the
/// map any more — there is signal above it.
struct ScopeAxis {
    let nominal: ScopeNominalRange
    let mode: ScopeScaleMode

    /// Position down the canvas of a signal level (0 = black, 1 = white).
    /// Levels outside 0…1 are the excursions, and they land outside the
    /// nominal pair rather than being clamped onto it.
    func unit(ofLevel level: Double) -> Double { nominal.unit(ofLevel: level) }

    /// The same for a horizontal code axis, where x grows with the code.
    func x(ofLevel level: Double) -> Double { 1 - unit(ofLevel: level) }

    /// Where a 10-bit CODE sits on that horizontal axis: 0 is the left edge
    /// (code 0), 1 the right (code 1023). Deliberately independent of the
    /// nominal pair — a code is where it is whatever the levels are.
    func x(ofCode code: Int) -> Double { Double(code) / 1023 }

    /// The bands the trace can reach that are outside the nominal range —
    /// Resolve's "below 0 / above 100" territory. Empty on a full-range frame,
    /// where there is nothing outside the nominal range to shade.
    var excursionBands: [(from: Double, to: Double)] {
        guard nominal.showsExcursions else { return [] }
        return [(0, nominal.white), (nominal.black, 1)]
    }

    /// Lines and numbers, top of the canvas first.
    ///
    /// Percent mode is a broadcast waveform monitor's ladder: every 10 %, with
    /// 50 % stronger and the 0/100 pair strongest. Code mode is linear over the
    /// WHOLE map rather than over the nominal range — a 10-bit code axis has
    /// nothing to do with where reference black happens to sit, and drawing it
    /// any other way would put "0" somewhere other than the bottom of a map
    /// whose bottom row IS code 0.
    var ticks: [ScopeTick] {
        mode == .percent ? percentTicks : codeTicks
    }

    private var percentTicks: [ScopeTick] {
        var out = excursionTicks
        for percent in stride(from: 100, through: 0, by: -10) {
            let weight: ScopeTick.Weight = .ofPercent(percent)
            out.append(ScopeTick(unit: unit(ofLevel: Double(percent) / 100),
                                 label: String(percent), weight: weight))
        }
        return out
    }

    /// The two ends of the map, named at the scale.
    ///
    /// The shaded excursion bands were the owner's "unexplained limit lines at
    /// the top and bottom": a strip of tint whose inner edge reads as a rule and
    /// whose outer edge is the frame, with nothing anywhere saying what the
    /// territory between them is. It is the room the wire signal has above 100 %
    /// and below 0 %, and the cheapest way to say so is to put the number on it
    /// — a band running from a labelled 100 to a labelled 109 needs no caption.
    ///
    /// Percent mode only, and only on a wire frame: on a full-range one these
    /// ARE 100 and 0 and the ladder already draws them, and in code mode the
    /// ends of the map are 1023 and 0, which `codeTicks` names.
    private var excursionTicks: [ScopeTick] {
        guard nominal.showsExcursions else { return [] }
        let levels = nominal.visibleLevels
        return [ScopeTick(unit: 0, label: percentLabel(levels.upperBound),
                          weight: .minor, drawsRule: false),
                ScopeTick(unit: 1, label: percentLabel(levels.lowerBound),
                          weight: .minor, drawsRule: false)]
    }

    private func percentLabel(_ level: Double) -> String {
        String(Int((level * 100).rounded()))
    }

    private var codeTicks: [ScopeTick] {
        var out: [ScopeTick] = []
        for step in stride(from: 1024, through: 0, by: -128) {
            let code = min(1023, step)
            let position = 1 - Double(code) / 1023
            out.append(ScopeTick(unit: position, label: String(code),
                                 weight: code == 512 ? .major : .minor))
        }
        return out
    }

    /// In code mode the nominal pair is not in the tick list — the numbers are
    /// codes and 0 % is code 64 — so it is drawn separately. In percent mode it
    /// already is, and this is empty.
    var extraNominalUnits: [Double] {
        mode == .tenBitCode ? [nominal.white, nominal.black] : []
    }

    /// The marks a horizontal code axis carries — the histogram's — left to
    /// right. Five across rather than the vertical ladder's eleven: a histogram
    /// is 256 bins wide in a box a couple of hundred points across, and a rule
    /// every 10 % turns the shape being measured into a picket fence.
    ///
    /// The two modes are NOT the same marks flipped. Percent mode names signal
    /// levels, so its marks ride with the nominal pair; code mode names codes,
    /// which sit where they sit whatever the levels are. Placing the code
    /// labels by level instead would print "1023" over the bin holding code
    /// 940 on every wire frame — a number on the wrong tick, which is the exact
    /// fault this type was extracted to make impossible.
    var horizontalTicks: [ScopeTick] {
        mode == .percent ? horizontalPercentTicks : horizontalCodeTicks
    }

    private var horizontalPercentTicks: [ScopeTick] {
        var out: [ScopeTick] = []
        for percent in stride(from: 0, through: 100, by: 25) {
            let weight: ScopeTick.Weight = .ofPercent(percent)
            out.append(ScopeTick(unit: x(ofLevel: Double(percent) / 100),
                                 label: String(percent), weight: weight))
        }
        return out
    }

    private var horizontalCodeTicks: [ScopeTick] {
        let codes: [Int] = [0, 256, 512, 768, 1023]
        var out: [ScopeTick] = []
        for code in codes {
            let weight: ScopeTick.Weight = code == 512 ? .major : .minor
            out.append(ScopeTick(unit: x(ofCode: code), label: String(code),
                                 weight: weight))
        }
        return out
    }

    /// The nominal pair on that horizontal axis, for the mode whose own numbers
    /// do not already name it — the mirror of `extraNominalUnits`.
    var extraNominalXs: [Double] { extraNominalUnits.map { 1 - $0 } }
}

/// Height reserved for one axis number. The labels sit INSIDE the trace canvas
/// now (they used to be a column beside it, which is where the operator kept
/// losing them when a box got narrow), so this is what keeps the end numbers
/// from hanging half off the top and bottom edges. Shared with the histogram's
/// code axis in `ScopeCodeAxis.swift` — one number, so the two axes inset their
/// end labels by the same amount.
let scopeLabelHeight: CGFloat = 10

/// The graticule of a level scope — the lines, the shaded excursion bands and
/// the numbers, all placed by `ScopeAxis`.
struct ScopeLevelGraticule: View {
    let nominal: ScopeNominalRange
    @Environment(\.scopeGridBrightness) private var brightness
    @Environment(\.scopeScaleMode) private var mode

    var body: some View {
        GeometryReader { geo in
            let axis = ScopeAxis(nominal: nominal, mode: mode)
            ZStack(alignment: .topLeading) {
                bands(axis, in: geo.size)
                lines(axis, in: geo.size)
                numbers(axis, in: geo.size)
            }
        }
    }

    /// Everything the trace can reach that is outside the nominal range, tinted
    /// rather than labelled: a number there would collide with the 0 and 100 it
    /// sits a few points away from, and the band says the same thing.
    private func bands(_ axis: ScopeAxis, in size: CGSize) -> some View {
        ForEach(axis.excursionBands.indices, id: \.self) { index in
            let band = axis.excursionBands[index]
            Rectangle()
                .fill(.white.opacity(0.05 + 0.05 * brightness))
                .frame(height: size.height * (band.to - band.from))
                .offset(y: size.height * band.from)
        }
    }

    private func lines(_ axis: ScopeAxis, in size: CGSize) -> some View {
        ZStack {
            ForEach(axis.ticks.filter(\.drawsRule)) { tick in
                rule(at: tick.unit, in: size, opacity: tick.weight.opacity)
            }
            ForEach(axis.extraNominalUnits, id: \.self) { unit in
                rule(at: unit, in: size,
                     opacity: ScopeTick.Weight.nominal.opacity)
            }
        }
    }

    private func rule(at unit: Double, in size: CGSize,
                      opacity: Double) -> some View {
        Path { path in
            let y = size.height * unit
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(.white.opacity(opacity * brightness), lineWidth: 0.5)
    }

    /// The numbers, each one sitting on its own line inside the canvas.
    ///
    /// Clamped to the canvas at both ends: the 100 and the 0 are exactly on the
    /// top and bottom rules, and centring them there would put half of each
    /// outside the box — which is the complaint this whole change answers.
    private func numbers(_ axis: ScopeAxis, in size: CGSize) -> some View {
        ForEach(legible(axis.ticks, in: size)) { tick in
            Text(tick.label)
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35 + brightness * 0.5))
                .shadow(color: .black.opacity(0.9), radius: 1)
                .frame(height: scopeLabelHeight)
                .padding(.leading, 3)
                .offset(y: labelTop(tick, in: size))
        }
    }

    private func labelTop(_ tick: ScopeTick, in size: CGSize) -> CGFloat {
        min(size.height - scopeLabelHeight,
            max(0, size.height * tick.unit - scopeLabelHeight / 2))
    }

    /// The ticks whose numbers can actually be read, loudest first.
    ///
    /// A short canvas puts the excursion end labels within a few points of the
    /// 100 and the 0 they explain — 109 over 100 is worse than no 109 at all.
    /// Sorting by weight before position means the reference pair always wins
    /// the space and the explanation is what gets dropped, which is the right
    /// way round: the box that has no room for it is the in-player glance, not
    /// the window the operator reads a level in.
    private func legible(_ ticks: [ScopeTick], in size: CGSize) -> [ScopeTick] {
        // weight first, then position: `sorted` is not stable, and which of
        // two equally quiet numbers survives may not depend on the run
        let ordered = ticks.sorted {
            $0.weight.opacity == $1.weight.opacity
                ? $0.unit < $1.unit
                : $0.weight.opacity > $1.weight.opacity
        }
        var kept: [ScopeTick] = []
        for tick in ordered
        where !kept.contains(where: {
            abs(labelTop($0, in: size) - labelTop(tick, in: size))
                < scopeLabelHeight
        }) {
            kept.append(tick)
        }
        return kept
    }
}
