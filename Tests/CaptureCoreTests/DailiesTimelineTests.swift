import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// The pure halves of the dailies engine: the timecode-for-frame math the
/// running burn-in draws, the output raster rule, and how the toggles turn a
/// take's facts into strip texts. All of it without media — the exactness the
/// pixel tests cannot state (they can only say "the strip changed") lives
/// here.
struct DailiesTimelineTests {
    private let tenOClock = Timecode(hours: 10, minutes: 0, seconds: 0,
                                     frames: 0, fps: 25)

    // MARK: - one anchor, the common case

    @Test func framesAdvanceFromTheStartAnchor() {
        let timeline = DailiesTimeline(
            anchors: [.init(seconds: 0, timecode: tenOClock)], frameRate: 25)
        #expect(timeline.text(atSeconds: 0) == "10:00:00:00")
        #expect(timeline.text(atSeconds: 13.0 / 25) == "10:00:00:13")
        #expect(timeline.text(atSeconds: 30.0 / 25) == "10:00:01:05")
        // frame 42 — the label DailiesEngineTests reads back as pixels
        #expect(timeline.text(atSeconds: 42.0 / 25) == "10:00:01:17")
    }

    /// Presentation times come out of rational CMTime math a hair off the
    /// ideal grid; half a frame either way must not change the label.
    @Test func aHairOffTheFrameGridStillLandsOnTheFrame() {
        let timeline = DailiesTimeline(
            anchors: [.init(seconds: 0, timecode: tenOClock)], frameRate: 25)
        #expect(timeline.text(atSeconds: 13.0 / 25 - 0.005) == "10:00:00:13")
        #expect(timeline.text(atSeconds: 13.0 / 25 + 0.005) == "10:00:00:13")
    }

    /// 29.97 DF: the burn-in crosses a drop-frame minute exactly like the
    /// camera did — 00:00:59;29 + 1 frame is 00:01:00;02, never ;00.
    @Test func dropFrameMinuteBoundaryIsLabelledLikeTheCamera() {
        let anchor = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 20,
                              fps: 30, isDropFrame: true)
        let timeline = DailiesTimeline(
            anchors: [.init(seconds: 0, timecode: anchor)],
            frameRate: 29.97)
        // 10 real frames past ...59;20 crosses the minute: ;29 then ;02.
        #expect(timeline.text(atSeconds: 9.0 / 29.97) == "00:00:59;29")
        #expect(timeline.text(atSeconds: 10.0 / 29.97) == "00:01:00;02")
    }

    // MARK: - several anchors (the mid-take Rec Run re-anchor)

    /// TakeWriter writes an extra tc32 sample when the camera's TC started
    /// running mid-take; the burn-in has to jump with it, not average it.
    @Test func aResyncAnchorTakesOverFromItsOwnFrame() {
        let resync = Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0,
                              fps: 25)
        let timeline = DailiesTimeline(
            anchors: [.init(seconds: 0, timecode: tenOClock),
                      .init(seconds: 2, timecode: resync)],
            frameRate: 25)
        #expect(timeline.text(atSeconds: 49.0 / 25) == "10:00:01:24")
        #expect(timeline.text(atSeconds: 2) == "11:00:00:00")
        #expect(timeline.text(atSeconds: 51.0 / 25) == "11:00:00:01")
    }

    /// Anchors arriving unsorted (a track read in file order) must not make
    /// time run backwards.
    @Test func anchorsAreSortedOnInit() {
        let later = Timecode(hours: 11, minutes: 0, seconds: 0, frames: 0,
                             fps: 25)
        let timeline = DailiesTimeline(
            anchors: [.init(seconds: 2, timecode: later),
                      .init(seconds: 0, timecode: tenOClock)],
            frameRate: 25)
        #expect(timeline.text(atSeconds: 0) == "10:00:00:00")
        #expect(timeline.text(atSeconds: 2) == "11:00:00:00")
    }

    // MARK: - the output raster rule

    @Test func sourcesAt1080pOrBelowKeepTheirSize() {
        #expect(DailiesEngine.outputSize(for: CGSize(width: 1920, height: 1080))
            == CGSize(width: 1920, height: 1080))
        #expect(DailiesEngine.outputSize(for: CGSize(width: 320, height: 180))
            == CGSize(width: 320, height: 180))
    }

    @Test func largerSourcesAreFittedInto1080pWithEvenEdges() {
        #expect(DailiesEngine.outputSize(for: CGSize(width: 3840, height: 2160))
            == CGSize(width: 1920, height: 1080))
        // 4K DCI: width-bound, height comes out 1010.5… → floored to even
        #expect(DailiesEngine.outputSize(for: CGSize(width: 4096, height: 2160))
            == CGSize(width: 1920, height: 1012))
        // portrait: height is the binding edge
        #expect(DailiesEngine.outputSize(for: CGSize(width: 1080, height: 1920))
            == CGSize(width: 606, height: 1080))
    }

    // MARK: - toggles → strip texts

    private var item: DailiesItem {
        DailiesItem(source: URL(fileURLWithPath: "/takes/A001C01.mov"),
                    outputName: "A001C01_DAILY", clipName: "A001C01",
                    projectLine: "UnitFilm · A001", dateText: "2026-08-02",
                    startTimecode: nil)
    }

    @Test func projectAndDateShareTheBottomRightStrip() {
        var burnins = DailiesBurnins()
        burnins.date = true
        let texts = burnins.overlayTexts(for: item)
        #expect(texts.project == "UnitFilm · A001 · 2026-08-02")
        #expect(texts.clipName == "A001C01")
        #expect(texts.timecodeTemplate == "00:00:00:00")
        #expect(texts.custom == nil)
    }

    @Test func everySwitchedOffLineVanishesFromTheOverlay() {
        let burnins = DailiesBurnins(timecode: false, clipName: false,
                                     project: false, date: true,
                                     customText: "FOR REVIEW")
        let texts = burnins.overlayTexts(for: item)
        #expect(texts.project == "2026-08-02")
        #expect(texts.clipName == nil)
        #expect(texts.timecodeTemplate == nil)
        #expect(texts.custom == "FOR REVIEW")
    }

    /// The layout puts each enabled strip in its own corner, inside the frame.
    @Test func theOverlayLayoutIsTheClassicDailiesArrangement() throws {
        var burnins = DailiesBurnins()
        burnins.customText = "FOR REVIEW"
        let size = CGSize(width: 1920, height: 1080)
        let overlay = DailiesOverlay(size: size,
                                     texts: burnins.overlayTexts(for: item))
        let tc = try #require(overlay.layout.timecode)
        let name = try #require(overlay.layout.clipName)
        let project = try #require(overlay.layout.project)
        let custom = try #require(overlay.layout.custom)
        // TC top-center, custom top-left, name bottom-left, project
        // bottom-right — and every strip fully inside the frame.
        #expect(abs(tc.midX - size.width / 2) < 2)
        #expect(tc.minY < size.height / 4)
        #expect(custom.minX < size.width / 4 && custom.minY < size.height / 4)
        #expect(name.minX < size.width / 4 && name.maxY > size.height * 3 / 4)
        #expect(project.maxX > size.width * 3 / 4
            && project.maxY > size.height * 3 / 4)
        for rect in [tc, name, project, custom] {
            #expect(CGRect(origin: .zero, size: size).contains(rect))
        }
    }
}
