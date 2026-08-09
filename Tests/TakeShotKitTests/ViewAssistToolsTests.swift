import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The operator aids as the player shows them: what is still drawn over the
/// picture, and the popover that drives all of them. What the aids do when they
/// are dragged is `ViewAssistZoomTests`.
///
/// The exposure legend is NOT here any more. It used to be a SwiftUI overlay
/// measured against the player and inset to dodge the badge row and the
/// transport; the owner ruled that it has to reach the hardware monitor with
/// the false colour it explains, so it is burned into the display frame and
/// measured against the SIGNAL in `AssistLegendTests`. What is left of it in
/// this layer is the pair of pickers below and the settings they write.
@MainActor
struct ViewAssistToolsTests {
    // MARK: - the legend

    /// Four placements, four shapes (owner items 39/40): a column down the left
    /// or the right, a row along the top or the bottom.
    @Test func theFourPlacementsFaceTheWayTheyAreNamed() {
        #expect(AssistLegendPlacement.allCases.count == 4)
        #expect(AssistLegendPlacement.left.isVertical)
        #expect(AssistLegendPlacement.right.isVertical)
        #expect(!AssistLegendPlacement.top.isVertical)
        #expect(!AssistLegendPlacement.bottom.isVertical)
        // …and the default is the bottom, centered, at the medium size
        #expect(AssistLegendPlacement.standard == .bottom)
        #expect(AssistLegendPlacement(rawValue: "") ?? .standard == .bottom)
    }

    /// Both pickers say something in both languages. The strip itself carries
    /// stop marks and no words at all, so these labels are the only part of the
    /// legend a translation can reach.
    @Test func theLegendPickersAreTranslated() {
        for language in [AppLanguage.english, .russian] {
            for key in AssistLegendSize.allCases.map(\.labelKey)
                + AssistLegendPlacement.allCases.map(\.labelKey) {
                let value = ViewRender.withLanguage(language) { L(key) }
                #expect(value != key,
                        "\(key) renders as its raw key in \(language.rawValue)")
            }
        }
    }

    /// Whatever the aids draw — framelines and safe areas magnified ten times
    /// over — the player underneath must come out the size it was asked for.
    @Test func theAssistOverlaysNeverStretchThePlayer() async throws {
        try await ViewProbe.run { probe in
            let base = CGSize(width: ViewBudget.playerWidth, height: 380)
            probe.controller.assist.colorTool = .elZone
            probe.controller.settings.assist.framelineRatio = 2.39
            probe.controller.settings.assist.safeAreasOn = true
            // the new ceiling, so the overlays are measured at what the zoom
            // can actually reach (owner item 42)
            probe.controller.punchInLevel = ViewAssist.maxPunchIn
            for fullscreen in [false, true] {
                let size = ViewRender.laidOutSize(
                    probe.hosted(Color.clear.playerTopBadges(
                        showsModeSwitch: !fullscreen, autoHide: fullscreen)),
                    in: base)
                #expect(size == base,
                        "the aids stretched the player, fullscreen \(fullscreen)")
            }
        }
    }

    // The fullscreen players carrying the zoom input is `ViewAssistZoomTests`
    // (that suite owns the pan/zoom behaviour; this one owns what is drawn).

    // MARK: - the popover

    /// The panel gained the legend rows, the safe-area margins and the punch-in
    /// slider. It still cannot fit its ideal width (the exposure segmented
    /// control alone wants ~245pt), so what matters is that everything can be
    /// SQUEEZED into the fixed popover — a minimum wider than the box is a
    /// clipped row.
    @Test func theAssistPopoverStillFitsWithEveryNewRow() async throws {
        try await ViewProbe.run { probe in
            probe.controller.assist.colorTool = .falseColor
            probe.controller.assist.zebraOn = true
            probe.controller.assist.peakingOn = true
            probe.controller.settings.assist.safeAreasOn = true
            probe.controller.settings.assist.framelineRatio = 2.39
            probe.controller.punchInLevel = 2.5

            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "the Russian assist rows stop at \(minimum.ru)pt, box is \(box)")
            #expect(minimum.en <= box)

            let ideal = probe.fittingSizes { AssistControlsPanel() }
            #expect(ideal.ru.height > ideal.en.height - 1,
                    "a row went missing in Russian: \(ideal)")
        }
    }

    /// The badge that opens it has to read as an exposure aid. A symbol name
    /// that does not resolve renders as nothing at all, silently.
    @Test func theAssistBadgeSymbolResolves() {
        #expect(NSImage(systemSymbolName: AssistMenu.symbol,
                        accessibilityDescription: nil) != nil,
                "\(AssistMenu.symbol) is not an SF Symbol on this system")
        #expect(!AssistMenu.symbol.contains("arrow"),
                "the assist badge is wearing a fullscreen icon again")
    }

}

/// What the aids leave behind for the next launch: the legend's size and edge,
/// the peaking tint and how hard it is driven, and the safe-area margins.
///
/// Its own suite rather than more rows in `ViewAssistToolsTests` — that one is
/// about what is DRAWN and this one about what is stored.
@MainActor
struct ViewAssistSettingsTests {
    /// Old saved settings have none of these fields, and must still decode —
    /// with the standard 93/90 safe areas and a medium legend.
    @Test func theNewFieldsDecodeFromSettingsWrittenWithoutThem() throws {
        let legacy = """
        {"codec":"ProRes 422","namingTemplate":"{prefix}_C{clip}",
         "destinationPath":"/tmp/x","detectionMode":"vanc",
         "startDebounceFrames":0,"stopDebounceFrames":0,
         "projectName":"P","cameraLabel":"A"}
        """
        let settings = try JSONDecoder().decode(
            CaptureSettings.self, from: Data(legacy.utf8))
        #expect(settings.assist.legendSize == nil)
        #expect(settings.assist.legendPlacement == nil)
        #expect(settings.assist.peakingColor == nil)
        #expect(settings.assist.peakingIntensity == nil)
        #expect(settings.assist.safeActionPercentEffective == 93)
        #expect(settings.assist.safeTitlePercentEffective == 90)
        // SMPTE RP 218 / EBU R 95, and the ORDER is the point: title safe is
        // the tighter box and has to fall inside action safe. Assign the pair
        // the other way round and the two guides swap, which draws a title-safe
        // line outside the action-safe line — a diagram that contradicts itself.
        #expect(settings.assist.safeTitlePercentEffective
                < settings.assist.safeActionPercentEffective,
                "title safe is drawn outside action safe")

        // and a nonsense value cannot put the guides outside the picture
        var edited = settings
        edited.assist.safeActionPercent = 0
        edited.assist.safeTitlePercent = 400
        #expect(edited.assist.safeActionPercentEffective == 50)
        #expect(edited.assist.safeTitlePercentEffective == 100)
    }

    /// Legend size and placement persist, and the defaults are stored as nil so
    /// a blob written by this build still decodes on an older one.
    @Test func theLegendChoicesPersist() async throws {
        try await ViewProbe.run { probe in
            probe.controller.legendSize = .large
            probe.controller.legendPlacement = .left
            #expect(probe.controller.settings.assist.legendSize == "l")
            #expect(probe.controller.settings.assist.legendPlacement == "left")
            // …and the picker reaches the RENDERER, which is the half that
            // makes it to the hardware monitor: the legend is burned into the
            // display frame off `assist`, not drawn from the settings blob.
            #expect(probe.controller.assist.legend
                == AssistLegend(size: .large, placement: .left))

            let reloaded = CaptureSettings.loaded(from: probe.store)
            #expect(reloaded.assist.legendSize == "l")
            #expect(reloaded.assist.legendPlacement == "left")

            // the defaults — medium, bottom centre (owner item 40)
            probe.controller.legendSize = .medium
            probe.controller.legendPlacement = .bottom
            #expect(probe.controller.settings.assist.legendSize == nil)
            #expect(probe.controller.settings.assist.legendPlacement == nil)
            #expect(probe.controller.legendSize == .medium)
            #expect(probe.controller.legendPlacement == .bottom)
            #expect(probe.controller.assist.legend == AssistLegend())
        }
    }

    /// …and they come BACK at launch on the value the renderer reads. A stored
    /// choice that only reappeared in the picker would leave the monitor
    /// drawing last session's legend somewhere else.
    @Test func theLegendChoicesAreRestoredAtStartup() async throws {
        try await ViewProbe.run(configure: {
            $0.assist.legendSize = "s"
            $0.assist.legendPlacement = "right"
        }, { probe in
            #expect(probe.controller.legendPlacement == .right)
            #expect(probe.controller.assist.legend
                == AssistLegend(size: .small, placement: .right))
        })
    }

    /// Focus peaking is dialled in percent and stored in the renderer's own
    /// unit (owner item 41): the mapping has to round-trip, 0 has to mean no
    /// edges at all, and a value written before the percentage existed has to
    /// land somewhere sensible on the new slider rather than be reset.
    @Test func thePeakingSensitivityIsAPercentageThatRoundTrips() async throws {
        for percent in [0.0, 1, 25, 40, 50, 99, 100] {
            let intensity = ViewAssist.peakingIntensity(forPercent: percent)
            #expect(abs(ViewAssist.peakingPercent(forIntensity: intensity)
                        - percent) < 0.000_001,
                    "\(percent)% came back as a different percentage")
        }
        #expect(ViewAssist.peakingIntensity(forPercent: 0) == 0,
                "0% still draws edges")
        #expect(ViewAssist.peakingIntensity(forPercent: 100)
                == ViewAssist.maxPeakingIntensity)
        // out of range in either direction is clamped, not wrapped
        #expect(ViewAssist.peakingIntensity(forPercent: -20) == 0)
        #expect(ViewAssist.peakingIntensity(forPercent: 500)
                == ViewAssist.maxPeakingIntensity)

        // the values the OLD 2…30 slider could leave behind, on the new scale
        #expect(abs(ViewAssist.peakingPercent(forIntensity: 2) - 20.0 / 3) < 0.001)
        #expect(ViewAssist.peakingPercent(forIntensity: 12) == 40)
        #expect(ViewAssist.peakingPercent(forIntensity: 30) == 100)
        #expect(ViewAssist().peakingPercent == 40,
                "the shipped default moved off what it renders as")
    }

    /// …and it survives a relaunch, through the controller, in both units.
    @Test func thePeakingSensitivityPersistsAndComesBack() async throws {
        try await ViewProbe.run { probe in
            probe.controller.peakingPercent = 80
            probe.controller.commitAssistDraft()
            #expect(probe.controller.assist.peakingIntensity == 24)
            #expect(probe.controller.settings.assist.peakingIntensity == 24)
            #expect(CaptureSettings.loaded(from: probe.store).assist.peakingIntensity == 24)

            probe.controller.peakingPercent = 40 // the default, stored as nil
            probe.controller.commitAssistDraft()
            #expect(probe.controller.settings.assist.peakingIntensity == nil)
        }
        // a stored gain from the old range comes back as itself
        try await ViewProbe.run(configure: { $0.assist.peakingIntensity = 2 }, { probe in
            #expect(probe.controller.assist.peakingIntensity == 2)
            #expect(abs(probe.controller.peakingPercent - 20.0 / 3) < 0.001)
        })
        // …and a hand-edited nonsense value is clamped, not adopted
        try await ViewProbe.run(configure: { $0.assist.peakingIntensity = 900 }, { probe in
            #expect(probe.controller.assist.peakingIntensity
                    == ViewAssist.maxPeakingIntensity)
        })
    }

    /// The peaking color is a crew convention like the marker color, so it
    /// persists the same way: by raw value, nil at the default so old builds
    /// still decode the blob.
    @Test func thePeakingColorPersists() async throws {
        try await ViewProbe.run { probe in
            probe.controller.setAssist { $0.peakingColor = .green }
            #expect(probe.controller.settings.assist.peakingColor == "green")
            #expect(CaptureSettings.loaded(from: probe.store).assist.peakingColor
                    == "green")
            // …and the renderer sees it at once: the color rides ViewAssist,
            // which is what every surface is fed (see setViewAssist fan-out)
            #expect(probe.controller.liveAssist.peakingColor == .green)

            probe.controller.setAssist { $0.peakingColor = .red }
            #expect(probe.controller.settings.assist.peakingColor == nil)
        }
    }

    /// And it comes BACK at launch — with garbage in a hand-edited blob
    /// falling back to red rather than to a crash in the picker.
    @Test func thePeakingColorIsRestoredAtStartup() async throws {
        try await ViewProbe.run(configure: { $0.assist.peakingColor = "yellow" }, { probe in
            #expect(probe.controller.assist.peakingColor == .yellow)
        })
        try await ViewProbe.run(configure: { $0.assist.peakingColor = "vermilion" }, { probe in
            #expect(probe.controller.assist.peakingColor == .red)
        })
    }
}
