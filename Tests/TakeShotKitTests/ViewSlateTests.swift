import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The slate face rendered headless, in both languages. The slate has no width
/// budget to overflow — everything on it scales off the window — so the render
/// pass asserts the two things a size cannot: the face actually draws its
/// readout, and the sync flash actually whites it out.
@MainActor
struct ViewSlateTests {
    private static let windowSize = CGSize(width: 960, height: 540)

    private func seed(_ probe: ViewProbe) {
        probe.controller.settings.naming.projectName = "MARS"
        probe.controller.live.currentTimecode = Timecode(
            hours: 10, minutes: 20, seconds: 30, frames: 12, fps: 25)
    }

    private func slate(_ probe: ViewProbe) -> SlateView {
        SlateView(model: probe.controller.slate, live: probe.controller.live)
    }

    /// The face fills exactly the window it is given — an overlay-style view
    /// that stretched its host would fight the fullscreen it exists for.
    @Test func theFaceLaysOutAtTheWindowSizeInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            seed(probe)
            let laid = ViewRender.bothLanguages({
                ViewRender.laidOutSize($0, in: Self.windowSize)
            }, { probe.hosted(slate(probe)) })
            #expect(laid.en == Self.windowSize)
            #expect(laid.ru == Self.windowSize)
        }
    }

    /// The readout and the card draw something bright on the near-black face
    /// in both languages — a size cannot say whether the TC rendered at all.
    @Test func theReadoutActuallyDrawsInBothLanguages() async throws {
        try await ViewProbe.run { probe in
            seed(probe)
            for language in [AppLanguage.english, .russian] {
                let columns = ViewRender.withLanguage(language) {
                    probe.brightColumns(slate(probe), in: Self.windowSize,
                                        rows: 0.2...0.8)
                }
                #expect(!columns.isEmpty,
                        "nothing bright on the face in \(language.rawValue)")
            }
        }
    }

    /// The sync flash is a real white-out of the whole face, not a state flag:
    /// rasterized dark before, near-white while the flash is up.
    @Test func theSyncFlashWhitesTheFaceOut() async throws {
        try await ViewProbe.run { probe in
            seed(probe)
            let size = CGSize(width: 480, height: 270)
            let model = probe.controller.slate
            let dark = ViewRender.meanBrightness(probe.hosted(slate(probe)),
                                                 in: size)
            // park both holds out of reach so the rasterization below cannot
            // race the flash dropping on a slow machine
            model.flashHold = .seconds(600)
            model.freezeHold = .seconds(600)
            model.fireSync()
            let lit = ViewRender.meanBrightness(probe.hosted(slate(probe)),
                                                in: size)

            #expect(dark < 0.3, "the idle face is not dark: \(dark)")
            #expect(lit > 0.85, "the flash did not white the face out: \(lit)")
        }
    }
}
