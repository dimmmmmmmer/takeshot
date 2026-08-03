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

    /// The offload status is the one free-text string in this panel. It used to
    /// be a single line in the takes header; since the sheet learned to close
    /// over a live run (owner item 16) it is a whole readout — a status line, a
    /// percentage, a bar, the file in flight and Stop — at the bottom of the
    /// panel, which is where it stays with every sheet closed (owner item 2).
    /// This measures the panel as the operator gets it; `ViewOffloadTests`
    /// measures the readout on its own. Neither the status nor the file name
    /// may widen the panel — they truncate.
    @Test func offloadStatusDoesNotWidenTheTakesPanel() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let quiet = probe.minimumWidths(proposedHeight: 600) {
                TakeListView()
            }
            probe.controller.offload.isRunning = true
            probe.controller.offload.progress = OffloadProgress(
                filesTotal: 128, bytesTotal: 64_000_000_000,
                currentFile: "DCIM/100MEDIA/A001C042_240730_R1AB.mov",
                destinations: [], elapsed: 48.5, isCancelling: false)
            probe.controller.offloadStatus = ViewRender.withLanguage(.russian) {
                L("offload_progress", 41, 128)
            }
            let busy = probe.minimumWidths(proposedHeight: 600) {
                TakeListView()
            }
            #expect(busy.ru <= max(quiet.ru, ViewBudget.panelMinWidth),
                    "the offload status pushed the panel to \(busy.ru)pt")
            #expect(busy.en <= max(quiet.en, ViewBudget.panelMinWidth))
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

    /// Both sections share the list/grid toggle: two icons in a segmented
    /// control, so no translation may resize it — and it hugs them, because a
    /// control smaller than its frame is centered in it and the empty half of
    /// that frame is what made the header look lopsided (owner item 44).
    @Test func viewModePickerHugsItsIconsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                ViewModePicker(mode: .constant("list"))
            }
            #expect(ideal.ru == ideal.en,
                    "the icon toggle changed size with the language: \(ideal)")
            #expect(ideal.en.width > 0 && ideal.en.width < 70,
                    "the picker is \(ideal.en.width)pt — it is padding again")
            // and the drawing fills the frame: whatever slack is left inside it
            // reappears as the asymmetry item 44 reported
            let ink = try #require(ViewRender.drawnBounds(
                probe.hosted(ViewModePicker(mode: .constant("list"))),
                in: CGSize(width: ideal.en.width, height: 24)))
            #expect(ink.minX <= 0.5 && ink.maxX >= ideal.en.width - 0.5,
                    "the picker draws \(ink) inside a \(ideal.en.width)pt box")
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
                ScopesPanel(scopes: probe.controller.scopes, singleScope: true)
            }
            let overlay = ViewBudget.scopesOverlayWidth
            #expect(ideal.ru.width <= overlay,
                    "the Russian scopes chrome wants \(ideal.ru.width)pt of \(overlay)")
            #expect(ideal.en.width <= overlay)
            #expect(ideal.ru.height > 0)
        }
    }

    /// The separate scopes window opens at 980pt wide; the same chrome has to
    /// fit that too. It carries no close button of its own — the window's title
    /// bar has one — so this is the chrome minus the overlay's X.
    @Test func scopesWindowChromeFitsItsDefaultSize() async throws {
        try await ViewProbe.run { probe in
            probe.controller.scopesWindowOpen = true
            let ideal = probe.fittingSizes {
                ScopesPanel(scopes: probe.controller.scopes)
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
                ScopesPanel(scopes: probe.controller.scopes)
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

    /// Settings, the VANC monitor and the offload are three icons on the
    /// window's top chrome now (owner item 2), and that band is only as tall as
    /// the traffic lights beside it. They carry localized TOOLTIPS and nothing
    /// else, so no translation may resize them, and the row has to fit inside
    /// `windowTopInset` without pushing the player down.
    @Test func theUtilityButtonsFitTheWindowsTopChromeBand() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { WindowUtilityButtons() }
            #expect(ideal.ru == ideal.en,
                    "a localized label reached the utility buttons: \(ideal)")
            let band = probe.controller.windowTopInset
            #expect(ideal.en.height <= band,
                    "the buttons are \(ideal.en.height)pt tall, the band is \(band)")
            #expect(ideal.en.width > 0)
        }
    }

    /// They are on the MAIN COLUMN, not in the takes panel: the panel is where
    /// they used to be, in a plate of their own, and that plate is what owner
    /// item 2 asked to be rid of. With nothing running the panel must therefore
    /// be exactly the sections — no strip, no readout, no extra height.
    @Test func anIdlePanelCarriesNoUtilityBlockAtAll() async throws {
        try await ViewProbe.run { probe in
            let idle = probe.fittingSizes { PanelRunStatus() }
            #expect(idle.en == .zero,
                    "the idle panel still pays for a status block: \(idle.en)")
            #expect(idle.ru == idle.en)

            // …and a running job puts a readout there without widening it
            probe.controller.offloadStatus = "copying"
            let busy = probe.minimumWidths(proposedHeight: 200) { PanelRunStatus() }
            #expect(busy.ru <= ViewBudget.panelMinWidth,
                    "the running readout wants \(busy.ru)pt of \(ViewBudget.panelMinWidth)")
            #expect(probe.fittingSizes { PanelRunStatus() }.en.height > 0,
                    "the readout did not render at all")
        }
    }

    /// Owner item 44: the list/tile pickers have to finish as close to the
    /// panel's right edge as the section title starts from its left.
    ///
    /// Both are on the same 10pt margin and it still looked lopsided, which is
    /// why this measures INK rather than frames: a title's frame is its glyphs,
    /// a segmented control's is not — AppKit draws the cell inset inside its
    /// bounds to leave room for a focus ring, and that inset is the whole
    /// asymmetry. Rasterized and read back, so the compensating constant cannot
    /// drift away from what the control actually renders as.
    @Test func theSectionHeaderInsetsAreSymmetric() async throws {
        try await ViewProbe.run { probe in
            let width = ViewBudget.panelMinWidth
            for mode in ["list", "grid"] {
                let header = probe.hosted(
                    PanelSectionHeader(viewMode: .constant(mode),
                                       tileSize: .constant(150)) {
                        Text(L("other_content"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    })
                let box = try #require(
                    ViewRender.drawnBounds(header,
                                           in: CGSize(width: width, height: 28)),
                    "the \(mode) header drew nothing")
                let leading = box.minX
                let trailing = width - box.maxX
                #expect(abs(leading - trailing) <= 0.5,
                        "\(mode) header: \(leading)pt left, \(trailing)pt right")
                #expect(abs(leading - PanelChrome.contentMargin) <= 0.5,
                        "\(mode) header sits \(leading)pt in, margin is \(PanelChrome.contentMargin)")
            }
        }
    }

    /// Take rows carry the comment and rating controls; both are icon buttons
    /// with localized tooltips only, so they must stay a fixed 18pt square.
    @Test func takeRowControlsAreLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            let takes = try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            let take = try #require(takes.first)
            let comment = probe.fittingSizes { TakeLogButton(take: take) }
            let rating = probe.fittingSizes { RatingToggle(take: take) }
            #expect(comment.en == CGSize(width: 18, height: 18))
            #expect(comment.ru == comment.en)
            #expect(rating.en == CGSize(width: 18, height: 18))
            #expect(rating.ru == rating.en)
        }
    }
}
