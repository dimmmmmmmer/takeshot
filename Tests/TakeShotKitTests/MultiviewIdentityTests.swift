import CaptureCore
@preconcurrency import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// **The tile says what it is, in the picture** — and what can honestly be
/// asserted about that on a machine none of us is looking at.
///
/// **What this suite deliberately does not read: glyphs.** This project already
/// paid for that lesson once, with a centring test that measured drawn text
/// bounds and came back nil on a headless runner, and the reason generalizes —
/// a font's advance widths, its cap height and even whether a face resolves at
/// all are properties of the OS the test runs on, not of this app. CI is two
/// macOS releases behind the development Mac, so any assertion of the shape
/// "the label is 137 pixels wide" or "there is ink at (12, 40)" is pinning the
/// runner's type stack.
///
/// So everything here is one of four portable kinds:
///
/// - **arithmetic** — the type-size rule and the cell geometry are pure
///   functions of the tile, and a fraction is a fraction on every machine;
/// - **direction and bound** — a nameplate with a lamp is WIDER than the same
///   nameplate without one, and a long name is clamped INSIDE its cell. Both
///   hold whatever the font measures, which is exactly why they are the two
///   drawn facts worth asserting;
/// - **counted work** — `TileBadge.rasterCount` turns the caching rule from a
///   comment into a number, and a number is the same on every machine;
/// - **the state the draw is made from** — what the composer holds per tile,
///   for the two rules that are otherwise only visible as glyphs.
///
/// **What none of that can see**, stated so the next person does not assume it
/// is covered:
///
/// - **whether the text is legible, or right.** Nothing here reads a single
///   glyph, so a label rendered in the wrong font, at the wrong weight, white
///   on white, upside down, or mirrored would pass every assertion in this
///   file. The type-size rule is checked as arithmetic and argued from
///   arcminutes at `TileTypeMetrics`; that it actually READS on a phone is a
///   judgement somebody has to make with a phone.
/// - **whether the badge is over the right tile.** The geometry tests check
///   that camera 0's nameplate lands inside camera 0's cell, but "inside the
///   cell" is checked against `MultiviewComposer.cell`, so a layout that put
///   every tile in the wrong cell would move the labels with them and stay
///   green. The existing `cameraZeroIsTheTopLeftCell` is what holds that end.
/// - **whether the identity is TRUE.** That `pushGridIdentities` reads
///   `channel.isRecording` and not `controller.isRecording` is checked by
///   composition below; that the lamp is lit at the moment the writer actually
///   opens a file is not — the wiring is asserted, the truth of what it carries
///   belongs to the pipeline's own suites.
/// - **the encode.** These badges exist to survive an H.264 pass at a
///   monitoring bitrate. Nothing here encodes anything.
/// One pixel of a badge bitmap.
///
/// A named type rather than a tuple of three, and it earns the name: `isLamp`
/// is the one question this suite asks of ink, and it belongs beside the values
/// it is asked of rather than being spelled out at each call site.
struct Ink: CustomStringConvertible {
    var r: Int
    var g: Int
    var b: Int

    /// **Red dominance**, which is what tells the REC lamp from everything else
    /// that can be at that point in the plate. White type has red equal to
    /// green, an antialiased edge of it has them equal too, and the plate has
    /// both at zero. Only the lamp is red with green well under it — so this is
    /// a question no font can answer by accident, which is what makes it
    /// portable where reading a glyph is not.
    var isLamp: Bool { r > 128 && r > g * 2 }

    var description: String { "(r: \(r), g: \(g), b: \(b))" }
}

@Suite struct MultiviewIdentityTests {
    private static let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - the two kinds

    /// **A take has no lamp to leave switched off.**
    ///
    /// The one thing this modelling must not do is flatten the two callers'
    /// tiles into one struct with a `recording` flag: that would say a take is
    /// a camera which happens not to be rolling, and the first person to read it
    /// would wire a lamp to it. `.take` carries no flag at all, and this pins
    /// the consequence — no label, however constructed, can make one glow.
    ///
    /// Note what the test cannot state and the TYPE does: that there is no
    /// spelling of `.take` that takes a recording argument. That is a
    /// compile-time property, and the compiler is the assertion.
    @Test func aTakeHasNoLampAndACameraHasItsOwn() {
        for label in ["", "A", "TS_A001C003_long name"] {
            #expect(TileIdentity.take(label: label).showsRecordingLamp == false,
                    "a take lit a REC lamp for \(label)")
            #expect(TileIdentity.take(label: label).label == label)
        }
        #expect(TileIdentity.camera(label: "A", recording: true)
                    .showsRecordingLamp)
        #expect(TileIdentity.camera(label: "A", recording: false)
                    .showsRecordingLamp == false)
    }

    // MARK: - the type size

    /// **The rule, exactly: one line of type is the tile's height over 16.**
    ///
    /// Stated as an equality rather than a range because the whole argument for
    /// the number depends on it being a pure fraction — that is what makes the
    /// same picture legible on a phone holding a tile at 640 across and on a
    /// monitor holding four across 1920, which are the two surfaces this
    /// picture is watched on and the two `TileTypeMetrics` is answerable to.
    ///
    /// The second half is the property, not the constant: DOUBLE the tile and
    /// the type doubles. A rule that stopped scaling — a clamp, a rounding to
    /// whole points, a floor copied from `DailiesStripMetrics` — would leave the
    /// constant right at 1080p and wrong everywhere else, and the surface it
    /// would be wrong on is the one nobody here has in front of them.
    @Test func theTypeSizeIsAFixedFractionOfTheTileAndScalesWithIt() {
        // the phone end: a tile 640 across is 360 high at 16:9
        #expect(TileTypeMetrics(tileHeight: 360).pointSize == 22.5)
        // the monitor end: 1920 across four tiles is a 540-high tile
        #expect(TileTypeMetrics(tileHeight: 540).pointSize == 33.75)
        // and UHD, where the same four-up is twice the tile
        #expect(TileTypeMetrics(tileHeight: 1080).pointSize == 67.5)

        for height: CGFloat in [90, 180, 360, 540, 1080, 2160] {
            #expect(TileTypeMetrics(tileHeight: height).pointSize
                        == height / 16,
                    "the fraction moved at a tile height of \(height)")
            // the property the fraction exists for
            #expect(TileTypeMetrics(tileHeight: height * 2).pointSize
                        == TileTypeMetrics(tileHeight: height).pointSize * 2,
                    "the type stopped scaling with the tile at \(height)")
        }
    }

    /// **No floor, deliberately** — the one place this differs from the dailies
    /// burn-in it otherwise follows.
    ///
    /// `DailiesStripMetrics` clamps at `max(14, …)` because a daily is a whole
    /// frame and a 14-pixel strip on a small one is still a strip. A floor here
    /// would make the label grow relative to the TILE exactly when the tile is
    /// smallest — covering the picture the tile exists to show — so a tiny cell
    /// gets tiny type and the badge simply declines to draw below one point.
    @Test func aTinyTileGetsTinyTypeRatherThanAFloor() {
        #expect(TileTypeMetrics(tileHeight: 32).pointSize == 2)
        #expect(TileTypeMetrics(tileHeight: 8).pointSize == 0.5)
        // …and below one point there is nothing worth rasterizing
        let metrics = TileTypeMetrics(tileHeight: 8)
        #expect(TileBadge.nameplate(for: .camera(label: "A", recording: true),
                                    metrics: metrics,
                                    maximumWidth: 100) == nil,
                "a half-point nameplate was rasterized anyway")
    }

    /// A badge is inset from its cell at BOTH ends, and sits in the two corners
    /// the operator's own grids already use.
    ///
    /// The width matters most: a take name is a file name and file names are
    /// long, so without room reserved at the right-hand end the plate would run
    /// into the tile beside it — which on a four-up is another take, and a label
    /// crossing that boundary is worse than no label at all.
    @Test func aBadgeIsInsetInsideItsOwnCell() {
        let cell = MultiviewComposer.cell(camera: 1, cameras: 4,
                                          in: Self.canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        #expect(metrics.maximumWidth(in: cell) == cell.width - 2 * metrics.margin)
        #expect(metrics.maximumWidth(in: cell) < cell.width)

        // top left in a bottom-left-origin space is maxY, and the plate hangs
        // below it — the corner `MulticamGrid` and `SyncPlayView` both use
        let nameplate = metrics.nameplateOrigin(in: cell,
                                                height: metrics.plateHeight)
        #expect(nameplate.x > cell.minX)
        #expect(nameplate.y + metrics.plateHeight < cell.maxY)
        #expect(nameplate.y > cell.minY)
        let clock = metrics.clockOrigin(in: cell)
        #expect(clock.x == nameplate.x, "the two badges are not on one edge")
        #expect(clock.y > cell.minY)
        #expect(clock.y + metrics.plateHeight < nameplate.y,
                "the clock and the nameplate overlap")

        // **Which HALF each one is in**, measured against the cell's own
        // midpoint. Everything above is the placement arithmetic checked
        // against itself, which a badge that MOVED would satisfy perfectly — a
        // planted move to the middle of the cell passed all of it. The cell's
        // midpoint is the one reference here that the placement does not
        // supply, so this is the assertion that a nameplate is at the top and a
        // clock at the bottom, which is what the SwiftUI grids do and what an
        // operator glancing between the two surfaces is relying on.
        #expect(nameplate.y > cell.midY,
                "the nameplate left the top half of the cell")
        #expect(clock.y + metrics.plateHeight < cell.midY,
                "the clock left the bottom half of the cell")
    }

    // MARK: - what is actually drawn

    /// **The lamp is drawn for a recording camera and for nothing else.**
    ///
    /// Two assertions, because the first one alone was not enough and a planted
    /// regression proved it. The WIDTH is a direction — the lamp reserves its
    /// diameter plus an inset in front of the text, so the same words come out
    /// wider with it than without, on any font on any machine — and an idle
    /// camera and a take are required to measure the SAME, which is what says a
    /// take never gets one.
    ///
    /// But width is only the space RESERVED. Deleting the draw and keeping the
    /// reservation passed that assertion cleanly, and would have shipped a REC
    /// state nobody can see. So the dot itself is read out of the bitmap — and
    /// it can be, without breaking this suite's rule about glyphs, because a
    /// filled ellipse of a constant colour is not type: it lands on the same
    /// codes on every machine, where a letter's ink does not.
    @Test func theLampWidensThePlateForARecordingCameraAlone() throws {
        TileBadge.resetForTesting()
        let metrics = TileTypeMetrics(tileHeight: 540)
        let room: CGFloat = 900
        func width(_ identity: TileIdentity) throws -> CGFloat {
            let image: CIImage = try #require(
                TileBadge.nameplate(for: identity, metrics: metrics,
                                    maximumWidth: room))
            #expect(image.extent.height == metrics.plateHeight,
                    "the plate height left the metrics")
            return image.extent.width
        }
        let rolling = try width(.camera(label: "A CAM", recording: true))
        let idle = try width(.camera(label: "A CAM", recording: false))
        let take = try width(.take(label: "A CAM"))
        #expect(rolling > idle,
                "the REC lamp took no room: \(rolling) against \(idle)")
        #expect(idle == take,
                "a take drew differently from an idle camera: \(take) vs \(idle)")

        // …and the dot is actually there. Sampled at the lamp's own centre,
        // which the metrics place: one inset in from the plate's edge, half a
        // diameter across, on the plate's midline.
        //
        // **Asserted as red DOMINANCE, not as brightness**, and the difference
        // is the whole portability of it. Without the lamp that same point is
        // not blank — a badge with no lamp starts its text at the very same
        // inset, so what is there is a glyph, or the antialiased edge of one,
        // or the plate, depending on the letter and the machine's font. All
        // three are neutral: white type has red equal to green, the plate has
        // both at zero. Only the lamp is red with green well under it. So the
        // test asks the one question no font can answer by accident.
        let centre = (x: Int(metrics.textInset + metrics.lampDiameter / 2),
                      y: Int(metrics.plateHeight / 2))
        let lit: CIImage = try #require(
            TileBadge.nameplate(for: .camera(label: "A CAM", recording: true),
                                metrics: metrics, maximumWidth: room))
        let unlit: CIImage = try #require(
            TileBadge.nameplate(for: .take(label: "A CAM"), metrics: metrics,
                                maximumWidth: room))
        let onLamp = Self.sample(lit, atX: centre.x, y: centre.y)
        let onTake = Self.sample(unlit, atX: centre.x, y: centre.y)
        #expect(onLamp.isLamp,
                "nothing red at the lamp's own centre: \(onLamp)")
        #expect(!onTake.isLamp, "a take lit a REC lamp: \(onTake)")
    }

    /// One pixel out of a badge bitmap, rendered exactly as the composer
    /// composites it — unmanaged, so the codes drawn are the codes read.
    private static func sample(_ image: CIImage, atX x: Int, y: Int) -> Ink {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width > 0, height > 0 else { return Ink(r: -1, g: -1, b: -1) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 4,
                           bounds: image.extent, format: .RGBA8,
                           colorSpace: nil)
        }
        // The bitmap is written top row first; the badge's own origin is bottom
        // left, but every offset here is symmetric about the plate's midline or
        // measured from the left, so only the row order matters.
        let offset = y * width * 4 + x * 4
        guard offset + 2 < bytes.count else { return Ink(r: -1, g: -1, b: -1) }
        return Ink(r: Int(bytes[offset]), g: Int(bytes[offset + 1]),
                   b: Int(bytes[offset + 2]))
    }

    /// A name too long for its cell is truncated INTO the cell rather than
    /// drawn across the tile beside it.
    ///
    /// A bound, not a width — what the truncation costs in characters is a
    /// font's business and changes with the machine; that it never exceeds the
    /// room it was given is this app's business and does not.
    @Test func aLongNameIsClampedIntoTheRoomItWasGiven() throws {
        TileBadge.resetForTesting()
        let cell = MultiviewComposer.cell(camera: 0, cameras: 4,
                                          in: Self.canvas)
        let metrics = TileTypeMetrics(tileHeight: cell.height)
        let room = metrics.maximumWidth(in: cell)
        let long = String(repeating: "TS_A001C003_240817_R1ZX ", count: 8)
        let image: CIImage = try #require(
            TileBadge.nameplate(for: .take(label: long), metrics: metrics,
                                maximumWidth: room))
        #expect(image.extent.width <= room,
                "the name ran to \(image.extent.width) in \(room) of room")
        // and it did not collapse to nothing on the way
        #expect(image.extent.width > metrics.pointSize)
    }

    /// An empty name draws no plate at all, rather than an empty black box
    /// sitting in the corner of a picture somebody is judging exposure on.
    @Test func anEmptyNameDrawsNothing() {
        let metrics = TileTypeMetrics(tileHeight: 540)
        #expect(TileBadge.nameplate(for: .camera(label: "", recording: true),
                                    metrics: metrics, maximumWidth: 900) == nil)
        #expect(TileBadge.clock(text: "", metrics: metrics,
                                maximumWidth: 900) == nil)
    }
}
