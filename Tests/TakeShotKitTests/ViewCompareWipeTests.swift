import AppKit
import CaptureCore
import SwiftUI
import Testing

@testable import TakeShotKit

/// The draggable wipe seam, on every surface that draws the player.
///
/// The wipe is composited into the picture upstream, so the seam itself has
/// always travelled everywhere — the main viewer, the fullscreen player and the
/// external display all show it. The HANDLE that moves it was written inline in
/// `PreviewView` and went nowhere: on the two borderless surfaces the operator
/// saw a seam and had nothing to grab, which reads as a broken control rather
/// than as a missing one. All three mount `CompareWipeOverlay` now.
///
/// Measured in pixels rather than by counting mounts, because there is nothing
/// to count: the overlay registers no layer and adds no size. What it does is
/// draw a white line and a white dot over a dark picture, so each surface is
/// rendered and asked what it drew, and where.
@Suite @MainActor struct ViewCompareWipeTests {
    /// 16:9, so an unconstrained aspect-fit box fills it exactly and the seam
    /// at 0.5 belongs at x=360. Wide enough that the transport strip fits its
    /// one row (`ViewBudget.transportWidth` is 714) — squeezed narrower than
    /// that the bar grows upward into the middle of the picture, which is where
    /// the seam is read.
    private static let surface = CGSize(width: 720, height: 405)
    private static let centre = 360

    /// The band the seam is read in: the middle tenth of the picture. Both
    /// player surfaces carry chrome that is bright too — a transport strip
    /// along the bottom, badges along the top — and the handle's dot sits
    /// exactly on the seam's midpoint, which is the one row nothing else uses.
    private static let middle = 0.45...0.55

    private static let surfaces: [(name: String, view: AnyView)] = [
        ("main viewer", AnyView(PreviewView())),
        ("fullscreen player", AnyView(PlaybackFullscreenView())),
        ("external display", AnyView(ExternalOutputView())),
    ]

    /// Put the controller in playback on a clip, with the wipe engaged.
    private func wiping(_ controller: CaptureController, in root: URL,
                        at position: Double = 0.5) {
        controller.playbackURL = root.appendingPathComponent("a.mov")
        controller.viewerMode = .playback
        controller.compareMode = .wipe
        controller.wipePosition = position
    }

    /// Where the seam is, in points: the middle of the bright band, or nil if
    /// the surface drew nothing there at all.
    private func seam(_ probe: ViewProbe, _ view: AnyView) -> Int? {
        let columns = probe.brightColumns(view, in: Self.surface,
                                          rows: Self.middle)
        guard let low = columns.first, let high = columns.last else { return nil }
        return (low + high) / 2
    }

    // MARK: - the decision itself

    /// One property, read by all three surfaces — the same shape as
    /// `showsCompareSplit`, and for the same reason.
    @Test func theHandleIsOneDecisionSharedByEverySurface() async throws {
        try await ControllerHarness.run { controller, root in
            controller.compareMode = .wipe
            controller.viewerMode = .playback
            #expect(!controller.showsWipeHandle, "no clip loaded, no seam")

            controller.playbackURL = root.appendingPathComponent("a.mov")
            #expect(controller.showsWipeHandle)

            // the other compare modes have no seam to drag — difference
            // included: a wipe position through |A−B| means nothing
            for mode in [CaptureController.CompareMode.off, .blend, .difference,
                         .sideBySide] {
                controller.compareMode = mode
                #expect(!controller.showsWipeHandle, "\(mode.rawValue) is not a wipe")
            }

            // live: the wipe divides the signal from a PINNED reference, and
            // without one there is no B side — the seam would divide the
            // picture from itself
            controller.compareMode = .wipe
            controller.viewerMode = .record
            #expect(!controller.showsWipeHandle)
            controller.referencePinned = true
            #expect(controller.showsWipeHandle)
        }
    }

    // MARK: - what each surface draws

    /// Every surface draws the handle, and draws it in the same place. Before
    /// the fix only the first of the three did: the other two showed the
    /// composited seam with nothing on it.
    @Test func everySurfaceDrawsTheDraggableSeam() async throws {
        try await ViewProbe.run { probe in
            for surface in Self.surfaces {
                self.wiping(probe.controller, in: probe.root)

                let seam = self.seam(probe, surface.view)

                #expect(seam != nil,
                        "\(surface.name) drew no handle over its seam")
                #expect(seam.map { abs($0 - Self.centre) <= 6 } == true,
                        "\(surface.name) seam at \(seam ?? -1), expected \(Self.centre)")
            }
        }
    }

    /// All three read one position, so moving it moves the handle on every one
    /// of them — which is what makes a drag on any surface a drag on all of
    /// them, and why the handle needed no per-surface state to be shared.
    @Test func everySurfacePutsTheHandleWhereTheControllerSaysItIs() async throws {
        try await ViewProbe.run { probe in
            for surface in Self.surfaces {
                self.wiping(probe.controller, in: probe.root, at: 0.25)
                let quarter = self.seam(probe, surface.view)
                probe.controller.wipePosition = 0.75
                let threeQuarters = self.seam(probe, surface.view)

                #expect(quarter.map { abs($0 - 180) <= 6 } == true,
                        "\(surface.name) at 0.25: \(quarter ?? -1)")
                #expect(threeQuarters.map { abs($0 - 540) <= 6 } == true,
                        "\(surface.name) at 0.75: \(threeQuarters ?? -1)")
            }
        }
    }

    /// The handle rides the letterboxed picture, not the window.
    ///
    /// A square clip in a 16:9 window is pillarboxed to 405pt of the 720, so
    /// the far-left seam belongs at x=157, not at x=0. A handle laid over the
    /// whole surface would sit off the picture — and the two borderless windows
    /// are whatever shape the display is, so that is their normal case rather
    /// than an edge one.
    @Test func theHandleRidesThePictureRatherThanTheWindow() async throws {
        try await ViewProbe.run { probe in
            // the box is as wide as the surface is tall, centered
            let leftEdge = Int((Self.surface.width - Self.surface.height) / 2)
            for surface in Self.surfaces {
                self.wiping(probe.controller, in: probe.root, at: 0)
                probe.controller.playbackAspect = 1

                let seam = self.seam(probe, surface.view)

                #expect(seam.map { abs($0 - leftEdge) <= 8 } == true,
                        "\(surface.name) seam at \(seam ?? -1), expected \(leftEdge)")
            }
        }
    }

    /// And nothing is drawn when there is no wipe. The overlay is mounted
    /// unconditionally by all three surfaces, so it has to take itself off
    /// screen rather than leave a stray line across an ordinary playback.
    @Test func noWipeMeansNoHandleOnAnySurface() async throws {
        try await ViewProbe.run { probe in
            for surface in Self.surfaces {
                self.wiping(probe.controller, in: probe.root)
                probe.controller.compareMode = .off

                #expect(self.seam(probe, surface.view) == nil,
                        "\(surface.name) drew a seam with the compare off")
            }
        }
    }
}
