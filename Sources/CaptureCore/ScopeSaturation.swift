import Foundation

/// **How saturated a trace cell's colour is, and how opaque that makes it.**
///
/// Owner: "чтоб вейвформа по прозрачности реагировала на насыщенность в шоте —
/// то что насыщеннее видно явнее". The coloured waveform has always carried
/// the mean colour of the pixels that made each cell; what it could not do is
/// say which parts of the picture are the COLOURED ones — a pale sky and a
/// neon sign at the same level draw the same weight of trace, and the one an
/// operator is looking for is the neon.
///
/// So the trace's opacity follows the cell's saturation. A saturated cell is
/// drawn solid and a neutral one falls back toward the floor, which is what
/// "more saturated, more clearly seen" means on a scope: the emphasis is
/// RELATIVE, and the floor is what keeps a grey-card exposure read legible
/// while it happens.
///
/// Both halves live here rather than inside the accumulator's cell loop
/// because they are the whole of the operator-visible decision, and because a
/// curve nobody can see the numbers of is a curve nobody can argue with.
enum ScopeSaturation {
    /// What a completely neutral cell is drawn at. The one number in this
    /// file with a judgement in it:
    ///
    /// - at 1.0 the feature does nothing at all;
    /// - at 0.55 the neutral trace is a little over half the weight of a
    ///   saturated one, which is a clear difference on a black scope and
    ///   still a trace an operator can read a highlight roll-off off;
    /// - below about 0.4 a desaturated shot — a night exterior, a bleached
    ///   interior — has nothing left to read at all, which is the waveform
    ///   failing at its first job in order to do its second.
    ///
    /// Measured on the curve below: neutral 0.55, a quarter saturated 0.66,
    /// half 0.78, fully saturated 1.00.
    static let neutralOpacity = 0.55

    /// HSV saturation of a cell's mean colour, 0 (neutral or black) to 1.
    ///
    /// On the GAMMA-ENCODED codes, deliberately: this is a statement about
    /// what the operator sees on the screen, not about the light that made
    /// it, and every other saturation an eye judges — a vectorscope's radius
    /// included — is read off the coded signal too.
    ///
    /// Black has no saturation rather than an undefined one: a cell with no
    /// light in it has no hue, the same answer `RGBToXYZ.chromaticity` gives
    /// for the same reason.
    static func of(r: Double, g: Double, b: Double) -> Double {
        let high = max(r, max(g, b))
        guard high > 0 else { return 0 }
        let low = min(r, min(g, b))
        return min(1, max(0, (high - low) / high))
    }

    /// The opacity a cell of that saturation is drawn at — linear between the
    /// floor and solid.
    ///
    /// Linear and not a curve, because the thing being read is a COMPARISON
    /// between parts of one picture: a square root would push everything
    /// mildly coloured straight to solid and leave only the last few per cent
    /// doing any distinguishing.
    static func opacity(forSaturation saturation: Double) -> Double {
        let clamped = min(1, max(0, saturation))
        return neutralOpacity + (1 - neutralOpacity) * clamped
    }
}
