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

/// Owner item 44: the two margins of a takes-panel section header.
///
/// The title starts on the content margin and the list/tile pickers have to
/// finish on the same one. They did not look like it, and the gap was inside
/// the picker's own box — a segmented control pinned to the slider's 70pt
/// frame is centered in it, so a seventh of its box was empty on each side.
///
/// Its own suite because the two tests below share one subject and one trap.
/// Both used to read the answer out of a bitmap, and half of what they read
/// was the host's: AppKit does not draw a segmented control to the edges of
/// its bounds before macOS 26, and only the selected segment is bright enough
/// to register at all. What is measured here is layout — sizes, and the ink of
/// a filled rectangle, which is the same on every machine. The ink comparisons
/// that genuinely cannot be are kept, behind
/// `ViewRender.controlInkFillsItsBounds`.
@MainActor
struct PanelHeaderMarginTests {
    /// Both sections share the list/grid toggle: two icons in a segmented
    /// control, so no translation may resize it — and it hugs them, because a
    /// control smaller than its frame is centered in it and the empty half of
    /// that frame is what made the header look lopsided.
    @Test func viewModePickerHugsItsIconsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes {
                ViewModePicker(mode: .constant("list"))
            }
            #expect(ideal.ru == ideal.en,
                    "the icon toggle changed size with the language: \(ideal)")
            // 70 is the SLIDER's width, which is where the picker's frame was
            // copied from and what item 44 was; the picker itself is 42.
            #expect(ideal.en.width > 0 && ideal.en.width < 70,
                    "the picker is \(ideal.en.width)pt — it is padding again")
            // …and that width is its own content's, not a frame's: offered a
            // whole panel it takes none of it, squeezed to a point it gives
            // none of it back. Layout, so it holds on any host.
            let offered = probe.size(ViewModePicker(mode: .constant("list")),
                                     proposedWidth: ViewBudget.panelMinWidth)
            let squeezed = probe.size(ViewModePicker(mode: .constant("list")),
                                      proposedWidth: 1)
            #expect(offered.width == ideal.en.width,
                    "the picker stretched to \(offered.width) when offered room")
            #expect(squeezed.width == ideal.en.width,
                    "the picker compressed to \(squeezed.width)")
            // and the drawing fills the frame: whatever slack is left inside it
            // reappears as the asymmetry item 44 reported. Ink off an AppKit
            // control, so it is a fact about the host's drawing and not about
            // this layout — the widths above are the portable half of it.
            guard ViewRender.controlInkFillsItsBounds else { return }
            let ink = try #require(ViewRender.drawnBounds(
                probe.hosted(ViewModePicker(mode: .constant("list"))),
                in: CGSize(width: ideal.en.width, height: 24)))
            #expect(ink.minX <= 0.5 && ink.maxX >= ideal.en.width - 0.5,
                    "the picker draws \(ink) inside a \(ideal.en.width)pt box")
        }
    }

    /// The pickers finish as close to the panel's right edge as the section
    /// title starts from its left.
    ///
    /// Both margins are measured, neither is read off the source. The LEADING
    /// one comes off ink, and portably: the leading view here is a filled
    /// rectangle, which rasterizes to exactly its frame on any host, where a
    /// glyph's ink starts a fraction inside its own box and a segmented
    /// control's ink is whatever that release of AppKit felt like drawing.
    /// The TRAILING one is derived from sizes, which are portable too —
    /// squeezed to its minimum the header is
    ///
    ///     margin | block | 10 | 4 | 10 | controls | margin
    ///
    /// (`PanelSectionHeader`'s `HStack(spacing: 10)` and its `Spacer`), and
    /// every term but the last is measured, so the last one falls out. Those
    /// are the same two numbers the ink version compared — 10 and 10, exactly,
    /// in both modes — without asking the host to draw a control to the edge
    /// of its bounds.
    @Test func theSectionHeaderInsetsAreSymmetric() async throws {
        try await ViewProbe.run { probe in
            let width = ViewBudget.panelMinWidth
            let block = CGSize(width: 40, height: 12)
            // the spacings PanelSectionHeader puts between its three children
            let inner: CGFloat = 10 + 4 + 10
            @MainActor func header(_ mode: String) -> some View {
                PanelSectionHeader(viewMode: .constant(mode),
                                   tileSize: .constant(150)) {
                    Color.white.frame(width: block.width, height: block.height)
                }
            }
            for mode in ["list", "grid"] {
                let box = try #require(
                    ViewRender.drawnBounds(probe.hosted(header(mode)),
                                           in: CGSize(width: width, height: 28)),
                    "the \(mode) header drew nothing")
                let leading = box.minX
                let controls = probe.fittingSize(
                    HStack(spacing: 10) {
                        PanelViewControls(viewMode: .constant(mode),
                                          tileSize: .constant(150))
                    })
                let minimum = probe.size(header(mode), proposedWidth: 1,
                                         proposedHeight: 28).width
                let trailing = minimum - leading - block.width - inner
                    - controls.width
                #expect(abs(leading - trailing) <= 0.5,
                        "\(mode) header: \(leading)pt left, \(trailing)pt right")
                #expect(abs(leading - PanelChrome.contentMargin) <= 0.5,
                        "\(mode) header sits \(leading)pt in, margin is \(PanelChrome.contentMargin)")

                // …and on a host that draws a control to its own bounds, that
                // same trailing margin is there to be read straight off the
                // ink: the statement above, without the arithmetic
                guard ViewRender.controlInkFillsItsBounds else { continue }
                let inked = width - box.maxX
                #expect(abs(leading - inked) <= 0.5,
                        "\(mode) header ink: \(leading)pt left, \(inked)pt right")
                #expect(abs(inked - PanelChrome.contentMargin) <= 0.5,
                        "\(mode) header ends \(inked)pt in, margin \(PanelChrome.contentMargin)")
            }
        }
    }
}
