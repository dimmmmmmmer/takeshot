import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import CaptureCore

/// The metric: what the taught box says about a frame, and — the part the whole
/// feature stands on — what it says about a frame it was NOT taught.
///
/// False starts are the entire risk here. This project already paid for one rule
/// of exactly this shape (running timecode alone must never start a take), so
/// the cases below are not "does the dot work" — that is one test — but "does a
/// red practical, a red costume, a menu overlay or a half-lit indicator produce
/// evidence". None of them may.
struct VisualRecTriggerTests {
    // MARK: - the thing it is for

    /// The dot appears and vanishes, and the box says so.
    @Test func aDotAppearingReadsRollingAndVanishingReadsIdle() throws {
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        let idle = VisualRecProbe.frame()
        let teaching = VisualRecProbe.taught(rolling: rolling, idle: idle)
        #expect(teaching.isTaught, "the fixture taught nothing")

        #expect(VisualRecProbe.reading(teaching, of: rolling) == .rolling)
        #expect(VisualRecProbe.reading(teaching, of: idle) == .idle)
        // and the two references land where the axis says they should
        let atRolling = try #require(VisualRecProbe.position(teaching, of: rolling))
        let atIdle = try #require(VisualRecProbe.position(teaching, of: idle))
        #expect(abs(atRolling.along - 1) < 0.01, "rolling sits at \(atRolling)")
        #expect(abs(atIdle.along) < 0.01, "idle sits at \(atIdle)")
    }

    /// The separation the panel shows is a real code figure, not an abstraction:
    /// a 24 px dot 160 codes off its background inside the default box has to
    /// come out well clear of the floor that refuses to arm.
    @Test func theSeparationIsStatedInCodeValues() throws {
        let teaching = VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame())
        let separation = try #require(teaching.separation)
        #expect(separation > VisualRecTeaching.minSeparation,
                "a real dot separated by only \(separation) codes")
        #expect(separation < 255, "separation is on the code scale: \(separation)")
    }

    // MARK: - the false starts

    /// A red practical coming on somewhere else in frame. The same red as the
    /// indicator, sixteen times the area, and it must be invisible to the
    /// trigger — because the box is small and taught, and nothing outside it is
    /// read at all.
    @Test func aRedObjectOutsideTheRegionTriggersNothing() {
        let teaching = VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame())

        let redPractical = VisualRecProbe.frame([VisualRecProbe.practical])
        #expect(VisualRecProbe.reading(teaching, of: redPractical) == .idle,
                "a red practical outside the box read as a roll")
        // …and the picture is genuinely different, so this proves something
        #expect(VisualRecProbe.reading(teaching, of: VisualRecProbe.frame())
                == .idle)
    }

    /// The camera's own menu overlay dropped over the box. This one DOES change
    /// the watched pixels, so the region cannot save it — the residual gate does:
    /// the change is not along the axis the operator taught, so the frame is no
    /// evidence at all rather than evidence of a roll.
    @Test func anUntaughtChangeOverTheBoxIsNoEvidence() throws {
        let teaching = VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame())

        let overlaid = VisualRecProbe.frame([VisualRecProbe.menuOverlay])
        let position = try #require(VisualRecProbe.position(teaching, of: overlaid))
        #expect(position.residual > VisualRecTeaching.maxResidual,
                "the overlay landed on the taught axis: \(position)")
        #expect(VisualRecProbe.reading(teaching, of: overlaid) == nil,
                "a menu overlay produced a reading")
    }

    /// Half-lit: a dimmer dot than the one that was taught, i.e. a frame that is
    /// genuinely between the two references. The required margin makes it no
    /// evidence rather than a coin toss.
    @Test func theMarginRefusesAHalfLitIndicator() throws {
        let dot = VisualRecProbe.dot
        let rolling = VisualRecProbe.frame([dot])
        let idle = VisualRecProbe.frame()
        let teaching = VisualRecProbe.taught(rolling: rolling, idle: idle)

        // the same dot at the midpoint between background and full brightness
        let half = VisualRecProbe.Block(
            x: dot.x, y: dot.y, width: dot.width, height: dot.height,
            color: VisualRecProbe.Ink(r: 140, g: 46, b: 47))
        let halfLit = VisualRecProbe.frame([half])
        let position = try #require(VisualRecProbe.position(teaching, of: halfLit))
        #expect(abs(position.along - 0.5) < 0.2,
                "the fixture is not actually half-lit: \(position)")
        #expect(VisualRecProbe.reading(teaching, of: halfLit) == nil,
                "a half-lit indicator produced a reading: \(position)")

        // …and with the margin wound off it becomes a decision again, which is
        // what the margin is for and what it costs
        var loose = teaching
        loose.margin = 0
        #expect(VisualRecProbe.reading(loose, of: halfLit) != nil)
    }

    /// Two references that do not separate — the operator captured the same
    /// picture twice, or the box misses the indicator. The trigger refuses to
    /// arm at all rather than arming on noise.
    @Test func referencesThatDoNotSeparateRefuseToArm() {
        let idle = VisualRecProbe.frame()
        let teaching = VisualRecProbe.taught(rolling: idle, idle: idle)
        #expect(!teaching.isTaught, "an unchanged pair claimed to be taught")
        #expect(!teaching.isArmed, "it armed anyway")
        #expect(VisualRecProbe.reading(teaching, of: idle) == nil)
        let separation = teaching.separation ?? 0
        #expect(separation < VisualRecTeaching.minSeparation,
                "two identical captures separated by \(separation) codes")
    }

    /// A trigger nobody switched on says nothing, however well it was taught.
    /// Opt-in is a property of the value, not of a caller remembering to ask.
    @Test func anUntaughtOrUnarmedTriggerNeverReads() {
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        let off = VisualRecProbe.taught(rolling: rolling,
                                        idle: VisualRecProbe.frame(), on: false)
        #expect(!off.isArmed)
        #expect(VisualRecProbe.reading(off, of: rolling) == nil)

        // half taught: one reference and nothing to compare it against
        var half = VisualRecTeaching()
        half.region = VisualRecProbe.region()
        half.rolling = VisualRecSampler.signature(of: rolling,
                                                  region: half.region)
        half.isOn = true
        #expect(!half.isArmed)
        #expect(VisualRecProbe.reading(half, of: rolling) == nil)
        #expect(half.separation == nil)
    }

    // MARK: - the region is in signal coordinates

    /// The same picture at two rasters classifies the same way. That is what
    /// "signal coordinates" buys: a reference captured at 1080p keeps working
    /// when the camera switches to UHD, because the box is a fraction of the
    /// frame and the signature is a fixed-length grid over it.
    @Test func theSameSignalAtTwoRastersReadsTheSame() throws {
        let hd = VisualRecProbe.frame([VisualRecProbe.dot])
        let hdIdle = VisualRecProbe.frame()
        let teaching = VisualRecProbe.taught(rolling: hd, idle: hdIdle)

        let uhd = VisualRecProbe.frame([VisualRecProbe.dot],
                                       width: 1280, height: 720)
        let uhdIdle = VisualRecProbe.frame(width: 1280, height: 720)
        #expect(VisualRecProbe.reading(teaching, of: uhd) == .rolling,
                "a reference taught at 640x360 stopped working at 1280x720")
        #expect(VisualRecProbe.reading(teaching, of: uhdIdle) == .idle)
        // …and quantitatively: the projection lands on the reference, not near it
        let position = try #require(VisualRecProbe.position(teaching, of: uhd))
        #expect(abs(position.along - 1) < 0.15, "\(position)")
    }

    /// The box's pixel rect is a pure function of the fractions and the raster,
    /// and it is clamped inside the frame at every centre a click can produce —
    /// including the corners, where an unclamped box would read past the end of
    /// a row.
    @Test func theBoxIsClampedInsideTheFrame() throws {
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.0), (0.0, 0.5)] {
            let region = VisualRecRegion(centerX: x, centerY: y, width: 0.25)
            let box = try #require(region.pixels(width: 1920, height: 1080))
            #expect(box.x >= 0 && box.y >= 0, "\(x),\(y) → \(box)")
            #expect(box.x + box.width <= 1920, "\(x),\(y) → \(box)")
            #expect(box.y + box.height <= 1080, "\(x),\(y) → \(box)")
        }
        // a degenerate raster has nothing to watch
        #expect(VisualRecProbe.region().pixels(width: 0, height: 0) == nil)
    }

    /// The size is clamped to a SMALL box, and the ceiling is the load-bearing
    /// half: a region larger than a quarter of the frame each way stops being
    /// the indicator and starts being the picture.
    @Test func theBoxSizeIsClampedSmall() {
        // Both axes, independently — the box stopped being square when a REC
        // indicator turned out to be a dot beside a word.
        var region = VisualRecRegion(centerX: 0.5, centerY: 0.5,
                                     width: 4, height: 4)
        region.clamp()
        #expect(region.width == VisualRecRegion.maxSize)
        #expect(region.height == VisualRecRegion.maxSize)
        region.width = -1
        region.height = -1
        region.clamp()
        #expect(region.width == VisualRecRegion.minSize)
        #expect(region.height == VisualRecRegion.minSize)
        // …and one axis at the ceiling does not drag the other with it, which
        // is the whole point of there being two.
        var wide = VisualRecRegion(centerX: 0.5, centerY: 0.5,
                                   width: 0.25, height: 0.04)
        wide.clamp()
        #expect(wide.width == 0.25)
        #expect(wide.height == 0.04)
        #expect(VisualRecRegion.maxSize <= 0.25,
                "the box may not be allowed to cover the frame")
    }

    /// Punch-in, pan and desqueeze all move the picture inside the window and
    /// none of them move the signal. The click that places the box goes through
    /// `ViewAssist.imageFraction`, so this is the property that keeps a taught
    /// box under the indicator: a signal fraction maps to a viewport point and
    /// back to itself, whatever the viewer is doing.
    ///
    /// Round-tripped rather than compared against a hand-computed point, because
    /// what has to hold is that the two directions agree — the renderer places
    /// the picture with `placement` and the click is inverted with
    /// `imageFraction`, and one formula is why they cannot drift.
    @Test func aTaughtBoxSurvivesAPunchInAndADesqueeze() throws {
        let viewport = CGSize(width: 1200, height: 700)
        let region = VisualRecProbe.region()
        let target = CGPoint(x: region.centerX, y: region.centerY)

        for (punchIn, panX, panY, desqueeze) in [
            (1.0, 0.0, 0.0, 1.0),
            (4.0, 0.1, -0.05, 1.0),
            (1.0, 0.0, 0.0, 2.0),
            (2.5, -0.15, 0.2, 1.33),
        ] {
            var assist = ViewAssist()
            assist.desqueeze = desqueeze
            assist.setPunchIn(punchIn)
            assist.panX = panX
            assist.panY = panY
            assist.clampPan()
            // the source size the app hands the placement math: an aspect-shaped
            // box that already carries the desqueeze (see displaySourceSize)
            let source = CGSize(width: 16.0 / 9.0 * desqueeze, height: 1)
            let placed = try #require(assist.placement(sourceSize: source,
                                                       in: viewport))
            let onScreen = CGPoint(
                x: placed.rect.minX + target.x * placed.rect.width,
                y: placed.rect.minY + target.y * placed.rect.height)
            let back = try #require(
                assist.imageFraction(of: onScreen, sourceSize: source,
                                     in: viewport),
                "punchIn \(punchIn) desqueeze \(desqueeze): off the picture")
            #expect(abs(back.x - target.x) < 0.001,
                    "punchIn \(punchIn) desqueeze \(desqueeze): x \(back.x)")
            #expect(abs(back.y - target.y) < 0.001,
                    "punchIn \(punchIn) desqueeze \(desqueeze): y \(back.y)")
        }
    }

    // MARK: - what survives a relaunch

    /// A reference goes into the settings blob as 192 bytes of base64 and comes
    /// back classifying the same frames. Rounding to a code is deliberate — the
    /// samples came from an 8-bit buffer — so the round trip has to be exact
    /// enough that the reading does not change.
    @Test func aReferenceSurvivesTheSettingsBlob() throws {
        let rolling = VisualRecProbe.frame([VisualRecProbe.dot])
        let idle = VisualRecProbe.frame()
        let teaching = VisualRecProbe.taught(rolling: rolling, idle: idle)

        let rollingBlob = try #require(teaching.rolling).encoded
        let idleBlob = try #require(teaching.idle).encoded
        // Unwrapped into locals of the NON-optional type first. Assigning
        // `#require`'s result straight into `restored.rolling` gives the macro an
        // optional contextual type, it widens the initializer's own optional to
        // match, and it then warns that a check which very much can fail cannot.
        let rollingRef: VisualRecSignature =
            try #require(VisualRecSignature(encoded: rollingBlob))
        let idleRef: VisualRecSignature =
            try #require(VisualRecSignature(encoded: idleBlob))
        var restored = VisualRecTeaching()
        restored.region = teaching.region
        restored.rolling = rollingRef
        restored.idle = idleRef
        restored.isOn = true

        #expect(VisualRecProbe.reading(restored, of: rolling) == .rolling)
        #expect(VisualRecProbe.reading(restored, of: idle) == .idle)
        let before = try #require(teaching.separation)
        let after = try #require(restored.separation)
        #expect(abs(before - after) < 1, "\(before) became \(after)")
    }

    /// A truncated or hand-edited blob leaves the trigger untaught rather than
    /// armed on garbage — which for this feature is the difference between doing
    /// nothing and rolling a take nobody asked for.
    @Test func aMalformedStoredReferenceIsRefused() {
        #expect(VisualRecSignature(encoded: "") == nil)
        #expect(VisualRecSignature(encoded: "not base64 at all!!") == nil)
        #expect(VisualRecSignature(encoded: Data([1, 2, 3]).base64EncodedString())
                == nil)
        #expect(VisualRecSignature(codes: [1, 2, 3]) == nil)
        #expect(VisualRecSignature(codes: Array(repeating: 0,
                                               count: VisualRecSignature.componentCount))
                != nil)
    }

    /// Forgetting the references also switches the trigger off: an armed trigger
    /// with nothing taught would be a lie the panel could not show.
    @Test func forgettingTheReferencesDisarms() {
        var teaching = VisualRecProbe.taught(
            rolling: VisualRecProbe.frame([VisualRecProbe.dot]),
            idle: VisualRecProbe.frame())
        #expect(teaching.isArmed)
        teaching.forgetReferences()
        #expect(!teaching.isOn)
        #expect(!teaching.isTaught)
        #expect(teaching.region == VisualRecProbe.region(),
                "the box was thrown away with the references")
    }

    // MARK: - the sampler

    /// The sampler is for the DISPLAY half and says so: handed a wire frame it
    /// answers nil rather than guessing at a packing. A reference is only ever
    /// captured from the 8-bit display buffer, so a wire frame reaching it at all
    /// would mean the pipeline handed over the wrong stage.
    @Test func theSamplerRefusesAnythingButTheDisplayBuffer() {
        var wire: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &wire)
        if let wire {
            #expect(VisualRecSampler.signature(of: wire,
                                               region: VisualRecProbe.region())
                    == nil)
        }
    }

    /// Constant cost: the tap count does not depend on the box's size or the
    /// signal's resolution, which is what makes the per-pass budget a single
    /// number rather than a table.
    @Test func theTapCountIsFixed() {
        #expect(VisualRecSampler.taps == VisualRecSignature.grid
                * VisualRecSampler.tapsPerCell)
        #expect(VisualRecSampler.taps * VisualRecSampler.taps == 1024)
        #expect(VisualRecSignature.componentCount == 192)
    }
}
