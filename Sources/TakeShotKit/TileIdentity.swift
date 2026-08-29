import CoreGraphics
import Foundation

/// **What a tile IS, in the composed picture rather than over it.**
///
/// Every surface `MultiviewComposer` feeds — the hardware monitor, the SDI
/// output, NDI, SRT and every browser watching `LivePicture.grid` — used to see
/// anonymous rectangles. The names, the REC lights and the running timecodes
/// were SwiftUI chrome drawn on the operator's own screen (`MulticamGrid`,
/// `SyncPlayView`), which is the one surface that never needed them: the
/// operator knows which board is which. A director watching four takes does
/// not, and neither does a phone on the camera grid.
///
/// **Two kinds, because the composer's two callers have two kinds of tile.**
/// This is the one thing that must not be flattened. A live tile is a BOARD: a
/// name the operator typed into Settings, and a lamp that is that board's own
/// writer running — in multicam the boards record apart, so the lamp is per
/// pipeline and never the app's. A comparison tile is a FILE: a take's name off
/// the disk, and nothing is writing it, so it has no lamp at all. Modelling
/// that as one struct with a `recording` flag left false for takes would state
/// something untrue — that a take is a camera that happens not to be rolling —
/// and the first person to read it would wire a lamp to it.
///
/// So the difference is an enum with two cases and no shared payload but the
/// name, and `MultiviewComposer` draws what each case actually has.
///
/// **The clock is deliberately NOT in here**, and that is the second half of
/// the modelling. A name and a lamp change on an operator's action — a rename,
/// a REC press — a handful of times a shift. A timecode changes every frame by
/// construction. They also arrive from different places: the label and the lamp
/// are controller state, the timecode arrives on `CapturePipeline.onTimecode`
/// (live) or off the master transport (a comparison). Putting them in one value
/// would make every frame's tick look like a new identity, and the rendered
/// nameplate would be rebuilt 25 times a second to say the same word. The
/// composer takes them separately — `setIdentity` and `setClock` — and the two
/// rates stay apart all the way down to the raster cache.
enum TileIdentity: Equatable, Sendable {
    /// A live board: the name the operator set for it, and whether ITS OWN
    /// pipeline is writing right now.
    ///
    /// The label is `CameraChannel.camLabel` for an extra channel and
    /// `settings.naming.cameraLabel` for the main one — the same two
    /// expressions `MulticamGrid` and the `/cameras` page's tag already read,
    /// so the burned-in name cannot disagree with either.
    case camera(label: String, recording: Bool)

    /// A take being played back in a comparison: the file's display name.
    ///
    /// No lamp, and no flag saying so. Nothing is writing a finished file, and
    /// `SyncPlayModel.Tile` correspondingly has no recording state to read —
    /// `SyncPlayView`'s tile border is unconditional where `MulticamGrid`'s
    /// goes red. This case having no lamp is that fact, restated where the
    /// picture is drawn.
    case take(label: String)

    /// The words on the nameplate. Both kinds have a name; only that much is
    /// shared, which is why it is a computed property here and not a stored
    /// field in a common struct.
    var label: String {
        switch self {
        case .camera(let label, _): return label
        case .take(let label): return label
        }
    }

    /// Whether the nameplate carries the REC lamp.
    ///
    /// A take can never answer true — not because the flag is false but because
    /// the case carries no flag to be true.
    var showsRecordingLamp: Bool {
        switch self {
        case .camera(_, let recording): return recording
        case .take: return false
        }
    }
}

/// **How big the identity is drawn, as a fraction of the tile and nothing
/// else.**
///
/// The composed picture has no idea how large it will be shown. It is one
/// raster that goes to a phone holding a tile at ~640 pixels across and to a
/// director's monitor holding four tiles across 1920, and the H.264 session in
/// between rescales for neither. So the ONLY scale-invariant rule available is
/// type size as a fraction of the tile: the same fraction subtends the same
/// part of the tile on every surface, which is the property that has to
/// survive.
///
/// That is worth saying because the two comparable things in this app both do
/// it differently and both are right for what they are:
///
/// - the `/cameras` page sets its tag at a FIXED `font-size: 13px`. A page may
///   do that — CSS pixels are display units, so the page already knows how big
///   the tile will be. A picture never does.
/// - `DailiesStripMetrics` burns its strips at `height * 0.05 * 0.58` — about
///   1/34 of the frame — and that is right for a daily, which is watched FULL
///   FRAME at reading distance. Applied to a tile it comes out at 15.7 px on a
///   1080p four-up, which is under the size H.264 preserves at monitoring
///   bitrates and about 8 arcminutes at the phone end. A quarter of a picture
///   is not a picture, and the fraction has to grow when the frame is divided.
///
/// **The rule chosen is `pointSize = tile height / 16`**, and it is picked so
/// that the SMALLER of the two surfaces clears comfortable reading rather than
/// threshold:
///
/// | surface | tile | point size | cap height | subtends |
/// | --- | --- | --- | --- | --- |
/// | phone, 640 across a tile | 640x360 | 22.5 px | ~16 px = 1.9 mm @3x | 18.6' at 35 cm |
/// | monitor, 1920 across four | 960x540 | 33.8 px | ~24 px = 6.6 mm | 11.4' at 2 m |
///
/// Both are above the ~10 arcminutes where a glance becomes a squint, and the
/// monitor end has margin left for a director sitting further back. It is also
/// the end that fixes the floor from the other direction: 24 pixels of cap
/// height in the composed raster is well clear of the ~8-10 px where H.264 at a
/// monitoring bitrate turns small text into a grey smudge — which the dailies
/// fraction is not, and which no amount of legibility on the operator's own
/// screen would have revealed.
///
/// **There is deliberately no minimum size**, unlike `DailiesStripMetrics`'
/// `max(14, ...)`. A floor makes the label grow RELATIVE to the tile exactly
/// when the tile is smallest — covering the picture the tile exists to show —
/// and the canvas here follows the main camera's raster, which is never small
/// on a real signal. Keeping it one multiplication is also what lets a test
/// state the rule exactly rather than approximately.
struct TileTypeMetrics: Equatable {
    /// The fraction of the tile's height one line of type occupies. See above
    /// for the two surfaces this number is answerable to.
    static let pointSizeFraction: CGFloat = 1.0 / 16.0

    /// Type size, and the plate and margins derived from it so that changing
    /// the one number moves the whole nameplate together.
    let pointSize: CGFloat
    /// The dark plate behind the text: tall enough to sit the line in without
    /// the descenders touching the edge.
    let plateHeight: CGFloat
    /// Inset from the cell's edges, and the text's inset inside its plate.
    let margin: CGFloat
    let textInset: CGFloat
    /// The REC lamp's diameter. A dot rather than a word — see
    /// `TileBadge.rasterized`.
    let lampDiameter: CGFloat

    init(tileHeight: CGFloat) {
        let size = max(0, tileHeight) * Self.pointSizeFraction
        pointSize = size
        plateHeight = (size * 1.5).rounded()
        margin = (size * 0.5).rounded()
        textInset = (size * 0.45).rounded()
        lampDiameter = (size * 0.55).rounded()
    }

    /// The widest a badge may be drawn inside `cell` — the cell less a margin
    /// at each end, so a long take name is truncated rather than run into the
    /// tile beside it.
    func maximumWidth(in cell: CGRect) -> CGFloat {
        max(0, cell.width - 2 * margin)
    }

    /// Where the nameplate sits: the cell's TOP LEFT, inset by a margin.
    ///
    /// The same corner `MulticamGrid` and `SyncPlayView` put their label
    /// overlay in, and for the reason that makes it worth matching: an operator
    /// glancing between their own screen and the director's monitor should be
    /// reading one layout, not two. CoreImage's origin is bottom left, so the
    /// top of the cell is `maxY` and the plate hangs below it.
    func nameplateOrigin(in cell: CGRect, height: CGFloat) -> CGPoint {
        CGPoint(x: cell.minX + margin, y: cell.maxY - margin - height)
    }

    /// Where the clock sits: the cell's BOTTOM LEFT, inset by a margin — again
    /// the corner both SwiftUI grids already use for it.
    func clockOrigin(in cell: CGRect) -> CGPoint {
        CGPoint(x: cell.minX + margin, y: cell.minY + margin)
    }
}
