import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which mounted volumes are never offered as a card, and — the half that costs
/// footage — which ones must be.
///
/// Split out of `ControllerCardWatchTests`, which is at its file-length ceiling
/// and is about the ASKING (never copy, never during a take, never twice). This
/// is about the decision made before any of that: whether the volume is one of
/// the app's own disks at all. Shares `CardFixture` with that file, because a
/// fixture set that belongs to whichever suite was written first is how the
/// second one ends up with a copy of it.
@Suite @MainActor struct ControllerCardExclusionTests {
    @Test func theBootVolumeNeverPrompts() async throws {
        try await CardFixture.withWatch { controller, watch in
            watch.mount(URL(fileURLWithPath: "/"), name: "Macintosh HD")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// The app's own destination disk: offering to copy a card OFF the disk the
    /// copies land on is the one wrong guess that costs more than a click.
    @Test func theDestinationVolumeNeverPrompts() async throws {
        let card = try CardFixture.makeCard("own-disk")
        defer { try? FileManager.default.removeItem(at: card) }
        try await CardFixture.withWatch { controller, watch in
            // as if the record folder were a folder on this very volume
            controller.settings.capture.destinationPath =
                card.appendingPathComponent("Dailies").path
            #expect(controller.isExcludedVolume(
                MountedVolume(url: card, name: "A001")))

            watch.mount(card, name: "A001")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// A destination that is really THERE speaks for its volume: the disk the
    /// copies land on is not a card to copy.
    ///
    /// The folder is created, which is the whole difference from the test below
    /// it: a destination the operator picked through a file panel exists on the
    /// disk it was picked on. This fixture used to name a folder that had never
    /// been created, which passed for the wrong reason.
    @Test func aSavedOffloadDestinationNeverPrompts() async throws {
        let card = try CardFixture.makeCard("saved-dst")
        defer { try? FileManager.default.removeItem(at: card) }
        let dit: URL = card.appendingPathComponent("DIT")
        try FileManager.default.createDirectory(at: dit,
                                                withIntermediateDirectories: true)
        let rig: (inout CaptureSettings) -> Void = { [dit] in
            $0.offload.destinationPaths = [dit.path]
        }
        try await CardFixture.withWatch(configure: rig) { controller, watch in
            #expect(controller.isExcludedVolume(
                MountedVolume(url: card, name: "DAILIES_SSD")))
            #expect(controller.ownFolder(on: MountedVolume(url: card,
                                                          name: "DAILIES_SSD"))?
                .path == dit.path,
                    "the exclusion could not say which folder caused it")
            watch.mount(card, name: "DAILIES_SSD")

            #expect(!(await ControllerWait.until(
                { controller.cardOffer != nil }, timeout: .seconds(2))))
        }
    }

    /// …and a destination that is GONE speaks for nothing.
    ///
    /// This is the half that cost footage. `offload.destinationPaths` could
    /// never be cleared (see the offload suite), and `ownFolders` matched it by
    /// path alone — so a retired `/Volumes/Untitled/DIT` excluded every future
    /// volume that macOS happened to mount at `/Volumes/Untitled`. A camera card
    /// arriving at that mount point was not scanned, not offered, and not
    /// logged: the app looked like it had simply stopped noticing cards.
    ///
    /// The card here is a real one — the same fixture every other test in this
    /// suite offers — with a saved destination naming a folder ON it that does
    /// not exist. Existence is the discriminator: on the SSD the path was picked
    /// on it is there, and on the card that inherited the mount point it is not.
    @Test func aCardIsStillOfferedWhereARetiredDestinationOnceSat() async throws {
        let card = try CardFixture.makeCard("inherited-mount")
        defer { try? FileManager.default.removeItem(at: card) }
        let retired: URL = card.appendingPathComponent("DIT")
        let rig: (inout CaptureSettings) -> Void = { [retired] in
            $0.offload.destinationPaths = [retired.path]
        }
        try await CardFixture.withWatch(configure: rig) { controller, watch in
            let volume = MountedVolume(url: card, name: "Untitled")
            #expect(controller.ownFolder(on: volume) == nil,
                    "a destination that is not there still claimed the volume")
            #expect(!controller.isExcludedVolume(volume),
                    "the card was excluded by a destination that no longer exists")

            watch.mount(card, name: "Untitled")

            #expect(await CardFixture.waitForOffer(controller),
                    "the card was silently ignored")
            #expect(controller.cardOffer?.files == 2)
            // The setting is untouched — this is about what it MEANS for a
            // volume, not about deleting the operator's rig behind their back.
            #expect(controller.settings.offload.destinationPaths == [retired.path])
        }
    }
}
