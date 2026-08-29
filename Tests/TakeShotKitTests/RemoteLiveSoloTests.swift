import CaptureCore
import CoreGraphics
import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// **Tapping one tile of the composed grid to fill the screen with it.**
///
/// Its own suite rather than more of `RemoteLivePageTests`, which is at the
/// type-length ceiling — and it is a different question anyway: that one is
/// about the page's half of the picture CHOICE, this is about the arithmetic
/// that turns one raster into one camera.
///
/// **What every test here does, and why it is done that way.** The rules are
/// pure functions in the shipped page, and each test cuts THAT text out of the
/// page as served and evaluates it in a JS engine — the idiom
/// `aFullscreenCameraTileCanAlwaysBeLeft` established for the `/cameras` page.
/// A Swift re-implementation of the same arithmetic would be a second opinion
/// that could be right while the page is wrong, which is the whole failure this
/// feature can have.
///
/// **What none of it can see:**
///
/// - **the CSS.** Nothing here runs a layout engine. The containing step —
///   `width`/`height` auto under a max of `cols` and `rows` stages, which for a
///   replaced element preserves the intrinsic ratio — is replicated as
///   arithmetic in `theSoloShiftCentresTheChosenCellAndFillsTheStage`, so a
///   browser that sized the element differently would pass. What is held is the
///   half this app owns: given that box, the fractions centre the right cell.
/// - **the tap.** `getBoundingClientRect`, `videoWidth` and the event's
///   coordinates are the browser's; the rule they feed is checked, the reading
///   of them is not.
/// - **whether it looks right on a phone.** That a 960x540 cell blown up to a
///   handset is worth looking at is a judgement somebody has to make with a
///   handset — see the note at `MultiviewEncoder.maximumEdge` for the pixel
///   count it is being compared against.
@MainActor
struct RemoteLiveSoloTests {
    /// The three numbers a layout is, so the helpers below stay inside
    /// SwiftLint's parameter count without collapsing into a tuple nobody can
    /// read at the call site.
    private struct Layout {
        var columns: Int
        var rows: Int
        var count: Int

        /// The app's own answer for `count` cameras, never this file's.
        init(cameras: Int) {
            columns = MultiviewComposer.columns(cameras: cameras)
            rows = MultiviewComposer.rows(cameras: cameras)
            count = cameras
        }
    }

    private func utf8(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    /// One of the page's pure rules, cut out of the page AS SERVED.
    private func rule(_ name: String, in html: String) throws -> String {
        let start: Range<String.Index> = try #require(
            html.range(of: "function \(name)("),
            "the live page states no \(name) rule to check")
        let end: Range<String.Index> = try #require(
            html.range(of: "\n}", range: start.upperBound..<html.endIndex),
            "the \(name) rule does not end where this test can cut it")
        return String(html[start.lowerBound..<end.upperBound])
    }

    /// One CSS rule's body, cut out of the page as served.
    ///
    /// The point is what it EXCLUDES: a comment sitting above the rule, saying
    /// in English what the rule does. Asserting a declaration against the whole
    /// page passes on the sentence that describes it, which is how the first
    /// version of `theSoloIsWiredIntoTheMarkupItNeeds` stayed green against a
    /// deleted `overflow: hidden`.
    private func block(_ selector: String, in html: String) throws -> String {
        let start: Range<String.Index> = try #require(
            html.range(of: selector), "the page states no \(selector) rule")
        let end: Range<String.Index> = try #require(
            html.range(of: "}", range: start.upperBound..<html.endIndex),
            "the \(selector) rule does not end where this test can cut it")
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// A JS engine holding the three rules the solo is made of.
    private func soloContext() throws -> JSContext {
        let html: String = try utf8(RemotePage.liveHTML())
        let context: JSContext = try #require(JSContext())
        for name in ["wantsSolo", "cellAt", "soloShift"] {
            context.evaluateScript(try rule(name, in: html))
            let raised: String = context.exception?.toString() ?? ""
            #expect(context.exception == nil,
                    "\(name) does not evaluate on its own: \(raised)")
        }
        return context
    }

    // MARK: - which tile is which

    /// **The page and the composed picture agree about which tile is which.**
    ///
    /// This is the assertion the whole feature rests on. The grid is ONE raster
    /// with the cameras tiled inside it, so a page that filled the stage with
    /// the wrong quadrant would be showing a director camera B and telling them
    /// it is camera A — which is worse than the anonymous rectangles all of
    /// this replaced.
    ///
    /// It is checked by asking the two ends about the same point. For every
    /// camera count and every camera in it, `MultiviewComposer.cell` is asked
    /// where it PUT that tile, the middle of that rectangle is converted from
    /// CoreImage's bottom-left origin to the page's top-left one, and the
    /// page's own `cellAt` is asked which camera is there. Nothing in the test
    /// spells out a layout — both sides are asked, and the composer is the one
    /// that decides.
    ///
    /// The stage is given the raster's own size so the mapping is 1:1 and the
    /// letterbox drops out; that the letterbox itself is handled is the next
    /// test.
    @Test func theSoloRuleAgreesWithTheComposersOwnCells() throws {
        let context = try soloContext()
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for count: Int in 1...6 {
            let layout = Layout(cameras: count)
            try assertTheStatusCarriesTheComposersLayout(layout)
            for camera: Int in 0..<count {
                let cell = MultiviewComposer.cell(camera: camera,
                                                  cameras: count, in: canvas)
                let asked = Self.cellAt(
                    context,
                    at: CGPoint(x: cell.midX, y: canvas.height - cell.midY),
                    stage: canvas.size, video: canvas.size, layout: layout)
                #expect(asked == camera,
                        """
                        \(count) cameras: the composer put camera \(camera) at \
                        \(cell) and the page reads that point as \(asked)
                        """)
            }
        }
    }

    /// …and the layout the page is TOLD is that same rule's answer, rather than
    /// a second copy of it living on the wire.
    private func assertTheStatusCarriesTheComposersLayout(
        _ layout: Layout) throws {
        var status = RemoteStatus()
        status.cameras = (0..<layout.count).map {
            RemoteStatus.CameraState(name: "C\($0)", recording: false)
        }
        #expect(status.gridColumns == layout.columns,
                """
                \(layout.count) cameras: the status offered \
                \(status.gridColumns) columns, the composer lays out \
                \(layout.columns)
                """)
        #expect(status.gridRows == layout.rows,
                """
                \(layout.count) cameras: the status offered \
                \(status.gridRows) rows, the composer lays out \(layout.rows)
                """)
    }

    /// **A tap that is not on a camera is not a solo of one.**
    ///
    /// Two ways that happens and both are ordinary. A three-camera board lays
    /// out on a 2x2 with a hole in it, and the hole is not camera 3 — there is
    /// no camera 3. And the picture is contained in the stage, so a phone in
    /// portrait watching a 16:9 grid has bars above and below it that belong to
    /// no tile at all.
    ///
    /// Without the count the first case solos a board that is not in the
    /// session; without the bar arithmetic the second one solos the top row,
    /// because a negative fraction floors to zero.
    @Test func aTapOffTheTilesSolosNothing() throws {
        let context = try soloContext()
        let raster = CGSize(width: 1920, height: 1080)
        // three cameras: 2 across, 2 down, and the bottom-right cell is empty
        let three = Layout(cameras: 3)
        #expect(three.columns == 2)
        #expect(three.rows == 2)
        let hole = Self.cellAt(context, at: CGPoint(x: 1440, y: 810),
                               stage: raster, video: raster, layout: three)
        #expect(hole == -1, "the empty cell of a three-up solod camera \(hole)")

        // a 16:9 picture on a portrait phone: bars top and bottom
        let four = Layout(cameras: 4)
        let stage = CGSize(width: 390, height: 700)
        let bar = Self.cellAt(context, at: CGPoint(x: 195, y: 10),
                              stage: stage, video: raster, layout: four)
        #expect(bar == -1, "a tap on the letterbox solod camera \(bar)")

        // …and inside the picture the tiles are found where they are. On this
        // phone the 16:9 grid is 390 x 219.4 centred in 700 of height, so the
        // top-left tile's own middle is a quarter across and a quarter down
        // that rectangle rather than a quarter down the STAGE — which is the
        // arithmetic the bars above would otherwise be passing for free.
        let barHeight = (stage.height - stage.width * raster.height
                         / raster.width) / 2
        let inside = Self.cellAt(
            context,
            at: CGPoint(x: stage.width / 4,
                        y: barHeight + (stage.height - 2 * barHeight) / 4),
            stage: stage, video: raster, layout: four)
        #expect(inside == 0,
                "the top-left of the picture read as camera \(inside)")
    }

    // MARK: - where the picture ends up

    /// **The chosen tile ends up centred on the stage and as large as it fits.**
    ///
    /// `soloShift` returns two fractions of the picture's own size, which is
    /// what a CSS percentage translate is measured in, and the browser does the
    /// rest — see the note at the top of this file for the half of that no test
    /// here runs.
    ///
    /// What it does hold is the half that is this app's own: given the box the
    /// CSS asks for, the fractions put the right cell dead centre and leave it
    /// as big as the stage can hold, at every stage shape and every layout. A
    /// planted off-by-one in the numerator fails every row of it.
    @Test func theSoloShiftCentresTheChosenCellAndFillsTheStage() throws {
        let context = try soloContext()
        for stage in [CGSize(width: 390, height: 700),
                      CGSize(width: 844, height: 390),
                      CGSize(width: 1920, height: 1080)] {
            for count: Int in [1, 2, 3, 4] {
                let layout = Layout(cameras: count)
                for camera: Int in 0..<count {
                    check(context, camera: camera, layout: layout, stage: stage)
                }
            }
        }
    }

    /// One camera's cell, followed through the CSS by hand.
    private func check(_ context: JSContext, camera: Int, layout: Layout,
                       stage: CGSize) {
        let raster = CGSize(width: 1920, height: 1080)
        let cols = Double(layout.columns)
        let rows = Double(layout.rows)
        let col = Double(camera % layout.columns)
        let row = Double(camera / layout.columns)
        let shift = Self.soloShift(context, cols: cols, rows: rows,
                                   col: col, row: row)
        // what `max-width`/`max-height` do to an auto-sized replaced element:
        // contain, intrinsic ratio preserved
        let scale = min(stage.width * cols / raster.width,
                        stage.height * rows / raster.height)
        let picture = CGSize(width: raster.width * scale,
                             height: raster.height * scale)
        // the element's top-left corner sits at the stage's centre before the
        // translate, which is what makes these fractions the whole rule
        let left = stage.width / 2 + shift.x * picture.width
        let top = stage.height / 2 + shift.y * picture.height
        let cell = CGSize(width: picture.width / cols,
                          height: picture.height / rows)
        let midX = left + (col + 0.5) * cell.width
        let midY = top + (row + 0.5) * cell.height
        let note = "\(layout.count) up, camera \(camera), stage \(stage)"
        #expect(abs(midX - stage.width / 2) < 0.001,
                "\(note): the cell sits at \(midX) across")
        #expect(abs(midY - stage.height / 2) < 0.001,
                "\(note): the cell sits at \(midY) down")
        #expect(cell.width <= stage.width + 0.001
                    && cell.height <= stage.height + 0.001,
                "\(note): the cell overflows the stage at \(cell)")
        #expect(abs(cell.width - stage.width) < 0.001
                    || abs(cell.height - stage.height) < 0.001,
                "\(note): the cell fills neither axis at \(cell)")
    }

    // MARK: - the gesture

    /// **The way out is never refused**, which is the whole of what the
    /// `/cameras` page had to learn the hard way and is inherited here rather
    /// than rediscovered.
    ///
    /// A board leaving the multicam set takes the count down under a tile that
    /// is already filling the stage. A rule that answered "no" in both
    /// directions on `count < 2` would leave a director looking at a quarter of
    /// a picture with nothing to tap. Entering also needs the GRID: the other
    /// two pictures are one camera, so there is no tile to choose and blowing
    /// one up would only crop the frame.
    @Test func aTileFillingTheStageCanAlwaysBeLeft() throws {
        let context = try soloContext()
        let asks: (Bool, Int, Bool) -> Bool = { wasSolo, count, isGrid in
            context.evaluateScript(
                "wantsSolo(\(wasSolo), \(count), \(isGrid))")?
                .toBool() ?? true
        }
        // the way out, at every count and on every picture
        for count: Int in [1, 2, 4] {
            for isGrid in [true, false] {
                #expect(!asks(true, count, isGrid),
                        "a filled tile cannot be left at \(count)/\(isGrid)")
            }
        }
        // the way in, only where it means something
        #expect(!asks(false, 1, true), "one tile is already the whole stage")
        #expect(!asks(false, 4, false),
                "a single-camera picture has tiles to choose between")
        #expect(asks(false, 2, true))
        #expect(asks(false, 4, true))
    }

    /// The markup the rules above are useless without — a rename or a dropped
    /// line on either side of these fails only on a phone otherwise.
    @Test func theSoloIsWiredIntoTheMarkupItNeeds() throws {
        let html = try utf8(RemotePage.liveHTML())
        // The stage CLIPS. Without this the neighbouring tiles are simply laid
        // out around the magnified one instead of being cut off, which is the
        // difference between a solo and a zoom that shows three other cameras.
        // Read out of the RULE and not out of the page — see `block`.
        let stage = try block("#stage {", in: html)
        #expect(stage.contains("overflow: hidden"),
                "the stage no longer clips the tiles around the chosen one")
        // The four numbers the rules produce reach the CSS, and the CSS is the
        // contain-then-shift they are fractions of.
        for property in ["--solo-cols", "--solo-rows", "--solo-x", "--solo-y"] {
            #expect(html.contains("var(\(property)"),
                    "\(property) is computed and never read")
            #expect(html.contains("setProperty(\"\(property)\""),
                    "\(property) is read and never computed")
        }
        #expect(html.contains("max-width: calc(100% * var(--solo-cols"),
                "the picture is no longer contained in a box of whole stages")
        // The tap asks the rule rather than carrying a second copy of it.
        #expect(html.contains("if (!wantsSolo(was, cameras, "),
                "the tap handler does not ask the rule")
        // The layout comes off the status, not out of the page.
        #expect(html.contains("next.gridCols"),
                "the page works the grid's shape out for itself")
        // A picture with no tiles, or a set that shrank, drops the solo rather
        // than cropping what replaced it.
        #expect(html.contains(
            "if (solo >= 0 && (cameras < 2 || solo >= cameras))"),
                "a shrinking set leaves a tile filling the stage")
        // The wire word for the grid is the app's, not this page's spelling.
        #expect(html.contains(
            "gridPicture:" + RemoteJSON.quoted(LivePicture.grid.rawValue)),
                "the page is not told which picture the grid is")
        #expect(!html.contains("=== \"grid\""),
                "the page spells the grid's wire name itself")
    }

    // MARK: - driving the rules

    private static func cellAt(_ context: JSContext, at point: CGPoint,
                               stage: CGSize, video: CGSize,
                               layout: Layout) -> Int {
        let call = "cellAt(\(point.x), \(point.y), \(stage.width), "
            + "\(stage.height), \(video.width), \(video.height), "
            + "\(layout.columns), \(layout.rows), \(layout.count))"
        return Int(context.evaluateScript(call)?.toInt32() ?? -2)
    }

    private static func soloShift(_ context: JSContext, cols: Double,
                                  rows: Double, col: Double,
                                  row: Double) -> (x: Double, y: Double) {
        let call = "soloShift(\(cols), \(rows), \(col), \(row))"
        return (context.evaluateScript(call + ".x")?.toDouble() ?? .nan,
                context.evaluateScript(call + ".y")?.toDouble() ?? .nan)
    }
}
