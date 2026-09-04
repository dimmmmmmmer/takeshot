import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The two places a take can come back from the dead: the folder scan, which
/// reads a file's own metadata and decides whether it is one of ours, and the
/// disk watchdog, which decides whether a take is rolling by reading the main
/// actor's mirror of the pipeline's state.
///
/// Both are recording-integrity rules stated in CLAUDE.md — "a failed finalize
/// is renamed `*_FAILED.mov` rather than re-adopted by the folder scan", and
/// "the take is closed under 0.5 GB" — and both were held by a mechanism that
/// does not do what the rule says.
@Suite @MainActor struct ControllerFailedTakeScanTests {
    /// A path that cannot be a folder and whose volume cannot be interrogated:
    /// a directory nested inside a regular FILE. The same fixture
    /// `ControllerDestinationFailureTests` uses, and for the same reason — it
    /// fails `resourceValues` exactly as a detached volume does, with no
    /// privileges and no real disk.
    private func unreachablePath(under root: URL) throws -> String {
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data([0x00]).write(to: blocker)
        return blocker.appendingPathComponent("takes").path
    }

    // MARK: - the folder scan

    /// The rename is not what keeps a failed take out of the panel, and until now
    /// nothing was: `movieFragmentInterval` means the half-written file already
    /// carries `com.takeshot.origin` in the moov its first fragment wrote, so the
    /// scan recognised it as ours and adopted it — into the takes list, into the
    /// clip numbering, and into `takeshot-log.csv`, which is the table post
    /// production reads.
    @Test func aFailedTakeIsNotReadoptedIntoTheTakesList() async throws {
        try await ControllerHarness.run { controller, root in
            let url: URL = root.appendingPathComponent("A001C003_FAILED.mov")
            _ = try await MediaFixtures.writeClip(at: url, frames: 8)
            try ControllerFixtures.settle(url)

            controller.scanDestinationFolder()
            #expect(await ControllerWait.untilWritten {
                controller.otherFiles.contains(url)
            }, "the failed take was never classified at all")

            #expect(controller.takes.isEmpty,
                    "a take that never finalized joined the list anyway")
            #expect(controller.otherFiles.contains(url),
                    "the failed take vanished instead of staying visible")
        }
    }

    /// …and the check is on the marker, not on the scan: the identical file
    /// without `_FAILED` in its name is still one of ours and still comes back.
    /// Without this the test above passes just as well if the scan stops adopting
    /// anything at all.
    @Test func aHealthyTakeOfTheSameShapeStillComesBack() async throws {
        try await ControllerHarness.run { controller, root in
            let url: URL = root.appendingPathComponent("A001C003.mov")
            _ = try await MediaFixtures.writeClip(at: url, frames: 8)
            try ControllerFixtures.settle(url)

            controller.scanDestinationFolder()
            #expect(await ControllerWait.untilWritten { !controller.takes.isEmpty },
                    "a healthy take was not restored by the scan")
            #expect(controller.takes.first?.url == url)
            #expect(!controller.otherFiles.contains(url),
                    "one of our own takes was published as foreign content")
        }
    }

    /// A second failure of the same name comes out as `..._FAILED_2.mov`, which
    /// is why the reading is `contains` and not `hasSuffix` — the same reading the
    /// diagnostics bundle's own flag already used.
    @Test func aSecondFailureOfTheSameNameIsAlsoKeptOut() async throws {
        try await ControllerHarness.run { controller, root in
            let url: URL = root.appendingPathComponent("A001C003_FAILED_2.mov")
            _ = try await MediaFixtures.writeClip(at: url, frames: 8)
            try ControllerFixtures.settle(url)

            controller.scanDestinationFolder()
            #expect(await ControllerWait.untilWritten {
                controller.otherFiles.contains(url)
            }, "the second failure was never classified at all")
            #expect(controller.takes.isEmpty,
                    "a second failed take joined the list anyway")
        }
    }

    // MARK: - the disk watchdog

    /// The watchdog decides on `isRecording`, which is the MAIN actor's mirror of
    /// a state the pipeline owns and updates one queue hop later. A take the
    /// pipeline has already closed itself — the cable came out — therefore leaves
    /// the mirror reading true, and the watchdog's "close the take" used to be a
    /// TOGGLE: it opened one, on the volume it had just declared unreachable.
    ///
    /// The observable difference is the banner. A `beginTake` onto a path that
    /// cannot be created throws, and its alarm lands after the watchdog's own —
    /// so the operator's last word about a vanished disk was "failed to start
    /// recording", for a take nobody asked for.
    @Test func theWatchdogDoesNotOpenATakeOnAVolumeItJustGaveUpOn() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            #expect(await ControllerWait.until { controller.isCapturing })
            // The state the race leaves behind, set directly rather than raced
            // into: the mirror says a take is rolling and the pipeline knows
            // better. Reaching it through a real dropout would mean settling the
            // pipeline's own queue from here, which this target cannot see.
            controller.isRecording = true
            try #require(!controller.pipeline.health.isRecording,
                         "the pipeline was recording — the premise is wrong")

            controller.settings.capture.destinationPath =
                try unreachablePath(under: root)
            controller.checkDiskSpace()

            // Waited for in the failing direction, on the full budget: the
            // watchdog sets the banner synchronously, so a poll for the RIGHT
            // banner goes true before a `beginTake` that is still on its way to
            // failing could overwrite it.
            let opened: Bool = await Self.takeWasOpened(by: controller)
            #expect(!opened,
                    "the watchdog opened a take on the unreachable volume")
            #expect(controller.persistentAlert == L("alarm_volume_unreachable"),
                    "the banner stopped naming the unreachable volume")

            await controller.pipeline.finishPendingWrites()
        }
    }

    /// Whether a take got opened, either way it can show: the pipeline reports a
    /// writer, or the banner names a start that failed. A full-budget wait in the
    /// failing direction — nothing here is expected to become true.
    private static func takeWasOpened(by controller: CaptureController) async -> Bool {
        let startFailed: String = localizedHead("alarm_recording_start_failed")
        return await ControllerWait.until {
            if controller.pipeline.health.isRecording { return true }
            guard let alert: String = controller.persistentAlert
            else { return false }
            return alert.contains(startFailed)
        }
    }

    /// The primitive underneath it, on its own: a stop is a stop.
    @Test func stoppingAPipelineThatIsNotRecordingStartsNothing() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.pipeline.stopRecordingIfRolling()
            let opened: Bool = await ControllerWait.until {
                controller.pipeline.health.isRecording
            }
            #expect(!opened, "a stop on an idle pipeline opened a take")
            #expect(controller.pipeline.health.takesClosed == 0,
                    "a stop on an idle pipeline closed something")
        }
    }

    /// **…and a failed take whose RENAME could not be made is refused too.**
    /// The name guard above is only half of it: the rename fails exactly when
    /// the volume dropped, and the file keeps its healthy name and its tag.
    /// What survived the drop is the ledger in Application Support.
    @Test func aLedgeredTakeIsNotAdoptedAsFootage() async throws {
        let previous = FailedTakeLedger.fileURL
        FailedTakeLedger.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-takes-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: FailedTakeLedger.fileURL)
            FailedTakeLedger.fileURL = previous
        }
        try await ControllerHarness.run { controller, root in
            // a real tagged clip under its HEALTHY name — what a finalize that
            // failed on a dropped volume leaves behind when the rename fails
            let url: URL = root.appendingPathComponent("A001C007.mov")
            _ = try await MediaFixtures.writeClip(at: url, frames: 8)
            try ControllerFixtures.settle(url)
            FailedTakeLedger.record(url)

            controller.scanDestinationFolder()
            // the rename is retried now that the file is reachable
            let renamed = root.appendingPathComponent("A001C007_FAILED.mov")
            #expect(await ControllerWait.untilWritten {
                FileManager.default.fileExists(atPath: renamed.path)
            }, "the retry did not rename the file")
            #expect(controller.takes.isEmpty, """
                a take the ledger says failed came back into the list as \
                footage — and from there into the log post reads
                """)
            #expect(!FailedTakeLedger.contains(url),
                    "the name says it now; the ledger still did too")

            // …and the next scan shows it as Other content by name
            controller.scanDestinationFolder()
            #expect(await ControllerWait.untilWritten {
                controller.otherFiles.contains(renamed)
            }, "the renamed take vanished instead of staying visible")
            #expect(controller.takes.isEmpty)
        }
    }
}
