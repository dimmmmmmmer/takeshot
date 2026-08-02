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
