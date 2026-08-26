import AppKit
import CaptureCore
import CoreVideo
import Foundation
import SwiftUI
import Testing

@testable import TakeShotKit

/// A/B compare on every surface that shows the player, not just the main one.
///
/// The split used to be written inline in `PreviewView`, so the borderless
/// fullscreen player and the external-display window both rendered
/// `PlaybackContent()` — the take under review, alone. With A/B engaged the
/// operator's window showed two pictures and the director's monitor showed one,
/// which reads as "the compare is off" on the surface the client is watching.
/// All three mount `ComparePlaybackSplit` now.
///
/// Two levels, because the failure has two halves. Mount level: does the window
/// build an A pane at all — its OWN layer, per the preview display rule.
/// Pixel level: is that pane fed the compare clip rather than nothing, on real
/// decoded frames at grey levels far enough apart that a wrong picture cannot
/// pass as a right one.
@Suite @MainActor struct ViewCompareSplitTests {
    /// The reviewed take (dark) and the compare source (near-white). 0x20 vs
    /// 0xE0 with a mid-grey live signal between them: three levels, so "A is
    /// still on the camera" and "A is showing the clip" cannot be confused.
    private static let reviewedLevel: UInt8 = 0x20
    private static let compareLevel: UInt8 = 0xE0

    /// A controller in playback on a real clip, with a second clip chosen as
    /// the compare source and the mode set. Returns the scratch media directory
    /// the caller removes.
    private func loadCompare(_ controller: CaptureController, in root: URL,
                             mode: CaptureController.CompareMode) async throws -> URL {
        let media = try MediaFixtures.makeDirectory("compare-split")
        let reviewed = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("reviewed.mov"), frames: 60,
            level: Self.reviewedLevel)
        let source = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("source.mov"), frames: 60,
            level: Self.compareLevel)
        MediaFixtures.silence(controller)
        controller.play(url: reviewed)
        controller.compareClipURL = source
        controller.compareMode = mode
        return media
    }

    // MARK: - the decision itself

    /// One property, read by all three surfaces. They each carried their own
    /// copy of the condition and two of them simply did not have it.
    @Test func theSplitIsOneDecisionSharedByEverySurface() async throws {
        try await ControllerHarness.run { controller, root in
            controller.compareMode = .sideBySide
            #expect(!controller.showsCompareSplit, "no clip loaded, no split")

            controller.playbackURL = root.appendingPathComponent("a.mov")
            controller.viewerMode = .playback
            #expect(controller.showsCompareSplit)

            // the other compare modes are composited into one picture
            for mode in [CaptureController.CompareMode.off, .wipe, .blend,
                         .difference] {
                controller.compareMode = mode
                #expect(!controller.showsCompareSplit,
                        "\(mode.rawValue) is not a split")
            }

            // …and the live signal is never split against itself
            controller.compareMode = .sideBySide
            controller.viewerMode = .record
            #expect(!controller.showsCompareSplit)
        }
    }

    // MARK: - mount level

    /// The fullscreen player builds the A pane. Before the fix it mounted
    /// `PlaybackContent()` alone: one sink, no compare sink, one picture.
    @Test func theFullscreenPlayerMountsTheAPane() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.playbackURL = probe.root.appendingPathComponent("a.mov")
            controller.compareClipURL = probe.root.appendingPathComponent("b.mov")
            controller.viewerMode = .playback
            controller.compareMode = .sideBySide

            await probe.mounted(PlaybackFullscreenView()) {
                #expect(controller.playbackTap.compareSinks.all().count == 1,
                        "the fullscreen player is showing only the B side")
                #expect(controller.playbackTap.sinks.all().count == 1,
                        "the fullscreen player lost the take under review")
            }
        }
    }

    /// Same for the external display — the director's monitor is the surface
    /// the A/B is being performed for.
    @Test func theExternalDisplayMountsTheAPane() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.playbackURL = probe.root.appendingPathComponent("a.mov")
            controller.compareClipURL = probe.root.appendingPathComponent("b.mov")
            controller.viewerMode = .playback
            controller.compareMode = .sideBySide

            await probe.mounted(ExternalOutputView()) {
                #expect(controller.playbackTap.compareSinks.all().count == 1,
                        "the external display is showing only the B side")
                #expect(controller.playbackTap.sinks.all().count == 1)
            }
        }
    }

    /// The preview display rule: a CALayer lives in ONE NSView, so three
    /// surfaces showing the same split need three pairs of layers. Sharing one
    /// does not fail loudly — the layer is stolen by whichever view laid out
    /// last and the other windows go black or draw with the thief's geometry.
    @Test func eachSurfaceGetsItsOwnPairOfLayers() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.playbackURL = probe.root.appendingPathComponent("a.mov")
            controller.compareClipURL = probe.root.appendingPathComponent("b.mov")
            controller.viewerMode = .playback
            controller.compareMode = .sideBySide
            let tap = controller.playbackTap

            await probe.mounted(PreviewView()) {
                await probe.mounted(PlaybackFullscreenView()) {
                    await probe.mounted(ExternalOutputView()) {
                        let panes = tap.compareSinks.all()
                        let reviewed = tap.sinks.all()
                        #expect(panes.count == 3, "A panes: \(panes.count)")
                        #expect(reviewed.count == 3,
                                "B panes: \(reviewed.count)")
                        let identities = Set((panes + reviewed)
                            .map(ObjectIdentifier.init))
                        #expect(identities.count == 6,
                                "two mounts are sharing one layer")
                    }
                }
            }
        }
    }

    /// Wipe, blend and difference are composited inside the tap and arrive as
    /// one picture, so those two surfaces needed no split — and must not grow
    /// one. A compare sink here would put the B clip on screen a second time,
    /// uncomposited.
    @Test func theCompositedCompareModesMountNoSecondPane() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            controller.playbackURL = probe.root.appendingPathComponent("a.mov")
            controller.compareClipURL = probe.root.appendingPathComponent("b.mov")
            controller.viewerMode = .playback
            let tap = controller.playbackTap

            // Counted as a DELTA, not a total: a host this harness lets go of
            // is drained by the autorelease pool at a moment of AppKit's
            // choosing, so an earlier iteration's layer may still be in the
            // weak registry. What the surface itself added is the assertion.
            for mode in [CaptureController.CompareMode.wipe, .blend,
                         .difference] {
                controller.compareMode = mode
                for surface in [AnyView(PlaybackFullscreenView()),
                                AnyView(ExternalOutputView())] {
                    let panes = tap.compareSinks.all().count
                    let pictures = tap.sinks.all().count
                    await probe.mounted(surface) {
                        #expect(tap.compareSinks.all().count == panes,
                                "\(mode.rawValue) grew a second, uncomposited pane")
                        #expect(tap.sinks.all().count == pictures + 1,
                                "\(mode.rawValue) lost the composited picture")
                    }
                }
            }
        }
    }

    // MARK: - pixel level

    /// The fullscreen player, on its own, is fed both pictures.
    ///
    /// "On its own" is the whole point: the A pane exists because THIS window
    /// mounted one, not because the main window happens to be open behind it.
    /// Nothing pulls the compare clip until some surface asks for it — the split
    /// turns the composite off — so before the fix a fullscreen player was the
    /// only thing on screen and the compare source was never decoded at all.
    @Test func theFullscreenPlayerIsFedBothSidesOfTheSplit() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let media = try await loadCompare(controller, in: probe.root,
                                              mode: .sideBySide)
            defer {
                MediaFixtures.stopPlayback(controller)
                try? FileManager.default.removeItem(at: media)
            }
            let tap = controller.playbackTap

            try await probe.mounted(PlaybackFullscreenView()) {
                let fed = await ControllerWait.untilWritten {
                    guard let side = tap.compareSideBuffer() else { return false }
                    return MediaFixtures.sample(side, atFractionX: 0.5).r > 0xB0
                }
                let side = try #require(
                    tap.compareSideBuffer(),
                    "the fullscreen player's A pane was never fed anything")
                let pane = MediaFixtures.sample(side, atFractionX: 0.5)
                #expect(fed, "the A pane is not the compare clip: \(pane.description)")

                let reviewed = try #require(tap.currentBuffer())
                let bside = MediaFixtures.sample(reviewed, atFractionX: 0.5)
                #expect(bside.r < 0x60,
                        "the B pane is not the take under review: \(bside.description)")
            }
        }
    }

    /// The same on the external display.
    @Test func theExternalDisplayIsFedBothSidesOfTheSplit() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let media = try await loadCompare(controller, in: probe.root,
                                              mode: .sideBySide)
            defer {
                MediaFixtures.stopPlayback(controller)
                try? FileManager.default.removeItem(at: media)
            }
            let tap = controller.playbackTap

            try await probe.mounted(ExternalOutputView()) {
                let fed = await ControllerWait.untilWritten {
                    guard let side = tap.compareSideBuffer() else { return false }
                    return MediaFixtures.sample(side, atFractionX: 0.5).r > 0xB0
                }
                let side = try #require(
                    tap.compareSideBuffer(),
                    "the external display's A pane was never fed anything")
                let pane = MediaFixtures.sample(side, atFractionX: 0.5)
                #expect(fed, "the A pane is not the compare clip: \(pane.description)")
            }
        }
    }

    /// Wipe on those two surfaces, on decoded frames: the picture they are
    /// handed is the composite, both clips already in it. They mount the tap's
    /// main sink, and `deliver` hands that registry the same buffer the mirror
    /// handler gets — which is what this reads.
    @Test func theCompositedWipeReachesTheFullscreenAndExternalSurfaces() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let media = try await loadCompare(controller, in: probe.root,
                                              mode: .wipe)
            defer {
                MediaFixtures.stopPlayback(controller)
                try? FileManager.default.removeItem(at: media)
            }
            let tap = controller.playbackTap
            let collector = MediaFixtures.FrameCollector()
            tap.setOnDisplayFrame { collector.record($0[.decorated]) }
            defer { tap.setOnDisplayFrame(nil) }

            try await probe.mounted(PlaybackFullscreenView()) {
                try await probe.mounted(ExternalOutputView()) {
                    #expect(tap.sinks.all().count == 2,
                            "a composited surface is not a sink of the tap")
                    let composed = await ControllerWait.untilWritten {
                        guard let frame = collector.last else { return false }
                        return MediaFixtures.sample(frame, atFractionX: 0.9).r > 0xB0
                    }
                    let frame = try #require(collector.last)
                    let left = MediaFixtures.sample(frame, atFractionX: 0.1)
                    let right = MediaFixtures.sample(frame, atFractionX: 0.9)
                    #expect(composed,
                            "the compare clip never reached the wipe: \(right.description)")
                    #expect(left.r < 0x60,
                            "left of the seam is not the reviewed take: \(left.description)")
                }
            }
        }
    }

    /// What the DeckLink monitor shows with A/B engaged, stated rather than
    /// assumed.
    ///
    /// `wireDisplayMirrors` feeds the hardware output ONE composed buffer per
    /// frame, and a physical monitor cannot mount two SwiftUI panes. In
    /// sideBySide the tap's composite is off, so that buffer is the take under
    /// review — the B side, uncomposited, across the whole raster. Deliberately
    /// left that way: compositing a split for playout alone means a second
    /// full-frame CoreImage pass per frame on the tap queue, feeding a picture
    /// no on-screen surface shows, and the tap queue is the one that must not
    /// stall. Wipe and blend mirror correctly because they ARE that one buffer.
    /// If this ever needs to change, the honest alternative is showing the wipe
    /// on the hardware output while the screens show the split.
    @Test func theHardwareMirrorCarriesTheBSideWhileTheSplitIsOnScreen() async throws {
        try await ViewProbe.run { probe in
            let controller = probe.controller
            let media = try await loadCompare(controller, in: probe.root,
                                              mode: .sideBySide)
            defer {
                MediaFixtures.stopPlayback(controller)
                try? FileManager.default.removeItem(at: media)
            }
            let tap = controller.playbackTap
            let collector = MediaFixtures.FrameCollector()
            // what rebuildPlayout wires up when a DeckLink output is chosen
            tap.setOnDisplayFrame { collector.record($0[.decorated]) }
            defer { tap.setOnDisplayFrame(nil) }

            try await probe.mounted(PlaybackFullscreenView()) {
                let mirrored = await ControllerWait.untilWritten {
                    collector.count > 0
                }
                #expect(mirrored, "nothing ever reached the hardware mirror")
                let frame = try #require(collector.last)
                for fraction in [0.1, 0.5, 0.9] {
                    let pixel = MediaFixtures.sample(frame, atFractionX: fraction)
                    #expect(pixel.r < 0x60,
                            """
                            the mirror at \(fraction) is not the reviewed take: \
                            \(pixel.description)
                            """)
                }
            }
        }
    }
}
