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
                    - 2 * AssistLegendPlacement.sideInset
                #expect(ideal.ru.width <= budget,
                        "the large \(tool) legend wants \(ideal.ru.width)pt of \(budget)")
            }
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
            let clearance = AssistLegendPlacement.fullscreenBottomInset
            #expect(clearance >= tallest + lift,
                    "the chrome band is \(tallest + lift)pt, the legend clears only \(clearance)pt")

            // and the windowed inset clears the transport the player floats
            #expect(AssistLegendPlacement.bottomInset >= ViewBudget.transportHeight)
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
            #expect(AssistLegendPlacement.topInset >= reach,
                    "the badge row reaches \(reach)pt, the legend clears only \(AssistLegendPlacement.topInset)pt")
        }
    }

    /// A top corner has to clear the badge row instead, and a bottom corner must
    /// not carry the top inset around with it.
    @Test func theLegendInsetsFollowTheChosenCorner() {
        for corner in AssistLegendCorner.allCases {
            for fullscreen in [false, true] {
                let insets = AssistLegendPlacement.insets(corner: corner,
                                                          fullscreen: fullscreen)
                #expect(insets.leading == AssistLegendPlacement.sideInset)
                #expect(insets.trailing == AssistLegendPlacement.sideInset)
                if corner.isTop {
                    #expect(insets.top == AssistLegendPlacement.topInset)
                    #expect(insets.bottom == 0)
                } else {
                    #expect(insets.top == 0)
                    #expect(insets.bottom == (fullscreen
                        ? AssistLegendPlacement.fullscreenBottomInset
                        : AssistLegendPlacement.bottomInset))
                }
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
            probe.controller.punchInLevel = 4
            probe.controller.legendSize = .large
            for corner in AssistLegendCorner.allCases {
                probe.controller.legendCorner = corner
                for fullscreen in [false, true] {
                    let size = ViewRender.laidOutSize(
                        probe.hosted(Color.clear.playerTopBadges(
                            showsModeSwitch: !fullscreen, autoHide: fullscreen)),
                        in: base)
                    #expect(size == base,
                            "\(corner) legend stretched the player, fullscreen \(fullscreen)")
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

    // MARK: - settings

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
        #expect(settings.legendCorner == nil)
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

    /// Legend size and corner persist, and the defaults are stored as nil so a
    /// blob written by this build still decodes on an older one.
    @Test func theLegendChoicesPersist() async throws {
        try await ViewProbe.run { probe in
            probe.controller.legendSize = .large
            probe.controller.legendCorner = .topLeading
            #expect(probe.controller.settings.legendSize == "l")
            #expect(probe.controller.settings.legendCorner == "topLeading")

            let reloaded = CaptureSettings.loaded(from: probe.store)
            #expect(reloaded.legendSize == "l")
            #expect(reloaded.legendCorner == "topLeading")

            probe.controller.legendSize = .medium
            probe.controller.legendCorner = .bottomTrailing
            #expect(probe.controller.settings.legendSize == nil)
            #expect(probe.controller.settings.legendCorner == nil)
            #expect(probe.controller.legendSize == .medium)
            #expect(probe.controller.legendCorner == .bottomTrailing)
        }
    }
}
