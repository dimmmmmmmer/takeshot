import CoreGraphics
import Foundation

/// **How far a daily is scaled down** (owner: "во, точно, давай сделаем выбор
/// насколько снижать резолюшн").
///
/// A daily used to be 1080p and nothing else: everything above it came down to
/// fit, everything below kept its size. That is the right default and it is
/// the wrong only answer — a unit reviewing on a 4K monitor wants the picture
/// it shot, and a unit sending rushes over a hotel connection wants a fifth of
/// it. Both are the same run with a different ceiling.
///
/// # It is a CEILING, not a size
///
/// Every case bounds the longest edges and nothing is ever scaled UP: a 1080p
/// source under a 4K ceiling comes out 1080p, because upscaling buys an
/// editor nothing and costs the disk four times the bytes. The aspect is the
/// source's throughout — the ceiling is a box the picture is fitted into, the
/// same arithmetic `DailiesEngine.outputSize` always did.
///
/// # Raw values are numbers, and they are persisted
///
/// The raw value is the height as digits ("1080"), because it is written into
/// the settings blob and into a run's recipe and has to mean the same thing to
/// every build that reads it. A case renamed in Swift keeps its string.
public enum DailiesResolution: String, CaseIterable, Codable, Sendable,
                               Identifiable {
    /// No ceiling at all: the daily is the source's own raster, desqueezed if
    /// the run bakes a desqueeze. A ProRes daily of a 6K camera original is a
    /// deliberate thing to ask for and this is how it is asked for.
    case source
    case uhd = "2160"
    /// What every daily was before this existed, and still the default.
    case hd = "1080"
    case hd720 = "720"
    case sd = "540"

    public var id: String { rawValue }

    /// The box the picture is fitted into, or nil for "leave it alone".
    ///
    /// 16:9 boxes, and that is not an assumption about the source: a box
    /// bounds BOTH edges, so a 4:3 or a 2.39 source is fitted inside it by
    /// whichever edge runs out first and keeps its own shape either way.
    public var limit: CGSize? {
        switch self {
        case .source: return nil
        case .uhd: return CGSize(width: 3840, height: 2160)
        case .hd: return CGSize(width: 1920, height: 1080)
        case .hd720: return CGSize(width: 1280, height: 720)
        case .sd: return CGSize(width: 960, height: 540)
        }
    }

    /// What the picker shows. The height with a `p`, which is how everyone on
    /// a set says these — "ten-eighty", "seven-twenty" — and the one case that
    /// is not a number reads as a word.
    public var label: String {
        self == .source ? "Source" : "\(rawValue)p"
    }
}
