import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// Guards the side panel (takes + other content), the big audio panel, the
/// scopes chrome and the VANC monitor. These live in containers with declared
/// minimum widths — 310pt for the takes panel, 420 for the scopes, 560 for the
/// VANC window — and the question for every one of them is whether the
/// translated chrome still fits the minimum the container promises.
@MainActor
struct ViewPanelTests {
    /// The takes panel has to survive being squeezed to the narrowest the split
    /// view allows, in both languages and in both view modes.
    @Test func takesPanelFitsTheNarrowestSidePanel() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let panel = ViewBudget.panelMinWidth
            for mode in ["list", "grid"] {
                probe.store.set(mode, forKey: "takesViewMode")
                // the panel reads its view mode through @AppStorage, and a store
                // that is not the one the test writes means only one of these
                // two layouts is ever rendered
                #expect(probe.store.string(forKey: "takesViewMode") == mode)
                let minimum = probe.minimumWidths(proposedHeight: 600) {
                    TakeListView()
                }
                #expect(minimum.ru <= panel,
                        "\(mode) takes panel needs \(minimum.ru)pt of \(panel)")
                let laid = probe.sizes(proposedWidth: ViewBudget.panelMinWidth,
                                       proposedHeight: 600) { TakeListView() }
                #expect(laid.ru == laid.en, "\(mode) takes panel: \(laid)")
                #expect(laid.ru.width == ViewBudget.panelMinWidth)
            }
        }
    }

    /// The empty state is a localized sentence in the middle of the panel
    /// ("No takes yet" / "Дублей пока нет") and the header above it carries the
    /// folder and export buttons.
    @Test func emptyTakesPanelFitsTheNarrowestSidePanel() async throws {
        try await ViewProbe.run { probe in
            let minimum = probe.minimumWidths(proposedHeight: 400) {
                TakeListView()
            }
            #expect(minimum.ru <= ViewBudget.panelMinWidth,
                    "the empty takes panel needs \(minimum.ru)pt")
            #expect(minimum.ru == minimum.en)
        }
    }

    /// The offload status is the one free-text string in the takes header, and it
    /// shares the row with the buttons and the view-mode picker. It must not be
    /// able to widen the panel — it truncates instead.
    @Test func offloadStatusDoesNotWidenTheTakesPanel() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let quiet = probe.minimumWidths(proposedHeight: 600) { TakeListView() }
            probe.controller.offloadStatus = ViewRender.withLanguage(.russian) {
                L("offload_done", 1024)
            }
            let busy = probe.minimumWidths(proposedHeight: 600) { TakeListView() }
            #expect(busy.ru <= max(quiet.ru, ViewBudget.panelMinWidth),
                    "the offload status pushed the panel to \(busy.ru)pt")
        }
    }

    /// Other content shares the panel with the takes list through a VSplitView,
    /// so it has the same width to work with.
    @Test func otherContentFitsTheNarrowestSidePanel() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedOtherFiles(probe.controller, in: probe.root)
            let panel = ViewBudget.panelMinWidth
            for mode in ["list", "grid"] {
                probe.store.set(mode, forKey: "otherViewMode")
                let minimum = probe.minimumWidths(proposedHeight: 300) {
                    OtherContentSection()
                }
                #expect(minimum.ru <= panel,
                        "\(mode) other-content needs \(minimum.ru)pt of \(panel)")
                #expect(minimum.ru == minimum.en,
                        "\(mode) other-content differs by language: \(minimum)")
            }
        }
    }

    /// Both sections share the list/grid toggle: two icons in a fixed 70pt
    /// segmented control, so no translation may resize it.
    @Test func viewModePickerKeepsItsFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                ViewModePicker(mode: .constant("list"))
            }
            #expect(ideal.en.width == 70)
            #expect(ideal.ru == ideal.en)
        }
    }

    /// The audio panel's width is set by the channel count and nothing else
    /// (`channels * 30 + 84`), which is precisely why the localized title and
    /// hint inside it must not be able to change it.
    @Test func audioPanelWidthFollowsTheChannelCountNotTheLanguage() async throws {
        try await ViewProbe.run { probe in
            for channels in [2, 8, 16] {
                ViewFixtures.seedAudioLevels(probe.controller, count: channels)
                let ideal = probe.fittingSizes {
                    AudioChannelPanel(live: probe.controller.live)
                }
                #expect(ideal.ru.width == CGFloat(channels) * 30 + 84,
                        "\(channels)ch panel is \(ideal.ru.width)pt wide")
                #expect(ideal.ru.width == ideal.en.width,
                        "\(channels)ch panel width changed with the language")
                #expect(ideal.ru.height > 200)
            }
        }
    }

    /// The panel is an overlay centered on the player, so at the normal 16
    /// channels it also has to fit inside it.
    @Test func audioPanelFitsThePlayer() async throws {
        try await ViewProbe.run { probe in
            ViewFixtures.seedAudioLevels(probe.controller)
            let ideal = probe.fittingSizes {
                AudioChannelPanel(live: probe.controller.live)
            }
            let player = ViewBudget.playerWidth
            #expect(ideal.ru.width <= player,
                    "the audio panel wants \(ideal.ru.width)pt of \(player)")
        }
    }

    /// The scopes chrome — four localized toggles, the value-scale picker, two
    /// brightness sliders and the reorder hint — has to fit the 860pt the player
    /// gives the in-image scopes overlay. Nothing else clamps it, so a longer set
    /// of scope names simply clips.
    @Test func scopesChromeFitsTheInPlayerOverlay() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                ScopesPanel(live: probe.controller.live, singleScope: true)
            }
            let overlay = ViewBudget.scopesOverlayWidth
            #expect(ideal.ru.width <= overlay,
                    "the Russian scopes chrome wants \(ideal.ru.width)pt of \(overlay)")
            #expect(ideal.en.width <= overlay)
            #expect(ideal.ru.height > 0)
        }
    }

    /// The separate scopes window opens at 980pt wide; the same chrome plus the
    /// window's close button has to fit that too.
    @Test func scopesWindowChromeFitsItsDefaultSize() async throws {
        try await ViewProbe.run { probe in
            probe.controller.scopesWindowOpen = true
            let ideal = probe.fittingSizes {
                ScopesPanel(live: probe.controller.live, onCloseWindow: {})
            }
            #expect(ideal.ru.width <= 980,
                    "the scopes window chrome wants \(ideal.ru.width)pt of 980")
        }
    }

    /// Squeezed to the panel's declared minimum the chrome takes a second row
    /// rather than clipping, so the layout gets taller and never wider.
    @Test func scopesChromeStacksInsteadOfClippingWhenNarrow() async throws {
        try await ViewProbe.run { probe in
            let narrow = probe.sizes(proposedWidth: 420, proposedHeight: 260) {
                ScopesPanel(live: probe.controller.live)
            }
            #expect(narrow.ru.width == 420,
                    "the scopes panel overflowed its own minimum width")
            #expect(narrow.ru == narrow.en)
        }
    }

    /// The VANC window: an empty state that is a whole localized sentence, and a
    /// table whose column headers are localized inside fixed column widths.
    @Test func vancMonitorRendersEmptyAndPopulated() async throws {
        try await ViewProbe.run { probe in
            let empty = probe.fittingSizes { VancMonitorView() }
            #expect(empty.ru.width == ViewBudget.vancMinWidth)
            #expect(empty.ru == empty.en, "empty VANC state: \(empty)")

            probe.controller.vancStats = ViewFixtures.vancStats
            let table = probe.sizes(proposedWidth: ViewBudget.vancMinWidth,
                                    proposedHeight: 300) { VancMonitorView() }
            #expect(table.ru == table.en, "VANC table: \(table)")
            #expect(table.ru.width == ViewBudget.vancMinWidth)
        }
    }

    /// The table's description column is English for the packet types the app
    /// recognizes (they are SMPTE names) and localized for the ones it doesn't —
    /// that fallback is the string an operator sees for every camera nobody has
    /// written a parser for yet.
    @Test func vancDescriptionsFallBackToTheLocalizedUnknown() async throws {
        try await ViewProbe.run { _ in
            let ru = ViewRender.withLanguage(.russian) {
                VancMonitorView.describe(did: 0x7F, sdid: 0x01)
            }
            let en = ViewRender.withLanguage(.english) {
                VancMonitorView.describe(did: 0x7F, sdid: 0x01)
            }
            #expect(en == "Unknown")
            #expect(ru != en, "the unknown-packet label is not translated")
            #expect(ru != "vanc_unknown", "raw key: the .lproj bundle was missed")

            // a known type stays the SMPTE name in both languages
            let known = ViewRender.withLanguage(.russian) {
                VancMonitorView.describe(did: 0x60, sdid: 0x60)
            }
            #expect(known == "Timecode (RP188/ATC)")
        }
    }

    /// The output-device picker now sits under the volume slider in the channels
    /// panel (owner item 7). Device names come from the machine the suite runs on
    /// and can be any length, so the picker has to live inside the panel's
    /// channel-count width rather than set it — the test above pins the width, this
    /// one pins that the picker itself compresses instead of pushing.
    @Test func theOutputPickerFitsTheNarrowestAudioPanel() async throws {
        try await ViewProbe.run { probe in
            // two channels is the narrowest the panel ever gets: 2 * 30 + 56
            let panelContentWidth: CGFloat = 116
            let laid = probe.sizes(proposedWidth: panelContentWidth) {
                AudioOutputMenu()
            }
            #expect(laid.ru.width <= panelContentWidth,
                    "the output picker wants \(laid.ru.width)pt of \(panelContentWidth)")
            #expect(laid.ru.height == laid.en.height,
                    "the picker took a second line in one language: \(laid)")
            // the fixture has no device selected, so both languages render the
            // "System default" label — which IS localized and must still fit
            #expect(probe.minimumWidths { AudioOutputMenu() }.ru <= panelContentWidth)
        }
    }

    /// The utility strip at the bottom of the takes panel (owner item 48) is three
    /// icon buttons with localized tooltips only: it must measure the same in both
    /// languages and fit the narrowest panel with room to spare.
    @Test func utilityStripFitsTheNarrowestSidePanel() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { TakesPanelUtilityStrip() }
            #expect(ideal.ru == ideal.en,
                    "a localized label reached the utility strip: \(ideal)")
            #expect(ideal.ru.width <= ViewBudget.panelMinWidth,
                    "the strip wants \(ideal.ru.width)pt of \(ViewBudget.panelMinWidth)")
            #expect(ideal.ru.height > 0 && ideal.ru.height <= 40,
                    "the strip is \(ideal.ru.height)pt tall — it is meant to be compact")
        }
    }

    /// The mount modifier puts the strip UNDER whatever it is applied to (the
    /// takes list, or the Other content section when there is one) and takes its
    /// width from the panel, not from the strip.
    @Test func theStripMountsBelowThePanelWithoutWideningIt() async throws {
        try await ViewProbe.run { probe in
            let strip = probe.fittingSizes { TakesPanelUtilityStrip() }
            let content = CGSize(width: ViewBudget.panelMinWidth, height: 120)
            let mounted = probe.fittingSizes {
                Color.clear
                    .frame(width: content.width, height: content.height)
                    .takesPanelUtilityStrip()
            }
            #expect(mounted.en.width == content.width,
                    "the strip widened the panel to \(mounted.en.width)pt")
            #expect(mounted.en.height >= content.height + strip.en.height,
                    "the strip did not mount: \(mounted.en.height)pt")
            #expect(mounted.ru == mounted.en)
        }
    }

    /// Take rows carry the comment and rating controls; both are icon buttons
    /// with localized tooltips only, so they must stay a fixed 18pt square.
    @Test func takeRowControlsAreLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let comment = probe.fittingSizes { CommentButton(take: take) }
            let rating = probe.fittingSizes { RatingToggle(take: take) }
            #expect(comment.en == CGSize(width: 18, height: 18))
            #expect(comment.ru == comment.en)
            #expect(rating.en == CGSize(width: 18, height: 18))
            #expect(rating.ru == rating.en)
        }
    }
}
