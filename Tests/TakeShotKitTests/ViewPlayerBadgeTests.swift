import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// Guards the chrome laid over the player: the timecode badge, the centered
/// mode/compare group, the badge row on the right, and the two popovers that
/// hang off it.
///
/// This is where the Russian UI hurt most. The compare bar is a mini segmented
/// control whose four labels are all translated; it is centered between two
/// badge groups that are NOT going to move, and the space between them is about
/// 340pt at the narrowest window. Anything wider used to slide underneath them,
/// because the three groups were three independent corner overlays.
@MainActor
struct ViewPlayerBadgeTests {
    /// The record/playback switch wears NO plate (owner item 1).
    ///
    /// It used to sit on the same dark slab as the badges either side of it,
    /// which under a segmented control — a control that draws its own opaque
    /// chrome — was a second background behind a background. Asserted as width:
    /// the switch is the bare picker and nothing more, so it costs exactly the
    /// control and not the family's 8pt-a-side padding. What it DOES keep is
    /// the family's height, or it stops lining up with the badges beside it.
    @Test func theModeSwitchSitsOnTheChromeWithNoPlate() async throws {
        try await ViewProbe.run { probe in
            let ideal = probe.fittingSizes { ViewerModeSwitch() }
            let bare = probe.fittingSizes {
                Picker("", selection: .constant(CaptureController.ViewerMode.record)) {
                    Text(L("mode_record")).tag(CaptureController.ViewerMode.record)
                    Text(L("mode_playback")).tag(CaptureController.ViewerMode.playback)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            // …and what a plated control of the same content would have cost,
            // so "the plate is gone" fails if the plate comes back
            let plated = probe.fittingSizes {
                Text(verbatim: "x").playerChromePlate()
            }
            for (language, switchSize, control) in [("en", ideal.en, bare.en),
                                                    ("ru", ideal.ru, bare.ru)] {
                #expect(switchSize.width == control.width,
                        "the \(language) switch is \(switchSize.width)pt for a \(control.width)pt control")
                #expect(switchSize.height == PlayerChrome.height,
                        "the \(language) switch is \(switchSize.height)pt tall, the row is \(PlayerChrome.height)")
                #expect(switchSize.width <= ViewBudget.playerCenterWidth)
            }
            #expect(plated.en.width > 2 * PlayerChrome.horizontalPadding,
                    "the plate measurement itself is broken")
        }
    }

    /// The identity row — TC on the left, the mode switch centered, the signal
    /// badges on the right — fits the picture at the narrowest window, in both
    /// languages, whatever the operator has switched on.
    ///
    /// This is the owner's "the timecode and the resolution get pushed apart by
    /// the menu and the playback settings". The compare bar used to share the
    /// centered slot with the mode switch, and every control in it is
    /// `.fixedSize()` — so a bar wider than the slot did not compress, it made
    /// the whole HStack wider than the picture and shoved the badges off both
    /// edges. Nothing in this row grows without a bound any more; the compare
    /// bar has a row of its own (see below).
    @Test func theIdentityRowHoldsItsShapeAtTheNarrowestWindow() async throws {
        try await ViewProbe.run { probe in
            let chrome = ViewBudget.playerChromeWidth
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.referencePinned = true

            for viewer in [CaptureController.ViewerMode.record, .playback] {
                probe.controller.viewerMode = viewer
                for mode in [CaptureController.CompareMode.off, .wipe, .blend] {
                    probe.controller.compareMode = mode
                    let ideal = probe.fittingSizes { PlayerTopBadgeRow() }
                    #expect(ideal.ru.width <= chrome,
                            "\(viewer)/\(mode) row wants \(ideal.ru.width)pt of \(chrome)")
                    #expect(ideal.en.width <= chrome)
                    #expect(ideal.ru.height == ideal.en.height,
                            "\(viewer)/\(mode) row changed height with the language")
                }
            }
        }
    }

    /// The compare bar's budget is now the whole picture rather than the ~340pt
    /// between the badge groups, and it has to stay inside THAT in every mode
    /// and both languages — it cannot compress, so anything over is an overflow
    /// onto the image rather than a squeeze.
    @Test func theCompareBarFitsTheFullPictureInEveryMode() async throws {
        try await ViewProbe.run { probe in
            let chrome = ViewBudget.playerChromeWidth
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.referencePinned = true

            // A clip in the player, because that is the only state the app
            // mounts this bar in during playback — measured without one it
            // collapses to the pin (see `showsCompareBar`) and the budget check
            // passes on a 23pt row that is not the bar under test.
            probe.controller.playbackURL = probe.root
                .appendingPathComponent("a.mov")

            for viewer in [CaptureController.ViewerMode.record, .playback] {
                probe.controller.viewerMode = viewer
                for mode in [CaptureController.CompareMode.off, .wipe,
                             .blend, .difference, .sideBySide] {
                    probe.controller.compareMode = mode
                    #expect(probe.controller.compareHasBSide,
                            "\(viewer)/\(mode): measured with nothing to compare against")
                    let ideal = probe.fittingSizes { CompareControls() }
                    #expect(ideal.ru.width <= chrome,
                            "\(viewer)/\(mode) bar wants \(ideal.ru.width)pt of \(chrome)")
                    #expect(ideal.en.width <= chrome)
                }
            }
        }
    }

    /// In playback the widest segment is "Playback"/"Плейбек" and the bar comes
    /// out byte-for-byte the same size in both languages — which is what a slot
    /// centered between two fixed badge groups needs. "Микс" instead of
    /// "Наложение" for blend is what buys that: a segmented control gives every
    /// segment the width of the LONGEST label, so one long word is charged four
    /// times over.
    @Test func playbackCompareBarIsLocaleIndependent() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.viewerMode = .playback
            probe.controller.playbackURL = probe.root
                .appendingPathComponent("a.mov")

            for mode in [CaptureController.CompareMode.off, .wipe,
                         .blend, .difference, .sideBySide] {
                probe.controller.compareMode = mode
                let ideal = probe.fittingSizes { CompareControls() }
                #expect(ideal.ru == ideal.en,
                        "\(mode) compare bar differs by language: \(ideal)")
            }
        }
    }

    /// Record mode swaps the first segment for "Source"/"Сигнал" and Cyrillic
    /// costs ~5pt per segment there — 25 across the five-segment control. That
    /// is inside the slot, and this pins how much room is left before it is not.
    @Test func recordCompareBarStaysCloseToTheEnglishWidth() async throws {
        try await ViewProbe.run { probe in
            probe.controller.referencePinned = true
            let ideal = probe.fittingSizes { CompareControls() }
            let surcharge = ideal.ru.width - ideal.en.width
            #expect(surcharge >= 0)
            #expect(surcharge <= 30,
                    "Russian costs \(surcharge)pt on the record compare bar")
        }
    }

    /// Engaging difference brings the gain picker into the row — the bar has
    /// to grow, by the same amount in both languages: ×1/×4/×16 are symbols,
    /// not words, so the picker itself owes no translation surcharge.
    @Test func theDifferenceBarBringsItsGainPicker() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.viewerMode = .playback
            probe.controller.playbackURL = probe.root
                .appendingPathComponent("a.mov")

            let resting = probe.fittingSizes { CompareControls() }
            probe.controller.compareMode = .difference
            let engaged = probe.fittingSizes { CompareControls() }

            #expect(engaged.en.width > resting.en.width,
                    "the gain picker never joined the difference bar")
            #expect(engaged.ru == engaged.en,
                    "the difference bar differs by language: \(engaged)")
        }
    }

    /// The badges are an overlay: whatever they contain, they must not change
    /// the size of the player underneath them. A modifier that stretches its
    /// host is how the image starts moving when the language changes.
    @Test func badgeOverlayNeverStretchesThePlayer() async throws {
        try await ViewProbe.run { probe in
            let base = CGSize(width: ViewBudget.playerWidth, height: 380)
            for language in [AppLanguage.english, .russian] {
                let plain = ViewRender.withLanguage(language) {
                    ViewRender.laidOutSize(
                        probe.hosted(Color.clear.playerTopBadges()), in: base)
                }
                #expect(plain == base, "badges stretched the player in \(language)")
            }

            // and again with everything the chrome can show at once
            probe.controller.referencePinned = true
            probe.controller.compareMode = .blend
            probe.controller.assist.colorTool = .falseColor
            probe.controller.settings.assist.framelineRatio = 2.39
            for language in [AppLanguage.english, .russian] {
                let loaded = ViewRender.withLanguage(language) {
                    ViewRender.laidOutSize(
                        probe.hosted(Color.clear.playerTopBadges()), in: base)
                }
                #expect(loaded == base,
                        "loaded badges stretched the player in \(language)")
            }
        }
    }

    /// The fullscreen windows use the same modifier without the mode switch.
    @Test func fullscreenBadgeVariantRenders() async throws {
        try await ViewProbe.run { probe in
            let base = CGSize(width: 1280, height: 720)
            for language in [AppLanguage.english, .russian] {
                let size = ViewRender.withLanguage(language) {
                    ViewRender.laidOutSize(
                        probe.hosted(Color.clear.playerTopBadges(
                            showsModeSwitch: false, autoHide: true)),
                        in: base)
                }
                #expect(size == base)
            }
        }
    }

    // MARK: - one visual family (owner item 10)

    /// The row used to be two design languages side by side: native segmented
    /// controls on a 55%-black slab next to 72%-black plates with a hairline and
    /// their own height. One height is the part a reader sees first, and it is
    /// the part a control added later silently breaks — so every plate in the
    /// chrome is measured against `PlayerChrome.height`, in both languages.
    @Test func everyTopChromePlateSharesOneHeight() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.referencePinned = true

            let plates: [(String, () -> AnyView)] = [
                ("timecode badge", { AnyView(PlayerTimecodeBadge()) }),
                ("mode switch", { AnyView(ViewerModeSwitch()) }),
                ("compare bar", { AnyView(CompareControls()) }),
                ("format badge", { AnyView(PlayerFormatBadge()) }),
                ("icon badge", { AnyView(playerOverlayBadge { AssistMenu() }) }),
            ]
            for (name, make) in plates {
                let ideal = probe.fittingSizes(make)
                #expect(ideal.en.height == PlayerChrome.height,
                        "\(name) is \(ideal.en.height)pt in English")
                #expect(ideal.ru.height == PlayerChrome.height,
                        "\(name) is \(ideal.ru.height)pt in Russian")
            }
        }
    }

    /// The family's darkness is one constant, and the owner asked for it
    /// lightened (item 11: 72% black read as black bars on the picture). The
    /// band pins both directions — a per-badge edit must not creep it back
    /// toward the old darkness, and it must not bleach past what keeps white
    /// text readable over a blown highlight.
    @Test func thePlateFamilyStaysLightenedButReadable() {
        #expect(PlayerChrome.backgroundOpacity <= 0.55,
                "the plates darkened back to \(PlayerChrome.backgroundOpacity)")
        #expect(PlayerChrome.backgroundOpacity >= 0.45,
                "\(PlayerChrome.backgroundOpacity) black cannot carry white text")
    }

    /// The compare bar changes shape as modes are engaged (the wipe picker, the
    /// blend slider and its per-cent field). None of that may push it off the
    /// family's height — a bar that grows mid-shoot moves the mode switch above
    /// it and the whole chrome jumps.
    @Test func theCompareBarKeepsItsHeightInEveryMode() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            probe.controller.viewerMode = .playback
            probe.controller.playbackURL = probe.root
                .appendingPathComponent("a.mov")
            probe.controller.referencePinned = true

            for mode in [CaptureController.CompareMode.off, .wipe,
                         .blend, .difference, .sideBySide] {
                probe.controller.compareMode = mode
                let ideal = probe.fittingSizes { CompareControls() }
                #expect(ideal.en.height == PlayerChrome.height,
                        "\(mode) bar is \(ideal.en.height)pt")
                #expect(ideal.ru.height == ideal.en.height)
            }
        }
    }

    /// The LUT popover is a fixed 240pt box. Its rows are two localized toggles,
    /// a localized intensity label and a menu — they have to fit without being
    /// squeezed, i.e. the ideal width has to be inside the box.
    @Test func lutPopoverRowsFitTheirFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let box = LUTControlsPanel.contentWidth
            let ideal = probe.fittingSizes { LUTControlsPanel() }
            #expect(ideal.ru.width <= box,
                    "the Russian LUT rows want \(ideal.ru.width)pt of \(box)")
            #expect(ideal.en.width <= box)
            #expect(ideal.ru.height > 0)
        }
    }

    /// The assist popover cannot fit its ideal width (the exposure segmented
    /// control alone wants ~245pt in English and 262 in Russian), so what
    /// matters is that it can be SQUEEZED into the popover: a minimum wider than
    /// the box is a clipped first row, which is what a 260pt popover was doing
    /// in both languages.
    @Test func assistPopoverSqueezesIntoItsFixedWidth() async throws {
        try await ViewProbe.run { probe in
            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "the Russian assist rows stop at \(minimum.ru)pt, box is \(box)")
            #expect(minimum.en <= box)
        }
    }

    /// Every assist tool switched on at once: the zebra and peaking sliders and
    /// the punch-in pan hint all appear, and the popover still has to hold them.
    @Test func assistPopoverFitsWithEveryToolOn() async throws {
        try await ViewProbe.run { probe in
            probe.controller.assist.zebraOn = true
            probe.controller.assist.peakingOn = true
            probe.controller.assist.punchIn = 2
            probe.controller.settings.assist.safeAreasOn = true

            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "the expanded Russian assist panel needs \(minimum.ru)pt")

            let ideal = probe.fittingSizes { AssistControlsPanel() }
            #expect(ideal.ru.height > ideal.en.height - 1,
                    "a row went missing in Russian: \(ideal)")
        }
    }

    // The exposure legend used to be measured here as a view. It is not one any
    // more — it is burned into the display frame (`AssistLegend` in
    // CaptureCore), so its size is measured against the SIGNAL in
    // `AssistLegendTests`, and its labels are stop marks that no translation
    // can resize.
}
