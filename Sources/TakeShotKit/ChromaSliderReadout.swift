import Foundation

/// What the number beside a chroma dial says, derived from the dial's own
/// range instead of stated a second time next to it.
///
/// # Why this is one place and was three spellings of one question
///
/// Three of these rows ask the same question — what fraction of this slider's
/// travel is the dial at — and they asked it three different ways, because the
/// range and the readout were two separate arguments to `ChromaSliderRow` and
/// nothing held them together:
///
/// | dial | range it was given | readout it was given |
/// | --- | --- | --- |
/// | tolerance | `0...ChromaKey.maxTolerance` | `percent(value / ChromaKey.maxTolerance)` |
/// | softness | `0...ChromaKey.maxSoftness` | `percent(value)` — no divisor at all |
/// | spill | `0...1` | `percent(value)` |
///
/// All three are right today and two of them only by coincidence: softness
/// because `maxSoftness` happens to be 1.0, spill because its range is a
/// literal 1. `maxSoftness` is a real constant with a real argument behind it
/// (the feather is a FRACTION of the tolerance, so its ceiling is 1) and the
/// day that argument changes, the softness dial silently stops reaching 100
/// while its slider still reaches the end — a control the operator can see is
/// at the top of its travel, reading 80. Nothing would fail; the number would
/// just be wrong, on the one panel where the operator is matching a number to a
/// cyc they are looking at.
///
/// So the readout is no longer a second argument that happens to agree with the
/// range. The row has the range; the row computes the text. Moving a constant
/// now moves both ends of the dial together, which is the only version of this
/// that stays true without anybody remembering it.
///
/// # The other two are genuinely different questions
///
/// Stated as cases rather than folded in, because a shared spelling that means
/// two things is how this went wrong in the first place:
///
/// - the plate offsets read as percent OF THE FRAME, not of their travel. At
///   `maxOffset` the plate is shifted half a frame, and `+50` is what the
///   operator is being told; `+100` would be a different (and wrong) sentence
///   about the same knob position.
/// - the plate scale is a multiplier, and 2.5× is not a percentage of
///   anything.
enum ChromaSliderReadout {
    /// Where the knob is, as a percentage of the slider's own travel. The three
    /// dials that reach 100 at the end of their range, whatever that range is.
    case percentOfTravel
    /// Percent of the FRAME, signed, for the two plate offsets — a different
    /// denominator on purpose (see above).
    case signedPercentOfFrame
    /// A multiplier, for the plate scale.
    case multiplier

    /// The text for `value` on a slider spanning `range`.
    ///
    /// The percentage is clamped to the travel because the SLIDER is: a value
    /// outside the range pins the knob at the end, and a readout of 120 beside
    /// a knob that has stopped is the control disagreeing with itself. The
    /// settings blob is hand-editable and `ChromaKey.clamp()` is what normally
    /// keeps it in range, so this is the second line of that defence rather
    /// than the first.
    ///
    /// A zero-width range answers 0 rather than dividing by it — which is a
    /// hazard only once the divisor comes from the RANGE instead of a named
    /// non-zero constant.
    ///
    /// Measured rather than assumed, because the obvious worry turned out to be
    /// the wrong one. Without the guard, `0` on `0...0` divides 0 by 0 and the
    /// clamp absorbs the NaN — `max(0, .nan)` is 0 in Swift, since `nan >= 0`
    /// is false — so it answers "0" by accident and never reaches the `Int(_:)`
    /// trap. What is NOT absorbed is a value off a degenerate range: `5` on
    /// `3...3` divides by zero to +∞, clamps to 1 and reads **100**, i.e. "all
    /// the way along" a travel of zero, which is a sentence with no referent.
    /// The guard is here so the answer comes from the rule rather than from how
    /// `min`/`max` happen to treat infinity and NaN.
    func text(for value: Double, in range: ClosedRange<Double>) -> String {
        switch self {
        case .percentOfTravel:
            let travel = range.upperBound - range.lowerBound
            guard travel > 0 else { return "0" }
            let fraction = (value - range.lowerBound) / travel
            return "\(Int((min(1, max(0, fraction)) * 100).rounded()))"
        case .signedPercentOfFrame:
            return String(format: "%+d", Int((value * 100).rounded()))
        case .multiplier:
            return String(format: "%.2f", value)
        }
    }
}
