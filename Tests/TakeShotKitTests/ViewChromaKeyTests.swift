import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The chroma-key panel as the operator gets it: inside a fixed-width popover,
/// in both languages, with every background mode's extra row on screen.
///
/// The failure this guards against is silent — a Russian label truncating
/// inside a 310pt popover, or a row growing a second line and pushing the
/// warning about the monitor output off the bottom.
@MainActor
struct ViewChromaKeyTests {
    /// Every row the key can put on screen, squeezed into the popover the app
    /// actually opens, in English and in Russian.
    @Test func theChromaRowsFitThePopoverInEveryBackgroundMode() async throws {
        try await ViewProbe.run { probe in
            probe.controller.chromaKeyOn = true
            let box = AssistControlsPanel.contentWidth
            for background in ChromaKey.Background.allCases {
                probe.controller.chromaBackground = background
                let minimum = probe.minimumWidths { ChromaKeyRows() }
                #expect(minimum.ru <= box,
                        "\(background) needs \(minimum.ru)pt of \(box) in Russian")
                #expect(minimum.en <= box,
                        "\(background) needs \(minimum.en)pt of \(box)")
            }
        }
    }

    /// The whole popover, with the key open on top of everything else that can
    /// be open at once — the panel is one column and every row shares its width.
    @Test func theWholeAssistPopoverStillFitsWithTheKeyOpen() async throws {
        try await ViewProbe.run { probe in
            probe.controller.assist.colorTool = .falseColor
            probe.controller.assist.zebraOn = true
            probe.controller.assist.peakingOn = true
            probe.controller.settings.safeAreasOn = true
            probe.controller.chromaKeyOn = true
            probe.controller.chromaBackground = .image

            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "the Russian panel stops at \(minimum.ru)pt, box is \(box)")
            #expect(minimum.en <= box)

            let ideal = probe.fittingSizes { AssistControlsPanel() }
            #expect(ideal.ru.height > ideal.en.height - 1,
                    "a row went missing in Russian: \(ideal)")
        }
    }

    /// Off, the section is one switch; on, it is the whole panel. The rows have
    /// to actually appear — a binding wired to the wrong flag renders the same
    /// switch either way.
    @Test func theRowsAppearOnlyWhenTheKeyIsOn() async throws {
        try await ViewProbe.run { probe in
            let closed = probe.fittingSizes { ChromaKeyRows() }
            probe.controller.chromaKeyOn = true
            let open = probe.fittingSizes { ChromaKeyRows() }
            #expect(open.en.height > closed.en.height + 60,
                    "the key's controls did not open: \(closed) → \(open)")
            #expect(open.ru.height > closed.ru.height + 60)
        }
    }

    /// The line that keeps a keyed monitor from being mistaken for the record
    /// is on screen whenever the key is, and it says so in both languages.
    @Test func theMonitorWarningIsTranslatedAndOnScreen() async throws {
        try await ViewProbe.run { probe in
            for language in [AppLanguage.english, .russian] {
                let text = ViewRender.withLanguage(language) {
                    L("chroma_preview_only")
                }
                #expect(text != "chroma_preview_only",
                        "the warning is missing from \(language)")
                #expect(text.count > 30, "the warning does not say enough: \(text)")
            }
            // and it is inside the section that shows when the key is on
            probe.controller.chromaKeyOn = true
            probe.controller.chromaBackground = .checkerboard
            let withWarning = probe.fittingSizes { ChromaKeyRows() }
            #expect(withWarning.ru.height > 100,
                    "the warning row is not being laid out: \(withWarning)")
        }
    }

    /// The eyedropper's surface is over the picture only while it is armed, and
    /// it must not change the size of what it is over.
    @Test func thePickOverlayIsArmedOnlyOnDemandAndNeverStretchesThePlayer() async throws {
        try await ViewProbe.run { probe in
            let player = CGSize(width: 1280, height: 720)
            let idle = ViewRender.laidOutSize(probe.hosted(ChromaPickOverlay()),
                                              in: player)
            #expect(idle == player)
            #expect(probe.fittingSize(ChromaPickOverlay()) == .zero,
                    "the pick surface is on the picture with nothing armed")

            probe.controller.chromaPickArmed = true
            let armed = ViewRender.laidOutSize(probe.hosted(ChromaPickOverlay()),
                                               in: player)
            #expect(armed == player, "the pick surface stretched the player")
        }
    }

    /// A symbol name that does not resolve renders as nothing at all, silently
    /// — and an eyedropper nobody can see is a feature nobody can find.
    @Test func theEyedropperSymbolResolves() {
        #expect(NSImage(systemSymbolName: "eyedropper",
                        accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: "arrow.counterclockwise",
                        accessibilityDescription: nil) != nil,
                "the plate reset button has no glyph")
    }

    /// No SwiftUI `ColorPicker` anywhere in the key's rows (owner item 30).
    ///
    /// That control opens the system color panel, which takes key away from the
    /// popover, and a popover that loses key dismisses — so picking the screen
    /// color shut the panel every time. The structural check is the only one
    /// that can fail if somebody puts one back: a headless render cannot open a
    /// panel, so the dismissal itself is invisible to a test.
    @Test func theKeysRowsHostNoSystemColorPanel() {
        let rows = String(describing: ChromaKeyRows.Body.self)
        let plate = String(describing: ChromaPlateControls.Body.self)
        // the check can see inside: if a refactor hides the rows behind an
        // opaque wrapper the assertions below go vacuously green, so each one
        // is paired with something that must be visible
        #expect(rows.contains("ChromaColorField"),
                "the chroma rows are no longer introspectable: \(rows)")
        #expect(!rows.contains("ColorPicker"),
                "a ColorPicker is back in the chroma rows: \(rows)")
        // and the plate's source menu is the shared picker (owner item 36)
        #expect(plate.contains("MediaSourceMenuItems"),
                "the plate no longer offers the app's own media: \(plate)")
        #expect(!plate.contains("ColorPicker"))
    }

    /// The color field is the replacement: a swatch and the hex the rest of the
    /// app speaks, both inside the popover.
    @Test func theColorFieldShowsAndTakesAHex() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.chromaKeyOn = true
            controller.setChromaScreen(ChromaKey.blueScreen)
            #expect(controller.chroma.keyColor.hexString == "#0000FF")

            // what the field parses is what the keyer adopts, and nonsense is
            // refused rather than adopted as black
            #expect(ChromaKey.RGB(hex: "#123456") != nil)
            #expect(ChromaKey.RGB(hex: "123456") != nil, "the hash is optional")
            #expect(ChromaKey.RGB(hex: "#12345") == nil)

            let field = probe.fittingSizes {
                ChromaColorField(color: .constant(ChromaKey.greenScreen))
            }
            #expect(field.en == field.ru,
                    "a hex field measured differently by language: \(field)")
            #expect(field.en.width < AssistControlsPanel.contentWidth / 2,
                    "the color field takes half the row on its own")
        }
    }

    /// The plate section — a source menu, a fit picker, a scale and two offsets
    /// (owner item 37) — inside the popover, in both languages, with the app's
    /// own media in the menu.
    @Test func thePlateRowsFitThePopoverWithMediaToOffer() async throws {
        try await ViewProbe.run { probe in
            try ViewFixtures.seedTakes(probe.controller, in: probe.root)
            try ViewFixtures.seedOtherFiles(probe.controller, in: probe.root)
            probe.controller.chromaKeyOn = true
            probe.controller.chromaBackground = .image

            let box = AssistControlsPanel.contentWidth
            let minimum = probe.minimumWidths { AssistControlsPanel() }
            #expect(minimum.ru <= box,
                    "the Russian panel with the plate rows wants \(minimum.ru)pt")
            #expect(minimum.en <= box)

            // the section really is on screen: it is a good deal taller than
            // the checkerboard, which has no rows of its own at all
            let withPlate = probe.fittingSizes { ChromaKeyRows() }
            probe.controller.chromaBackground = .checkerboard
            let without = probe.fittingSizes { ChromaKeyRows() }
            #expect(withPlate.en.height > without.en.height + 80,
                    "the plate rows did not open: \(without) → \(withPlate)")
            #expect(withPlate.ru.height > without.ru.height + 80)
        }
    }

    /// Every label the plate section adds is translated, and none of the fit
    /// options collide in either language.
    @Test func thePlateLabelsAreAllTranslated() {
        let keys = ["chroma_plate_fit", "chroma_plate_scale",
                    "chroma_plate_offset_x", "chroma_plate_offset_y",
                    "chroma_plate_reset", "chroma_choose_file"]
        for language in [AppLanguage.english, .russian] {
            ViewRender.withLanguage(language) {
                for key in keys {
                    #expect(L(key) != key, "\(language) is missing \(key)")
                }
                let fits = ChromaKey.PlateFit.allCases.map { L($0.labelKey) }
                #expect(Set(fits).count == 3, "\(language) fits collide: \(fits)")
                #expect(fits.allSatisfy { !$0.hasPrefix("chroma_plate_fit_") },
                        "\(language) is missing a fit label: \(fits)")
            }
        }
    }

    /// Every background mode has a label, and the four of them are four
    /// different words in both languages.
    @Test func theBackgroundLabelsAreAllTranslated() {
        for language in [AppLanguage.english, .russian] {
            let labels = ViewRender.withLanguage(language) {
                ChromaKey.Background.allCases.map { L($0.labelKey) }
            }
            #expect(Set(labels).count == ChromaKey.Background.allCases.count,
                    "\(language) labels collide: \(labels)")
            #expect(labels.allSatisfy { !$0.hasPrefix("chroma_bg_") },
                    "\(language) is missing a background label: \(labels)")
        }
    }
}
