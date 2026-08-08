import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// What the app does when the place the footage is going stops being there:
/// the record folder is moved out from under it, the volume it lives on
/// detaches, or the operator quits with a take still rolling.
///
/// None of these are exercised by hand and all three cost footage. They are the
/// watchdog's whole reason to exist, and until now the watchdog's own failure
/// branches were the part of it nothing ran.
@Suite @MainActor struct ControllerDestinationFailureTests {
    private static let format = CaptureFormat(
        width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test 25")

    /// A path that cannot be a folder and whose volume cannot be interrogated:
    /// a directory nested inside a regular FILE. `resourceValues` fails on it
    /// exactly as it fails on a detached volume, `createDirectory` cannot repair
    /// it, and it needs no privileges and no real disk.
    private func unreachablePath(under root: URL) throws -> String {
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data([0x00]).write(to: blocker)
        return blocker.appendingPathComponent("takes").path
    }

    /// Push `count` frames through the pipeline and wait for the last one to
    /// come out the far side. The pipeline's queue is serial, so the last
    /// frame's timecode reaching the UI is proof that every earlier frame
    /// reached the writer — there is no counter to poll and no reason to sleep.
    @discardableResult
    private func feed(_ controller: CaptureController, count: Int,
                      from start: Timecode) async -> Bool {
        let buffer = MediaFixtures.pixelBuffer(level: 128, width: 320, height: 180)
        var timecode = start
        for index in 1...count {
            timecode = timecode.advanced(by: 1)
            controller.pipeline.handleFrame(
                pixelBuffer: buffer,
                pts: CMTime(value: CMTimeValue(index * 40), timescale: 1000),
                timecode: timecode)
        }
        let last = timecode
        return await ControllerWait.until { controller.live.currentTimecode == last }
    }

    // MARK: - the record folder is moved out from under the app

    /// The watcher's fd points at an unlinked inode once the folder goes, so an
    /// open take would be writing into an orphan. Recreate, rearm, and say so.
    @Test func theRecordFolderVanishingIsRecreatedAndAnnounced() async throws {
        try await ControllerHarness.run { controller, root in
            controller.startFolderWatcher()
            try #require(controller.folderWatcher != nil,
                         "the watcher did not arm on a perfectly good folder")

            try FileManager.default.removeItem(at: root)

            #expect(await ControllerWait.until {
                controller.lastError?.contains("moved/deleted") == true
            }, "the folder disappeared without a word")
            #expect(FileManager.default.fileExists(atPath: root.path),
                    "the record folder was not put back")
            // …and the watch is live again on the folder it just recreated,
            // rather than still holding the fd of the unlinked one
            #expect(controller.folderWatcher != nil)
        }
    }

    /// A destination the app cannot even open leaves no watcher behind. The
    /// interesting part is that it does not pretend to have one: a stale source
    /// on a dead fd is a watch that never fires again and never says why.
    @Test func aWatcherDoesNotArmOnAPathItCannotOpen() async throws {
        try await ControllerHarness.run { controller, root in
            controller.startFolderWatcher()
            try #require(controller.folderWatcher != nil)

            controller.settings.destinationPath = try unreachablePath(under: root)
            controller.startFolderWatcher()

            #expect(controller.folderWatcher == nil,
                    "a watcher was left armed on a folder that cannot exist")
        }
    }

    // MARK: - the volume detaches

    /// Asking a volume that is no longer mounted is exactly how the free-space
    /// query fails, so a quiet return meant the watchdog went silent in the one
    /// case it exists for.
    @Test func anUnreachableRecordVolumeRaisesAStickyAlarm() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            #expect(await ControllerWait.until { controller.isCapturing })

            controller.settings.destinationPath = try unreachablePath(under: root)
            controller.startDiskWatch()

            #expect(await ControllerWait.until {
                controller.persistentAlert
                    == L("alarm_folder_unreachable",
                         controller.destinationRoot.path)
            }, "a vanished record volume went unannounced")
            // sticky, not a toast: an operator watching the slate has to still
            // find it there when they look up
            #expect(controller.persistentAlert?.contains(
                controller.destinationRoot.path) == true)
            #expect(controller.lastError == nil)
        }
    }

    /// …and a take rolling onto a vanished destination is writing nothing at
    /// all, so it is stopped rather than left showing red.
    @Test func anUnreachableRecordVolumeStopsARollingTake() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            #expect(await ControllerWait.until { controller.signalFormat != nil })
            controller.toggleManualRecord()
            #expect(await ControllerWait.until { controller.isRecording })

            controller.settings.destinationPath = try unreachablePath(under: root)
            controller.startDiskWatch()

            #expect(await ControllerWait.until {
                controller.persistentAlert == L("alarm_volume_unreachable")
            }, "a take onto a vanished volume was left rolling")
            #expect(await ControllerWait.untilWritten { !controller.isRecording })

            await controller.pipeline.finishPendingWrites()
        }
    }

    /// A folder that is merely absent — a destination typed in Settings that has
    /// never been used — is recoverable and normal. It gets created, and the
    /// operator is told nothing at all.
    @Test func anAbsentRecordFolderIsCreatedRatherThanAlarmedAbout() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            #expect(await ControllerWait.until { controller.isCapturing })
            let fresh = root.appendingPathComponent("never-used-before")

            controller.settings.destinationPath = fresh.path
            controller.startDiskWatch()

            #expect(await ControllerWait.until {
                FileManager.default.fileExists(atPath: fresh.path)
            }, "a fresh destination folder was not created")
            let alarm = controller.persistentAlert
            #expect(alarm != L("alarm_folder_unreachable",
                               controller.destinationRoot.path),
                    "an ordinary new folder raised an alarm: \(alarm ?? "")")
            #expect(alarm != L("alarm_volume_unreachable"),
                    "an ordinary new folder stopped a take: \(alarm ?? "")")
        }
    }

    /// The two thresholds the recording-integrity rules promise, as arithmetic.
    /// Only a real disk can put the watchdog into either state, so the rule
    /// itself is what is pinned here.
    @Test func theFreeSpaceThresholdsAreTheOnesTheRulesPromise() {
        let gigabyte: Int64 = 1_000_000_000
        typealias Verdict = CaptureController.DiskVerdict

        #expect(CaptureController.diskVerdict(freeBytes: 40 * gigabyte,
                                              isRecording: true) == Verdict.fine)
        // warn under 5 GB, whether or not a take is rolling
        #expect(CaptureController.diskVerdict(freeBytes: 4 * gigabyte,
                                              isRecording: false)
            == Verdict.low(gigabytes: 4))
        #expect(CaptureController.diskVerdict(freeBytes: 4 * gigabyte,
                                              isRecording: true)
            == Verdict.low(gigabytes: 4))
        // close the take under 0.5 GB — but only if there is one
        #expect(CaptureController.diskVerdict(freeBytes: gigabyte / 4,
                                              isRecording: true)
            == Verdict.full(gigabytes: 0.25))
        #expect(CaptureController.diskVerdict(freeBytes: gigabyte / 4,
                                              isRecording: false)
            == Verdict.low(gigabytes: 0.25))
        // the boundaries themselves are on the safe side of each threshold
        #expect(CaptureController.diskVerdict(freeBytes: 5 * gigabyte,
                                              isRecording: true) == Verdict.fine)
        #expect(CaptureController.diskVerdict(freeBytes: gigabyte / 2,
                                              isRecording: true)
            == Verdict.low(gigabytes: 0.5))
    }

    // MARK: - the operator quits mid-take

    /// Quitting mid-record used to leave a .mov without its moov atom. The
    /// flush parks the main thread on a semaphore until every writer has
    /// finalized, and THAT is checked here with no polling at all: the file is
    /// on disk by the time the call returns, which is the whole promise.
    ///
    /// The take's list entry is polled for rather than asserted outright, and
    /// the difference is the process rather than the app. The flush publishes
    /// each take with a main-queue hop and then pumps the run loop until a
    /// sentinel behind it runs; in the app the main thread is inside
    /// `NSApplication`'s CFRunLoop, where a nested `RunLoop.run(until:)` drains
    /// the main queue. A test binary's main thread is parked in
    /// `dispatch_main()` instead, which drains that queue itself and not
    /// through any run loop, so the pump has nothing to pump. What the flush
    /// guarantees about the FILE is the same either way.
    @Test func quittingMidTakeFinalizesTheFileAndKeepsItsListEntry() async throws {
        try await ControllerHarness.run { controller, root in
            controller.pipeline.handleFormat(Self.format)
            #expect(await ControllerWait.until { controller.signalFormat != nil })

            controller.toggleManualRecord()
            #expect(await ControllerWait.until { controller.isRecording })
            #expect(await feed(controller, count: 8,
                               from: Timecode(hours: 10, minutes: 0, seconds: 0,
                                              frames: 0, fps: 25)))
            let name = try #require(controller.pipeline.health.takeFileName,
                                    "no take was open to quit in the middle of")

            controller.flushOnTerminate()

            let url = root.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "quitting mid-take lost the file: \(url.path)")

            #expect(await ControllerWait.untilWritten {
                controller.takes.count == 1 && !controller.isRecording
            }, "quitting mid-take lost the list entry")
            let take = try #require(controller.takes.first)
            #expect(take.url == url)
            #expect(take.durationSeconds > 0)
        }
    }

    // MARK: - the board is unplugged

    /// The backend reports its device list changed from a capture thread; the
    /// controller has to adopt it on the main actor. A real board appearing wins
    /// over the demo source, and capture follows it without a button.
    @Test func aBoardAppearingIsAdoptedFromTheBackendCallback() async throws {
        let board = StubBackend()
        try await ControllerHarness.run(
            extraBackends: [("decklink", board)]) { controller, _ in
            try #require(controller.isMockSelected,
                         "the demo source should be the only thing here yet")

            board.deviceList = [CaptureDeviceInfo(id: "b1", name: "UltraStudio")]
            controller.backendDeviceListChanged(controller.backend)

            #expect(await ControllerWait.until {
                controller.selectedDeviceID == "decklink:b1"
            }, "a board that appeared was not adopted")
            #expect(controller.devices.contains { $0.id == "decklink:b1" })
            #expect(board.startedDeviceID == "b1",
                    "capture did not follow the board that was selected")
        }
    }
}
