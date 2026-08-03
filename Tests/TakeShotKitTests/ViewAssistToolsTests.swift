import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The operator aids as the player shows them: the exposure legend (its size,
/// its corner, and staying clear of the chrome), the overlays it shares the
/// picture with, and the popover that drives all of them. What the aids do when
/// they are dragged is `ViewAssistZoomTests`.
@MainActor
struct ViewAssistToolsTests {
    // MARK: - the legend

    /// The complaint was that the legend is tiny with no way to change it. The
    /// three sizes have to be genuinely different, and none of them may depend
    /// on the language — it is a strip of swatches with English stop labels.
    @Test func theLegendGrowsWithItsSizeSettingInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            for tool in [ViewAssist.ColorTool.falseColor, .elZone] {
                var widths: [CGFloat] = []
                var heights: [CGFloat] = []
                for size in AssistLegendSize.allCases {
                    let ideal = probe.fittingSizes {
                        AssistLegend(tool: tool, size: size)
                    }
                    #expect(ideal.ru == ideal.en,
                            "\(tool) at \(size) differs by language: \(ideal)")
                    widths.append(ideal.en.width)
                    heights.append(ideal.en.height)
                }
                #expect(widths == widths.sorted(),
                        "\(tool) legend widths are not in size order: \(widths)")
                #expect(heights == heights.sorted(),
                        "\(tool) legend heights are not in size order: \(heights)")
                // the default (medium) has to be bigger than what shipped
                #expect(widths[1] > widths[0] && heights[1] > heights[0])
            }
        }
    }

    /// Even the large legend has to fit the player in the narrowest window the
    /// app allows — EL Zone is thirteen bands wide.
    @Test func theLargestLegendFitsTheNarrowestPlayer() async throws {
        try await ViewProbe.run { probe in
            for tool in [ViewAssist.ColorTool.falseColor, .elZone] {
                let ideal = probe.fittingSizes {
                    AssistLegend(tool: tool, size: .large)
                }
                let budget = ViewBudget.playerWidth
                    - 2 * AssistLegendChrome.sideInset
                #expect(ideal.ru.width <= budget,
                        "the large \(tool) legend wants \(ideal.ru.width)pt of \(budget)")
            }
        }
    }

    /// The vertical legend is the same bands turned on their side (owner items
    /// 39/40), and turning it must actually change its shape: taller than it is
    /// wide, where the horizontal strip is the other way round.
    @Test func theVerticalLegendIsAColumnAndTheHorizontalOneIsARow() async throws {
        try await ViewProbe.run { probe in
            for tool in [ViewAssist.ColorTool.falseColor, .elZone] {
                let across = probe.fittingSizes { AssistLegend(tool: tool) }
                let down = probe.fittingSizes {
                    AssistLegend(tool: tool, vertical: true)
                }
                #expect(across.en.width > across.en.height,
                        "the horizontal \(tool) legend is not a row: \(across.en)")
                #expect(down.en.height > down.en.width,
                        "the vertical \(tool) legend is not a column: \(down.en)")
                #expect(down.en == down.ru,
                        "the vertical \(tool) legend differs by language: \(down)")
            }
        }
    }

    /// Down the side of the player, the tall one (thirteen EL Zone bands at the
    /// large size) still has to fit between the badge row and the transport —
    /// centered vertically, it is clipped at BOTH ends if it does not.
    @Test func theTallestVerticalLegendFitsBetweenTheChrome() async throws {
        try await ViewProbe.run { probe in
            /// The player in the narrowest window is not tall either; 380 is
            /// the height the overlay suite lays it out at.
            let playerHeight: CGFloat = 380
            let insets = AssistLegendChrome.insets(placement: .left,
                                                   fullscreen: false)
            let budget = playerHeight - insets.top - insets.bottom
            let ideal = probe.fittingSizes {
                AssistLegend(tool: .elZone, size: .large, vertical: true)
            }
            #expect(ideal.ru.height <= budget,
                    "the tall legend wants \(ideal.ru.height)pt of \(budget)")
        }
    }

    /// In fullscreen the footer and the transport hide until the pointer asks
    /// for them, and they come back in the same place: a legend tucked into the
    /// bottom of the screen there vanishes under the controls exactly when the
    /// operator reaches for them. The inset is checked against the bars the
    /// fullscreen windows actually float, so a taller bar fails this instead of
    /// silently covering the legend.
    @Test func theFullscreenInsetClearsTheAutoHidingChrome() async throws {
        try await ViewProbe.run { probe in
            /// Both fullscreen windows lift their bar by 18pt (see
            /// LiveFullscreenView / PlaybackFullscreenView).
            let lift: CGFloat = 18
            let footer = probe.sizes(proposedWidth: 1280 - 120) {
                BottomBarView()
            }
            let transport = probe.sizes(proposedWidth: 1280 - 120) {
                TransportBar(player: ViewFixtures.idlePlayer(),
                             model: probe.controller.transport)
            }
            let tallest = max(footer.en.height, footer.ru.height,
                              transport.en.height, transport.ru.height)
            let clearance = AssistLegendChrome.fullscreenBottomInset
            #expect(clearance >= tallest + lift,
                    "the chrome band is \(tallest + lift)pt, the legend clears only \(clearance)pt")

            // and the windowed inset clears the transport the player floats
            #expect(AssistLegendChrome.bottomInset >= ViewBudget.transportHeight)
        }
    }

    /// The top chrome auto-hides in fullscreen too, and it is the badge row that
    /// comes back there — so a legend in a TOP corner has the same problem the
    /// bottom one had. Measured against the tallest thing the row can hold
    /// rather than against 44: the number only means something if a badge that
    /// grows fails this.
    @Test func theTopInsetClearsTheBadgeRow() async throws {
        try await ViewProbe.run { probe in
            /// `PlayerBadges.topChrome` insets the whole row by this.
            let rowPadding: CGFloat = 8
            // The timecode badge is the tallest in the row — it is the only one
            // carrying .body text (LiveTimecodeText); the rest are 13pt icons.
            let timecode = probe.fittingSizes {
                playerOverlayBadge {
                    Text(verbatim: "00:00:00:00").font(.body).monospacedDigit()
                }
            }
            // in fullscreen the mode switch is gone but compare can still show
            let compare = probe.fittingSizes { CompareControls() }
            let tallest = max(timecode.en.height, timecode.ru.height,
                              compare.en.height, compare.ru.height)
            let reach = tallest + rowPadding
            #expect(AssistLegendChrome.topInset >= reach,
                    "the badge row reaches \(reach)pt, the legend clears only \(AssistLegendChrome.topInset)pt")
        }
    }

    /// Four placements, four shapes (owner items 39/40): vertical down the left
    /// or the right, horizontal centered along the top or the bottom.
    @Test func theFourPlacementsFaceTheWayTheyAreNamed() {
        #expect(AssistLegendPlacement.allCases.count == 4)
        #expect(AssistLegendPlacement.left.isVertical)
        #expect(AssistLegendPlacement.right.isVertical)
        #expect(!AssistLegendPlacement.top.isVertical)
        #expect(!AssistLegendPlacement.bottom.isVertical)
        // a horizontal legend is centered along its edge, a vertical one down
        // its side — that is what the alignment has to say
        #expect(AssistLegendPlacement.top.alignment == .top)
        #expect(AssistLegendPlacement.bottom.alignment == .bottom)
        #expect(AssistLegendPlacement.left.alignment == .leading)
        #expect(AssistLegendPlacement.right.alignment == .trailing)
        // …and the default is the bottom, centered, at the medium size
        #expect(AssistLegendPlacement.standard == .bottom)
        #expect(AssistLegendPlacement(rawValue: "") ?? .standard == .bottom)
    }

    /// A top placement clears the badge row, a bottom one the transport, and a
    /// vertical one is centered between BOTH — with only one of the two insets
    /// a thirteen-band strip runs under the transport.
    @Test func theLegendInsetsFollowTheChosenPlacement() {
        for placement in AssistLegendPlacement.allCases {
            for fullscreen in [false, true] {
                let insets = AssistLegendChrome.insets(placement: placement,
                                                       fullscreen: fullscreen)
                let bottom = fullscreen
                    ? AssistLegendChrome.fullscreenBottomInset
                    : AssistLegendChrome.bottomInset
                #expect(insets.leading == AssistLegendChrome.sideInset)
                #expect(insets.trailing == AssistLegendChrome.sideInset)
                #expect(insets.top == (placement == .bottom
                                       ? 0 : AssistLegendChrome.topInset),
                        "\(placement) top inset is \(insets.top)")
                #expect(insets.bottom == (placement == .top ? 0 : bottom),
                        "\(placement) bottom inset is \(insets.bottom)")
            }
        }
    }

    /// The aids are an overlay: whatever they draw — a legend in any corner at
    /// any size, framelines and safe areas magnified four times over — the
    /// player underneath must come out the size it was asked for.
    @Test func theAssistOverlaysNeverStretchThePlayer() async throws {
        try await ViewProbe.run { probe in
            let base = CGSize(width: ViewBudget.playerWidth, height: 380)
            probe.controller.assist.colorTool = .elZone
            probe.controller.settings.framelineRatio = 2.39
            probe.controller.settings.safeAreasOn = true
            // the new ceiling, so the overlays are measured at what the zoom
            // can actually reach (owner item 42)
            probe.controller.punchInLevel = ViewAssist.maxPunchIn
            probe.controller.legendSize = .large
            for placement in AssistLegendPlacement.allCases {
                probe.controller.legendPlacement = placement
                for fullscreen in [false, true] {
                    let size = ViewRender.laidOutSize(
                        probe.hosted(Color.clear.playerTopBadges(
                            showsModeSwitch: !fullscreen, autoHide: fullscreen)),
                        in: base)
                    #expect(size == base,
                            "\(placement) legend stretched the player, fullscreen \(fullscreen)")
                }
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
            probe.controller.settings.safeAreasOn = true
            probe.controller.settings.framelineRatio = 2.39
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
        #expect(settings.legendSize == nil)
        #expect(settings.legendPlacement == nil)
        #expect(settings.peakingColor == nil)
        #expect(settings.peakingIntensity == nil)
        #expect(settings.safeActionPercentEffective == 93)
        #expect(settings.safeTitlePercentEffective == 90)
        // SMPTE RP 218 / EBU R 95, and the ORDER is the point: title safe is
        // the tighter box and has to fall inside action safe. Assign the pair
        // the other way round and the two guides swap, which draws a title-safe
        // line outside the action-safe line — a diagram that contradicts itself.
        #expect(settings.safeTitlePercentEffective
                < settings.safeActionPercentEffective,
                "title safe is drawn outside action safe")

        // and a nonsense value cannot put the guides outside the picture
        var edited = settings
        edited.safeActionPercent = 0
        edited.safeTitlePercent = 400
        #expect(edited.safeActionPercentEffective == 50)
        #expect(edited.safeTitlePercentEffective == 100)
    }

    /// Legend size and placement persist, and the defaults are stored as nil so
    /// a blob written by this build still decodes on an older one.
    @Test func theLegendChoicesPersist() async throws {
        try await ViewProbe.run { probe in
            probe.controller.legendSize = .large
            probe.controller.legendPlacement = .left
            #expect(probe.controller.settings.legendSize == "l")
            #expect(probe.controller.settings.legendPlacement == "left")

            let reloaded = CaptureSettings.loaded(from: probe.store)
            #expect(reloaded.legendSize == "l")
            #expect(reloaded.legendPlacement == "left")

            // the defaults — medium, bottom centre (owner item 40)
            probe.controller.legendSize = .medium
            probe.controller.legendPlacement = .bottom
            #expect(probe.controller.settings.legendSize == nil)
            #expect(probe.controller.settings.legendPlacement == nil)
            #expect(probe.controller.legendSize == .medium)
            #expect(probe.controller.legendPlacement == .bottom)
        }
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
            #expect(probe.controller.settings.peakingIntensity == 24)
            #expect(CaptureSettings.loaded(from: probe.store).peakingIntensity == 24)

            probe.controller.peakingPercent = 40 // the default, stored as nil
            probe.controller.commitAssistDraft()
            #expect(probe.controller.settings.peakingIntensity == nil)
        }
        // a stored gain from the old range comes back as itself
        try await ViewProbe.run(configure: { $0.peakingIntensity = 2 }, { probe in
            #expect(probe.controller.assist.peakingIntensity == 2)
            #expect(abs(probe.controller.peakingPercent - 20.0 / 3) < 0.001)
        })
        // …and a hand-edited nonsense value is clamped, not adopted
        try await ViewProbe.run(configure: { $0.peakingIntensity = 900 }, { probe in
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
            #expect(probe.controller.settings.peakingColor == "green")
            #expect(CaptureSettings.loaded(from: probe.store).peakingColor
                    == "green")
            // …and the renderer sees it at once: the color rides ViewAssist,
            // which is what every surface is fed (see setViewAssist fan-out)
            #expect(probe.controller.liveAssist.peakingColor == .green)

            probe.controller.setAssist { $0.peakingColor = .red }
            #expect(probe.controller.settings.peakingColor == nil)
        }
    }

    /// And it comes BACK at launch — with garbage in a hand-edited blob
    /// falling back to red rather than to a crash in the picker.
    @Test func thePeakingColorIsRestoredAtStartup() async throws {
        try await ViewProbe.run(configure: { $0.peakingColor = "yellow" }, { probe in
            #expect(probe.controller.assist.peakingColor == .yellow)
        })
        try await ViewProbe.run(configure: { $0.peakingColor = "vermilion" }, { probe in
            #expect(probe.controller.assist.peakingColor == .red)
        })
    }
}
