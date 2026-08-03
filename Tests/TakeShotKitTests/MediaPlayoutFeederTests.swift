import CaptureCore
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The frame path to the hardware monitor.
///
/// Never a real board: `PlayoutOutput` stands in for `CDLPlayout`, whose init
/// opens a DeckLink output — on a machine that has one, that puts this suite's
/// picture on somebody's monitor. What the fake makes assertable is everything
/// the feeder actually decides: whether a frame is handed over as it is or
/// rebuilt first, and what happens to a burst that arrives faster than a 25 Hz
/// output can take it.
@Suite struct MediaPlayoutFeederTests {
    /// A BGRA frame of a given size, filled flat so a scaled copy can be read
    /// back at a known value.
    private static func frame(level: UInt8, width: Int, height: Int)
        -> CVPixelBuffer {
        MediaFixtures.pixelBuffer(level: level, width: width, height: height)
    }

    /// A frame in a pixel format the hardware does not take. Same raster as the
    /// output, so it isolates the format half of the fast-path guard.
    private static func argbFrame(width: Int, height: Int) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let out else {
            fatalError("could not allocate a \(width)x\(height) ARGB frame")
        }
        return out
    }

    /// The output states its own geometry — the feeder never assumes the mode it
    /// asked for is the mode it got.
    @Test func theFeederReportsTheOutputsGeometry() {
        let output = FakePlayoutOutput(width: 1920, height: 1080)
        let feeder = PlayoutFeeder(output: output)
        #expect(feeder.outputSize == (1920, 1080))
    }

    /// A frame already in the output's raster and pixel format goes over
    /// untouched — the same object, not a copy. At UHD a copy on this path is
    /// 33 MB a frame through CoreImage for no change to a single pixel.
    @Test func aMatchingFrameIsHandedOverUntouched() {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        let submitted = Self.frame(level: 0x80, width: 320, height: 180)

        feeder.submit(submitted)
        feeder.settle()

        #expect(output.displayed.count == 1)
        #expect(output.displayed.first === submitted,
                "a frame that already matched the output was rebuilt")
    }

    /// A different raster is rebuilt into the output's. A UHD viewer on an HD
    /// output is the normal case, and handing the board a frame of the wrong size
    /// shows nothing.
    @Test func aDifferentRasterIsRebuiltIntoTheOutputs() throws {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        let submitted = Self.frame(level: 0xC0, width: 640, height: 360)

        feeder.submit(submitted)
        feeder.settle()

        #expect(output.displayed.count == 1)
        let shown = try #require(output.displayed.first)
        #expect(shown !== submitted)
        #expect(CVPixelBufferGetWidth(shown) == 320)
        #expect(CVPixelBufferGetHeight(shown) == 180)
        #expect(CVPixelBufferGetPixelFormatType(shown)
                    == kCVPixelFormatType_32BGRA)
    }

    /// The right raster in the wrong pixel format is rebuilt too. The board takes
    /// BGRA and nothing else, so the format is half of the guard — matching
    /// dimensions alone are not enough to pass a frame through.
    @Test func theWrongPixelFormatIsRebuiltEvenAtTheRightSize() throws {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        let submitted = Self.argbFrame(width: 320, height: 180)

        feeder.submit(submitted)
        feeder.settle()

        let shown = try #require(output.displayed.first)
        #expect(shown !== submitted)
        #expect(CVPixelBufferGetPixelFormatType(shown)
                    == kCVPixelFormatType_32BGRA)
    }

    /// A frame of a different SHAPE is fitted, not stretched: the picture keeps
    /// its aspect and the output gets black where the picture is not.
    ///
    /// Read as geometry, with room to spare: a square source into a 16:9 output
    /// leaves the centre column the source's own value and the edge columns
    /// black. That is CoreImage into an explicitly sized buffer — no backing
    /// scale and no AppKit control ink involved — so it says the same thing on a
    /// runner with no display.
    @Test func aDifferentShapeIsLetterboxedRatherThanStretched() throws {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        // 1:1 into 16:9 — fitted to 180x180, bars left and right
        feeder.submit(Self.frame(level: 200, width: 256, height: 256))
        feeder.settle()

        let shown = try #require(output.displayed.first)
        let middle = MediaFixtures.sample(shown, atFractionX: 0.5)
        let edge = MediaFixtures.sample(shown, atFractionX: 0.02)
        #expect(abs(middle.g - 200) <= 12,
                "the centre of the fitted picture read \(middle.description)")
        #expect(edge.g <= 8,
                "the letterbox bar read \(edge.description) instead of black")
    }

    /// A burst is coalesced latest-wins, not queued. Frames arrive from the
    /// pipeline's display queue faster than a 25 Hz output takes them, and a
    /// queue that grew instead would put the director's monitor further and
    /// further behind the room.
    ///
    /// Driven by holding the output rather than by a wall-clock window: the first
    /// frame is parked inside `display`, three more are submitted behind it, and
    /// the one that goes second has to be the NEWEST of the three.
    @Test func aBurstIsCoalescedLatestWins() {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        let first = Self.frame(level: 10, width: 320, height: 180)
        let superseded = Self.frame(level: 20, width: 320, height: 180)
        let alsoSuperseded = Self.frame(level: 30, width: 320, height: 180)
        let newest = Self.frame(level: 40, width: 320, height: 180)

        output.hold()
        feeder.submit(first)
        #expect(output.waitUntilParked(), "the first frame never reached the output")
        // The first frame is now parked inside `display`; these three land while
        // it is, and only the last of them can still be shown.
        feeder.submit(superseded)
        feeder.submit(alsoSuperseded)
        feeder.submit(newest)
        output.release() // lets `first` through
        output.release() // and whatever followed it
        feeder.settle()

        let shown = output.displayed
        #expect(shown.count == 2,
                "the output was handed \(shown.count) frames for four submissions")
        #expect(shown.first === first)
        #expect(shown.last === newest,
                "the frame that followed was not the newest one submitted")
        #expect(!shown.contains { $0 === superseded || $0 === alsoSuperseded },
                "a superseded frame reached the output")
    }

    /// Stopping reaches the board. A feeder dropped without it leaves the output
    /// running on the last frame it was given.
    @Test func stoppingReachesTheOutput() {
        let output = FakePlayoutOutput(width: 320, height: 180)
        let feeder = PlayoutFeeder(output: output)
        feeder.stop()
        #expect(output.stops == 1)
    }
}
