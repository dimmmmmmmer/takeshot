import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Markers on clips that are NOT takes (owner item 24).
///
/// The marker controls live in the transport and the transport runs for
/// whatever is loaded, so the operator can reach them on a clip that came off a
/// card — and pressing the flag on one used to answer with an error toast. The
/// sidecar beside the footage is keyed by file name, which is what makes the
/// second store possible; what regresses here is the routing between the two
/// stores, the refusals that are still right, and the clip's own zero being the
/// timebase its markers are measured from.
///
/// Its own suite rather than more of `ControllerMarkersTests`: that one is
/// about the two ways a marker is PLACED, this one is about which store owns it.
@Suite @MainActor struct ControllerOtherMarkersTests {
    /// A foreign clip in the record folder, loaded in the player. Nothing writes
    /// a real movie: the marker paths never decode one, and the position comes
    /// from a player holding no item — which is a playhead at zero.
    @discardableResult
    private func loadForeignClip(_ controller: CaptureController, in root: URL,
                                 named name: String = "A003_C012.mov")
        throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        controller.otherFiles = [url]
        controller.viewerMode = .playback
        controller.playbackURL = url
        controller.playbackFPS = 25
        return url
    }

    /// A clip that landed in the record folder from a card is still a clip
    /// somebody wants to flag a moment in, and the marker controls are in the
    /// transport, which runs for it. It used to answer with an error toast.
    @Test func aClipInOtherContentCarriesMarkers() async throws {
        try await ControllerHarness.run { controller, root in
            try loadForeignClip(controller, in: root)

            controller.addMarker()

            #expect(controller.lastError == nil)
            #expect(controller.playbackMarkers.count == 1)
            #expect(controller.otherMarkers["A003_C012.mov"]?.count == 1)
            // Its position is an OFFSET from the clip's own zero, not the
            // camera timecode the player badge may be showing: the sidecar has
            // no anchor to store for a clip that is not a take, so a marker
            // that read "10:00:00:00" today would read back as ten hours past
            // the end of it tomorrow.
            #expect(controller.playbackMarkers.first?.timecodeText
                    == "00:00:00:00")
            // and it goes nowhere near the takes
            #expect(controller.takes.isEmpty)
        }
    }

    /// The list editor drives the same store: recolour, annotate, delete and
    /// clear all have to reach a foreign clip's markers the way they reach a
    /// take's, or the popover is a read-only list for half the panel.
    @Test func theEditorReachesTheMarkersOfAForeignClip() async throws {
        try await ControllerHarness.run { controller, root in
            try loadForeignClip(controller, in: root)
            controller.otherMarkers["A003_C012.mov"] = [
                TakeMarker(seconds: 1), TakeMarker(seconds: 3),
            ]

            controller.updatePlaybackMarker(at: 1) { $0.note = "flare" }
            #expect(controller.playbackMarkers[1].note == "flare")

            // an index the list no longer has must not trap
            controller.updatePlaybackMarker(at: 9) { $0.note = "nope" }
            controller.removePlaybackMarker(at: 9)
            #expect(controller.playbackMarkers.count == 2)

            controller.removePlaybackMarker(at: 0)
            #expect(controller.playbackMarkers.map(\.note) == ["flare"])

            controller.clearPlaybackMarkers()
            #expect(controller.playbackMarkers.isEmpty)
            // cleared is not the same as never marked: the key stays, empty, so
            // the next folder scan cannot restore what was just deleted
            #expect(controller.otherMarkers["A003_C012.mov"]?.isEmpty == true)
        }
    }

    /// One marker per frame applies to a foreign clip too — the hotkey repeats
    /// while held, whatever is loaded.
    @Test func aForeignClipAlsoTakesOneMarkerPerFrame() async throws {
        try await ControllerHarness.run { controller, root in
            try loadForeignClip(controller, in: root)

            controller.addMarker()
            controller.addMarker()
            controller.addMarker()

            #expect(controller.otherMarkers["A003_C012.mov"]?.count == 1)
        }
    }

    /// A photo has one frame, so a marker on it would be a rating with extra
    /// steps; and a clip from outside the record folder would file its markers
    /// under a bare file name that means something else in that folder. Both
    /// refuse, and say so — the hotkey reaches them even where the transport
    /// bar (and with it the marker button) is not drawn.
    @Test func markingRefusesAPhotoAndAClipFromElsewhere() async throws {
        try await ControllerHarness.run { controller, root in
            let photo = try loadForeignClip(controller, in: root,
                                            named: "reference.png")
            #expect(controller.playbackURL == photo)

            controller.addMarker()
            #expect(controller.lastError == L("marker_needs_clip"))
            #expect(controller.playbackMarkers.isEmpty)

            controller.lastError = nil
            controller.playbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("somewhere_else.mov")
            controller.addMarker()
            #expect(controller.lastError == L("marker_needs_clip"))
            #expect(controller.otherMarkers.isEmpty)
        }
    }

    /// Trashing a foreign clip takes its markers with it — the same as its
    /// in/out points. A file merely leaving the folder is a different case and
    /// keeps them, like a retired take keeps its own.
    @Test func trashingAForeignClipForgetsItsMarkers() async throws {
        try await ControllerHarness.run { controller, root in
            let foreign = try loadForeignClip(controller, in: root)
            controller.otherMarkers["A003_C012.mov"] = [TakeMarker(seconds: 1)]

            controller.deleteOtherFile(foreign)

            #expect(controller.otherMarkers["A003_C012.mov"] == nil)
        }
    }
}
