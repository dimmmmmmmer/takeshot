import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// The framelines' geometry, now that they are drawn into the frame rather than
/// laid over the player (owner item 7).
///
/// The arithmetic used to live in a SwiftUI overlay and was measured against a
/// VIEWPORT. It is measured against the SIGNAL now, which is the only reading of
/// "2.39" that means anything, and it is the same box a hardware monitor gets.
struct AssistGuidesTests {
    private static let hd = CGSize(width: 1920, height: 1080)

    @Test func aWiderRatioThanTheFrameLetterboxesIt() {
        let guides = AssistGuides(ratio: 2.39)
        let box = guides.framedRect(in: Self.hd)
        #expect(box.width == 1920)
        #expect(abs(box.height - 1920 / 2.39) < 0.5)
        #expect(abs(box.midY - 540) < 0.5, "the frameline is not centered")
    }

    @Test func aNarrowerRatioThanTheFramePillarboxesIt() {
        let guides = AssistGuides(ratio: 4.0 / 3.0)
        let box = guides.framedRect(in: Self.hd)
        #expect(box.height == 1080)
        #expect(abs(box.width - 1080 * 4 / 3) < 0.5)
        #expect(abs(box.midX - 960) < 0.5)
    }

    /// No ratio is the whole frame, not an empty box: the safe areas sit inside
    /// the frameline when there is one and inside the picture when there is not.
    @Test func noRatioLeavesTheWholeFrame() {
        #expect(AssistGuides().framedRect(in: Self.hd)
                == CGRect(origin: .zero, size: Self.hd))
        #expect(AssistGuides(ratio: 0).framedRect(in: Self.hd).width == 1920)
    }

    /// SMPTE RP 218: title safe is the INNER box. Assign the pair the other way
    /// round and the guides swap, drawing a title-safe line outside the
    /// action-safe one — a diagram that contradicts itself.
    @Test func titleSafeFallsInsideActionSafe() {
        let guides = AssistGuides(safeAreas: true)
        let frame = guides.framedRect(in: Self.hd)
        let action = guides.safeRect(frame, percent: guides.actionPercent)
        let title = guides.safeRect(frame, percent: guides.titlePercent)
        #expect(frame.contains(action))
        #expect(action.contains(title))
        #expect(abs(action.width - 1920 * 0.93) < 0.5)
        #expect(abs(title.width - 1920 * 0.90) < 0.5)
    }

    /// A hand-edited settings blob cannot put a guide outside the picture.
    @Test func nonsenseMarginsClampInsteadOfEscaping() {
        let guides = AssistGuides(safeAreas: true)
        let frame = guides.framedRect(in: Self.hd)
        #expect(frame.contains(guides.safeRect(frame, percent: 400)))
        #expect(guides.safeRect(frame, percent: 0).width == 1920 * 0.5)
        #expect(guides.safeRect(frame, percent: 100) == frame)
    }

    /// The line has to be visible at the resolution it is drawn INTO, not at
    /// the size it happens to be shown at: one pixel on a UHD frame in a 1000pt
    /// player is a quarter of a screen pixel.
    @Test func theLineWidthScalesWithTheFrame() {
        let hd = AssistGuides.lineWidth(in: Self.hd)
        let uhd = AssistGuides.lineWidth(in: CGSize(width: 3840, height: 2160))
        #expect(hd >= 1)
        #expect(uhd == hd * 2, "\(uhd) on UHD against \(hd) on HD")
        #expect(AssistGuides.lineWidth(in: CGSize(width: 64, height: 32)) == 1,
                "a tiny frame still gets a line")
    }

    /// What the display stage asks before spending a pass. A frameline set to
    /// "off" and a safe-area toggle left off are the same nothing.
    @Test func nothingSwitchedOnIsNothingToDraw() {
        #expect(AssistGuides().isEmpty)
        #expect(AssistGuides(ratio: 0).isEmpty)
        #expect(!AssistGuides(ratio: 1.85).isEmpty)
        #expect(!AssistGuides(safeAreas: true).isEmpty)
    }

    /// The settings are the only place these values come from, and the
    /// conversion is one function so the drawn value and the edited one cannot
    /// mean different things.
    @Test func theGuidesComeOutOfTheSettingsIntact() {
        var settings = CaptureSettings()
        #expect(AssistGuides(settings: settings.assist).isEmpty)

        settings.assist.framelineRatio = 2.39
        settings.assist.safeAreasOn = true
        settings.assist.safeActionPercent = 88
        let guides = AssistGuides(settings: settings.assist)
        #expect(guides.ratio == 2.39)
        #expect(guides.safeAreas)
        #expect(guides.actionPercent == 88)
        #expect(guides.titlePercent == 90, "the unset margin lost its default")
    }
}
