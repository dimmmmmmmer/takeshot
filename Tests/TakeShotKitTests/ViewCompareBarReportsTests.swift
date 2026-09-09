import CaptureCore
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// Three reports about the compare bar and the picture's own corner, in one
/// place because they are one pass over the same row.
@Suite @MainActor struct ViewCompareBarReportsTests {
    /// **The difference has no gain picker, and reaches the render at unity.**
    ///
    /// It was ×1/×4/×16/×64, and the owner has now said twice that only the
    /// first is any use to them ("кроме х1 смысла не вижу в них"). Asserted on
    /// the row's source as well as on the render: what was wrong is a CONTROL
    /// being offered, and a control that is gone has no size to measure.
    @Test func theCompareRowOffersNoDifferenceGain() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/CompareControls.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("gainPicker"),
                "the difference gain picker is back in the compare bar")
        #expect(!code.contains("differenceGain"),
                "the compare bar reads a retired setting")
    }

    /// **The two diagonal wipes are two glyphs.**
    ///
    /// The mirrored one was the plain one with `.scaleEffect(x: -1, y: 1)` on
    /// it, and a segmented picker drops that — both rows drew "/" (owner:
    /// "значок другой диагональной шторки показан в ту же сторону что и
    /// первый"). The ink is measured in `MirroredSymbolTests`; what this holds
    /// is that the row uses the flipped IMAGE and not a transform, because a
    /// transform is what silently does nothing here.
    @Test func theMirroredWipeUsesAFlippedImageNotATransform() throws {
        let code = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TakeShotKit/CompareControls.swift"),
            encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("MirroredSymbol.diagonal"),
                "the mirrored wipe does not use the flipped image")
        #expect(!code.contains("scaleEffect"),
                "a picker row is being mirrored with a transform again")
    }

    /// **The pin says which of its two jobs it is about to do.**
    ///
    /// Over a reference that already exists the press REPLACES it — and the
    /// button drew the same hollow glyph and offered the same sentence either
    /// way, so on the playback page it read as a control that could be pressed
    /// twice to no effect (owner: "запиненый реф на странице плейбека снова
    /// можно запинить. путает это").
    @Test func thePinReadsDifferentlyOverAReferenceThatExists() {
        let fresh = ComparePinReading.reading(pinned: false)
        let over = ComparePinReading.reading(pinned: true)
        #expect(fresh.symbol != over.symbol,
                "the pin draws the same glyph whether or not one is pinned")
        #expect(fresh.helpKey != over.helpKey,
                "the pin promises the same thing in both states")
        #expect(over.symbol == "pin.fill")
        // both sentences exist in both languages — a tooltip that renders its
        // own key is worse than none
        for key in [fresh.helpKey, over.helpKey] {
            #expect(L(key) != key, "\(key) has no words")
        }
    }

    /// **A still under review can be put fullscreen.**
    ///
    /// Playback's fullscreen button lives in the transport bar, and a still has
    /// no transport — so a photo had no way to fill the screen at all (owner:
    /// "если в плейбеке включить не видео а фотку то нет кнопки чтобы открыть
    /// ее на фулл скрин"). The corner button appears exactly where nothing
    /// under the picture is already offering one.
    @Test func theCornerFullscreenAppearsForAStillAndNotUnderATransport()
        async throws {
        try await ControllerHarness.run { controller, root in
            // record mode: it has always been there
            #expect(controller.showsCornerFullscreenButton)

            let still = root.appendingPathComponent("reference.png")
            try Data([0x00]).write(to: still)
            controller.viewerMode = .playback
            controller.playbackURL = still
            #expect(controller.transportBarKind == .none,
                    "a still grew a transport bar")
            #expect(controller.showsCornerFullscreenButton,
                    "a still under review still cannot be put fullscreen")

            // a clip carries its own in the transport, so the corner stands down
            let clip = root.appendingPathComponent("A001C001.mov")
            try Data([0x00]).write(to: clip)
            controller.playbackURL = clip
            #expect(controller.transportBarKind == .video)
            #expect(!controller.showsCornerFullscreenButton,
                    "the fullscreen button is offered twice at once")

            // …and a clean feed has no controls at all, still-or-not
            controller.playbackURL = still
            controller.cleanFeed = true
            #expect(!controller.showsCornerFullscreenButton,
                    "a clean feed grew a button")
        }
    }
}
