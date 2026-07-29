import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The record folder is treated as the library, which means the scan decides
/// what the operator sees: what is ours, what was dropped in by hand, what has
/// left, and whether the next filename is already taken. Each of these has a
/// specific failure the code carries a comment about — a name silently reused,
/// a copy listed before it finished landing, and takes moved to the archive
/// taking the day's metadata with them.
@Suite @MainActor struct ControllerLibraryTests {
    /// Run one scan to completion. `scanDestinationFolder` marks itself in
    /// flight synchronously, so this cannot return before the scan it asked
    /// for has landed.
    /// Kick a scan and wait for `outcome`, not merely for the scan flag to
    /// clear. Writing the fixture files wakes the folder watcher, and a scan
    /// requested while one is already running is deferred (`rescanWhenIdle`),
    /// so "no scan in flight" can go true again on the strength of a scan that
    /// ran before the test's files existed.
    private func scan(_ controller: CaptureController,
                      until outcome: () -> Bool = { true }) async {
        controller.scanDestinationFolder()
        await ControllerWait.until { !controller.scanInFlight && outcome() }
    }

    @Test func theNextFilenameIsCheckedAgainstTheFolder() async throws {
        try await ControllerHarness.run { controller, root in
            #expect(controller.nameCollision == nil)

            try Data([0x00]).write(
                to: root.appendingPathComponent("A001C01.mov"))
            controller.refreshNameCollision()
            #expect(controller.nameCollision == "A001C01.mov")

            // stepping past the taken number clears the warning
            controller.nextTakeNumber = 2
            #expect(controller.nameCollision == nil)
        }
    }

    /// While a take rolls, the file being written naturally exists — warning
    /// about it would mean the banner is lit through every take.
    @Test func theTakenNameWarningIsHiddenWhileRecording() async throws {
        try await ControllerHarness.run { controller, root in
            try Data([0x00]).write(
                to: root.appendingPathComponent("A001C01.mov"))
            controller.refreshNameCollision()
            #expect(controller.nameCollision == "A001C01.mov")

            controller.isRecording = true
            controller.refreshNameCollision()
            #expect(controller.nameCollision == nil)
        }
    }

    /// A grab is a single atomic write and the operator expects to see it at
    /// once; only videos wait out the settle window.
    @Test func aStillShowsUpOnTheFirstScan() async throws {
        try await ControllerHarness.run { controller, root in
            let png = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("grab.png"))

            await scan(controller, until: { controller.otherFiles == [png] })

            #expect(controller.otherFiles == [png])
        }
    }

    /// A video that is still being copied onto the card is skipped — and
    /// nothing else will re-trigger the scan once the copy finishes, so the
    /// scan has to come back for it by itself.
    @Test func aVideoStillLandingIsPickedUpByTheRetry() async throws {
        try await ControllerHarness.run { controller, root in
            let clip = root.appendingPathComponent("dropped.mp4")
            try Data([0x00]).write(to: clip)
            // a second into the future, so the first scan still reads it as
            // mid-write even if a loaded machine takes its time getting there
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(1)],
                ofItemAtPath: clip.path)

            await scan(controller)
            #expect(controller.otherFiles.isEmpty, "a fresh write must settle first")

            await ControllerWait.until({ controller.otherFiles == [clip] },
                                       timeout: .seconds(20))
            #expect(controller.otherFiles == [clip])
        }
    }

    @Test func otherContentIsListedNewestFirst() async throws {
        try await ControllerHarness.run { controller, root in
            let old = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("a-old.png"))
            let new = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("b-new.png"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                ofItemAtPath: old.path)

            await scan(controller, until: { controller.otherFiles == [new, old] })

            #expect(controller.otherFiles == [new, old])
        }
    }

    /// Our own takes are not "other content" — listing them twice is how the
    /// panel ends up showing every take in both blocks.
    @Test func ourOwnTakesAreNotListedAsForeign() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C01", in: root)
            try ControllerFixtures.placeholder(for: take)
            // aged past the settle window, so the only thing that can keep it
            // out of Other content is the take list itself
            try ControllerFixtures.settle(take.url)
            controller.takes = [take]

            await scan(controller)

            #expect(controller.otherFiles.isEmpty)
            #expect(controller.takes.count == 1)
        }
    }

    /// The normal end of a day is the DIT moving the footage out. The takes
    /// leave the panel, but they must stay in the shift log — rewriting the
    /// CSV from the shrunken list destroyed the day's ratings and markers.
    @Test func takesThatLeftTheFolderAreRetiredNotForgotten() async throws {
        try await ControllerHarness.run { controller, root in
            let gone = ControllerFixtures.take(named: "A001C01", in: root)
            controller.takes = [gone]
            controller.thumbnails[gone.id] = nil
            controller.scannedPaths.insert(gone.url.path)

            await scan(controller, until: { controller.takes.isEmpty })

            #expect(controller.takes.isEmpty)
            #expect(controller.retiredTakes.map(\.url) == [gone.url])
            // and the path is forgotten, so the take is re-identified if it
            // ever comes back
            #expect(!controller.scannedPaths.contains(gone.url.path))
        }
    }

    /// A fresh destination is a fresh day: the previous folder's takes,
    /// previews and clip numbering must not carry over.
    @Test func resettingForANewDestinationClearsEverything() async throws {
        try await ControllerHarness.run { controller, root in
            let take = ControllerFixtures.take(named: "A001C09", in: root, clip: 9)
            try ControllerFixtures.placeholder(for: take)
            controller.takes = [take]
            controller.retiredTakes = [
                ControllerFixtures.take(named: "A001C08", in: root, clip: 8),
            ]
            controller.otherFiles = [root.appendingPathComponent("x.png")]
            controller.scannedPaths.insert(take.url.path)
            controller.nextTakeNumber = 10
            let generation = controller.libraryGeneration

            controller.resetLibraryForNewDestination()

            #expect(controller.takes.isEmpty)
            #expect(controller.retiredTakes.isEmpty)
            #expect(controller.otherFiles.isEmpty)
            #expect(controller.scannedPaths.isEmpty)
            #expect(controller.nextTakeNumber == 1)
            #expect(controller.libraryGeneration > generation)
        }
    }

}
