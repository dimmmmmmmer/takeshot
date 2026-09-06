import Foundation
import Testing

@testable import TakeShotKit

/// The record folder's watcher failing to arm at a launch without the SSD
/// plugged in used to stay dead for the whole day: the only re-arm was
/// changing the destination path. Its volume coming back is the moment.
@MainActor
struct ControllerFolderWatcherRearmTests {
    @Test func theRecordFoldersVolumeComingBackReArmsTheWatcher() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.folderWatcher?.cancel()
            controller.folderWatcher = nil
            let volume = MountedVolume(
                url: controller.destinationRoot.deletingLastPathComponent(),
                name: "SSD", uuid: nil, isRemovable: false, isEjectable: true)
            controller.handleVolumeMount(volume)
            #expect(controller.folderWatcher != nil,
                    "the watcher stayed dead after its volume returned")
        }
    }

    /// Some other volume is not the record folder's: nothing to re-arm.
    @Test func anUnrelatedVolumeDoesNotTouchTheWatcher() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.folderWatcher?.cancel()
            controller.folderWatcher = nil
            controller.handleVolumeMount(MountedVolume(
                url: URL(fileURLWithPath: "/Volumes/SomeCard"), name: "CARD",
                uuid: nil, isRemovable: true, isEjectable: true))
            #expect(controller.folderWatcher == nil)
            // …and neither is a volume whose PATH merely begins with the
            // record folder's, which a string prefix could not tell apart.
            let sibling = controller.destinationRoot.deletingLastPathComponent()
            let lookalike = sibling.deletingLastPathComponent()
                .appendingPathComponent(sibling.lastPathComponent + "-2")
            controller.handleVolumeMount(MountedVolume(
                url: lookalike, name: "SSD-2", uuid: nil,
                isRemovable: false, isEjectable: true))
            #expect(controller.folderWatcher == nil,
                    "a volume beside the record folder's re-armed the watcher")
        }
    }
}
