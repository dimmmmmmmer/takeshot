import Foundation

/// What a wire frame's code values mean, for the scopes only.
///
/// The pipeline's own levels handling expands limited-range sources into the
/// display buffer and CLAMPS whatever falls outside 64…940 while doing it. A
/// measurement instrument may not do that: a camera legally rides its blacks
/// down to code 4 and its highlights up to 1019, and a scope that cannot show
/// those codes cannot be used to spot the clip. So the analyzer is handed the
/// wire frame and told what its codes mean, instead of the already-expanded
/// (and already-clipped) display buffer.
public enum ScopeWireLevels: Sendable, Equatable {
    /// The codes already fill the scale: a full-range source, or any buffer the
    /// levels stage has already expanded.
    case full
    /// Studio swing — nominal black at 64, nominal white at 940 in 10-bit
    /// units, with legal excursions on both sides of them.
    case limited

    /// 10-bit code of nominal black / nominal white on this scale.
    var nominalCodes: (black: Int, white: Int) {
        switch self {
        case .full: return (0, 1023)
        case .limited: return (64, 940)
        }
    }

    /// How much the chroma of a raw sample has to be scaled to land on the
    /// full-range vectorscope. The graticule targets are positioned from
    /// full-range R'G'B', so an unexpanded limited-range frame would plot a 75%
    /// bar at 876/1023 of its target radius — inside its box, which reads as a
    /// desaturated camera rather than as an un-expanded signal.
    ///
    /// The black offset cancels in a colour difference, so a single gain is the
    /// whole correction.
    var chromaGain: Double {
        switch self {
        case .full: return 1
        case .limited: return 1023.0 / 876.0
        }
    }
}

/// Where the nominal signal levels sit on a trace map whose top row is the
/// highest code value and whose bottom row is the lowest.
///
/// Every scope's graticule is placed through this and nothing else, so the
/// waveform's 0 % line, the parade's, the histogram's black mark and the value
/// scale beside them cannot drift apart. On a full-range frame it is the
/// identity — top row is 100 %, bottom row is 0 % — and the picture is exactly
/// what it always was.
public struct ScopeNominalRange: Sendable, Equatable {
    /// Unit position measured DOWN from the top of the map (0 = top row,
    /// 1 = bottom row) of reference white, 100 %.
    public let white: Double
    /// The same, for reference black, 0 %.
    public let black: Double

    /// The map's top row IS 100 % and its bottom row IS 0 %.
    public static let full = ScopeNominalRange(white: 0, black: 1)

    public init(white: Double, black: Double) {
        self.white = white
        self.black = black
    }

    /// Unit position of a signal level, 0 = black, 1 = white. Values outside
    /// 0…1 are the excursions and land outside `white`…`black` — that is the
    /// point of carrying this around rather than assuming the map's ends.
    public func unit(ofLevel level: Double) -> Double {
        white + (1 - level) * (black - white)
    }

    /// The inverse: what level a unit position down the map represents.
    public func level(atUnit unit: Double) -> Double {
        guard black != white else { return 0 }
        return 1 - (unit - white) / (black - white)
    }

    /// The levels visible on the map, lowest first — 0…1 for a full-range
    /// frame, a little wider when the trace can carry excursions.
    public var visibleLevels: ClosedRange<Double> {
        let low = level(atUnit: 1), high = level(atUnit: 0)
        return min(low, high)...max(low, high)
    }

    /// True when the map has room above 100 % or below 0 %, i.e. the scopes are
    /// reading a wire signal rather than an expanded display buffer.
    public var showsExcursions: Bool {
        white > 0.0001 || black < 0.9999
    }
}
