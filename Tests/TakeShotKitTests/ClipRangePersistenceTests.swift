import AVFoundation
import AppKit
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// In/out points outliving the app.
///
/// The range is operator work — a stunt beat, the one usable moment in a long
/// take — and losing it to a restart is losing the review the operator did. It is
/// filed in `takeshot-ranges.csv` in the record folder, which means it also
/// travels with the footage: the same marks come back on the machine the DIT
/// copies the folder onto.
///
/// The sidecar's own format lives in `CaptureCoreTests/ClipRangeSidecarTests`.
/// This suite is the wiring: what triggers a write, what a scan restores, and what
/// a relaunch actually gets back.
@Suite @MainActor struct ClipRangePersistenceTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/takeshot-range-persist/\(name)")
    }

    /// The sidecar as it stands on disk in `directory`.
    ///
    /// The failable decode is enough here: every sidecar in these tests is one the
    /// app just wrote. The lossy decode belongs in the app, where the file may
    /// have been through somebody's spreadsheet.
    private func sidecar(in directory: URL) -> [String: ClipRange] {
        let url = directory
            .appendingPathComponent(TakeLogExporter.rangesFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        return TakeLogExporter.parseRanges(csv: text)
    }

    /// A relaunch: a second controller over the same preferences and so the same
    /// record folder. Its `TransportModel` is its own, built empty, so the only
    /// route a range can take to it is the file on disk.
    ///
    /// Torn down the way `ControllerHarness` tears the first one down — a
    /// controller left running keeps a capture, a folder watcher, an audio monitor
    /// and two persistence debounces alive for the rest of the suite.
    private func relaunch(
        _ controller: CaptureController,
        _ body: (CaptureController) async throws -> Void) async throws {
        let second = CaptureController(
            backends: [("mock", SyntheticSignalBackend())],
            defaults: controller.defaults,
            audioInputs: FakeAudioInputProvider())
        second.monitorOn = false
        second.audioMonitor.stop()
        second.stopCapture()
        // the suites drive scans themselves; a kernel watcher would fire them at
        // unpredictable moments
        second.folderWatcher?.cancel()
        second.folderWatcher = nil
        defer {
            second.volumePersistTask?.cancel()
            second.lutPersistTask?.cancel()
            second.folderWatcher?.cancel()
            second.folderWatcher = nil
            second.stopCapture()
            second.monitorOn = false
            second.audioMonitor.stop()
        }
        try #require(second.settings.destinationPath
                        == controller.settings.destinationPath,
                     "the relaunched controller opened a different folder")
        try await body(second)
    }

    // MARK: - what triggers a write

    @Test func markingARangeWritesTheSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            let clip = root.appendingPathComponent("A001C001.mov")
            controller.transport.loadClip(clip)
            controller.transport.position.currentTime = 12.125
            controller.transport.toggleRangePoint(out: false)
            controller.transport.position.currentTime = 20.5
            controller.transport.toggleRangePoint(out: true)

            let written = await ControllerWait.untilWritten {
                sidecar(in: root)["A001C001.mov"]
                    == ClipRange(inPoint: 12.125, outPoint: 20.5)
            }
            #expect(written, "the sidecar holds \(sidecar(in: root))")
        }
    }

    /// Clearing a mark is a decision too, and it has to reach the file — otherwise
    /// the range the operator just removed comes back tomorrow.
    @Test func clearingTheLastRangeRemovesTheSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            let clip = root.appendingPathComponent("A001C001.mov")
            controller.transport.loadClip(clip)
            controller.transport.position.currentTime = 4
            controller.transport.toggleRangePoint(out: false)
            let written = await ControllerWait.untilWritten {
                !sidecar(in: root).isEmpty
            }
            #expect(written)

            controller.transport.position.currentTime = 4
            controller.transport.toggleRangePoint(out: false) // clicking it clears

            let gone = await ControllerWait.untilWritten { sidecar(in: root).isEmpty }
            #expect(gone, "the cleared range is still on file: \(sidecar(in: root))")
        }
    }

    /// Reviewing clip after clip without touching a mark must not rewrite the
    /// file each time. The transport reports a change, not a load.
    @Test func aLoadThatChangesNothingIsNotAChange() {
        let transport = TransportModel()
        var reports = 0
        transport.onRangesChanged = { reports += 1 }

        for name in ["A.mov", "B.mov", "C.mov"] { transport.loadClip(url(name)) }
        #expect(reports == 0,
                "reviewing three clips without a mark reported \(reports) changes")

        transport.position.currentTime = 4
        transport.toggleRangePoint(out: false)
        #expect(reports == 1, "marking an in point has to report exactly once")

        // closing that clip files a range that is already on file
        transport.loadClip(url("D.mov"))
        #expect(reports == 1, "filing an unchanged range reported again")
        // and coming back to it adopts what is on file
        transport.loadClip(url("C.mov"))
        #expect(reports == 1)
        #expect(transport.inPoint == 4)
    }

    // MARK: - what a scan restores

    @Test func aFreshTransportGetsItsRangesFromTheSidecar() {
        let transport = TransportModel() // as after a relaunch: nothing on file
        let stored = TakeLogExporter.parseRanges(csv: """
            File Name,In,Out
            A001C001.mov,12.125,20.500
            """)

        transport.restoreRanges(stored,
                                forFilesNamed: ["A001C001.mov", "A001C002.mov"])

        transport.loadClip(url("A001C001.mov"))
        #expect(transport.currentRange == ClipRange(inPoint: 12.125, outPoint: 20.5))
        transport.loadClip(url("A001C002.mov"))
        #expect(transport.currentRange.isEmpty,
                "a clip the sidecar says nothing about was given a range")
    }

    /// A scan runs every minute and on every folder event. Restoring from the file
    /// must not undo the mark the operator made ten seconds ago.
    @Test func restoringDoesNotUndoAMarkMadeThisSession() {
        let transport = TransportModel()
        let clip = url("A001C001.mov")
        transport.loadClip(clip)
        transport.position.currentTime = 3
        transport.toggleRangePoint(out: false)

        transport.restoreRanges(["A001C001.mov": ClipRange(inPoint: 99)],
                                forFilesNamed: ["A001C001.mov"])

        transport.loadClip(url("other.mov"))
        transport.loadClip(clip)
        #expect(transport.inPoint == 3, "a stale row overwrote a fresh mark")
    }

    /// A row is only restored for a clip the scan actually found. That is what
    /// keeps a trashed clip's range from coming back out of a sidecar that was
    /// written before it went.
    @Test func aRowForAClipTheScanDidNotFindIsNotRestored() {
        let transport = TransportModel()

        transport.restoreRanges(["gone.mov": ClipRange(inPoint: 5)],
                                forFilesNamed: ["still-here.mov"])

        transport.loadClip(url("gone.mov"))
        #expect(transport.currentRange.isEmpty)
    }

    /// The clip can be open before the first scan has read the file — the operator
    /// double-clicks a take while the folder is still being walked. The range has
    /// to appear when it arrives, not at the next open.
    @Test func aRangeRestoredWhileTheClipIsOpenShowsUpInThePlayer() {
        let transport = TransportModel()
        let clip = url("A001C001.mov")
        transport.loadClip(clip)
        #expect(transport.inPoint == nil)

        transport.restoreRanges(["A001C001.mov": ClipRange(inPoint: 6, outPoint: 8)],
                                forFilesNamed: ["A001C001.mov"])

        #expect(transport.currentRange == ClipRange(inPoint: 6, outPoint: 8))
    }

    // MARK: - the relaunch

    @Test func aRangeSurvivesARelaunch() async throws {
        try await ControllerHarness.run { controller, root in
            let marked = ControllerFixtures.take(named: "takeshot-test-marked",
                                                 in: root, clip: 1)
            let plain = ControllerFixtures.take(named: "takeshot-test-plain",
                                                in: root, clip: 2)
            for take in [marked, plain] {
                try ControllerFixtures.placeholder(for: take)
                // past the scan's "still being written" window, so the relaunched
                // controller's scan really sees them
                try ControllerFixtures.settle(take.url)
            }

            controller.transport.loadClip(marked.url)
            controller.transport.position.currentTime = 12.125
            controller.transport.toggleRangePoint(out: false)
            controller.transport.position.currentTime = 20.5
            controller.transport.toggleRangePoint(out: true)
            let saved = await ControllerWait.untilWritten {
                !sidecar(in: root).isEmpty
            }
            #expect(saved, "nothing reached the sidecar to survive anything")

            try await relaunch(controller) { second in
                second.scanDestinationFolder()
                let restored = await ControllerWait.untilWritten {
                    second.transport.storedRange(for: marked.url)
                        == ClipRange(inPoint: 12.125, outPoint: 20.5)
                }
                #expect(restored, "the take came back without the range marked on it")
                #expect(second.transport.storedRange(for: plain.url).isEmpty,
                        "the take nobody marked was given a range")

                // and the player gets it when the clip is opened
                second.transport.loadClip(marked.url)
                #expect(second.transport.currentRange
                            == ClipRange(inPoint: 12.125, outPoint: 20.5))
            }
        }
    }

    // MARK: - the range leaves with the clip

    @Test func deletingAClipRemovesItsRowFromTheSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            let doomed = ControllerFixtures.take(named: "takeshot-test-doomed",
                                                 in: root)
            try ControllerFixtures.placeholder(for: doomed)
            let kept = root.appendingPathComponent("takeshot-test-kept.mov")
            try Data([0x00]).write(to: kept)
            controller.takes = [doomed]
            controller.otherFiles = [kept]

            for (clip, seconds) in [(doomed.url, 2.0), (kept, 5.0)] {
                controller.transport.loadClip(clip)
                controller.transport.position.currentTime = seconds
                controller.transport.toggleRangePoint(out: false)
            }
            let both = await ControllerWait.untilWritten {
                sidecar(in: root).count == 2
            }
            #expect(both, "the sidecar holds \(sidecar(in: root))")

            controller.deleteTake(doomed)

            let removed = await ControllerWait.untilWritten {
                sidecar(in: root).keys.sorted() == ["takeshot-test-kept.mov"]
            }
            #expect(removed, "the sidecar holds \(sidecar(in: root))")
        }
    }

    /// Changing the record folder mid-shift. The folder being switched to has its
    /// own sidecar — whoever shot there this morning marked it — and swapping to it
    /// must not write this session's empty table over it before it is read.
    @Test func switchingRecordFolderDoesNotBlankTheNewFoldersSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            // a subfolder of the scratch root, so the harness's teardown takes it
            let afternoon = root.appendingPathComponent("afternoon")
            try FileManager.default.createDirectory(
                at: afternoon, withIntermediateDirectories: true)
            let clip = afternoon.appendingPathComponent("B001C001.mov")
            try Data([0x00]).write(to: clip)
            try ControllerFixtures.settle(clip)
            try TakeLogExporter.writeRanges(
                ["B001C001.mov": ClipRange(inPoint: 7, outPoint: 9)],
                toDirectory: afternoon)

            // a mark in the morning folder, so the table being dropped is not empty
            controller.transport.loadClip(
                root.appendingPathComponent("A001C001.mov"))
            controller.transport.position.currentTime = 3
            controller.transport.toggleRangePoint(out: false)

            controller.settings.destinationPath = afternoon.path

            let restored = await ControllerWait.untilWritten {
                controller.transport.storedRange(for: clip)
                    == ClipRange(inPoint: 7, outPoint: 9)
            }
            #expect(restored,
                    "the afternoon sidecar reads \(sidecar(in: afternoon))")
            #expect(sidecar(in: afternoon)["B001C001.mov"]
                        == ClipRange(inPoint: 7, outPoint: 9),
                    "the afternoon sidecar was written over before it was read")
        }
    }

    // MARK: - RAW

    /// The RAW engine counts frames and the sidecar stores seconds, so the
    /// conversion has to survive the trip both ways. And the engine reports a mark
    /// as it is made rather than when the clip closes — a quit with a RAW clip
    /// still open must not lose it.
    @Test func aRawRangeReachesTheSidecarInSecondsAndComesBackInFrames() async throws {
        let media = try MediaFixtures.makeDirectory("range-sidecar-raw")
        defer { try? FileManager.default.removeItem(at: media) }
        // a CinemaDNG "clip": the engine opens the folder and falls back to
        // 1920x1080/24 without ever decoding the frame
        let sequence = media.appendingPathComponent("A002")
        try FileManager.default.createDirectory(at: sequence,
                                               withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: sequence.appendingPathComponent("0001.dng"))

        try await ControllerHarness.run { controller, root in
            MediaFixtures.silence(controller)
            defer { MediaFixtures.stopPlayback(controller) }

            controller.play(url: sequence)
            let raw = try #require(controller.rawPlayer)
            raw.pause()
            let fps = raw.frameRate

            // marked on the engine, with the clip still open: the file hears now
            raw.toggleRangePoint(out: false) // the playhead is at frame 0
            let marked = await ControllerWait.untilWritten {
                sidecar(in: root)["A002"] == ClipRange(inPoint: 0, outPoint: nil)
            }
            #expect(marked, "the sidecar holds \(sidecar(in: root))")

            raw.inFrame = Int(fps * 2)
            raw.outFrame = Int(fps * 3)
            controller.play(url: sequence) // files the range, rebuilds the engine

            let seconds = await ControllerWait.untilWritten {
                sidecar(in: root)["A002"] == ClipRange(inPoint: 2, outPoint: 3)
            }
            #expect(seconds, "frames did not land as seconds: \(sidecar(in: root))")
            let reopened = try #require(controller.rawPlayer)
            reopened.pause()
            #expect(reopened.inFrame == Int(fps * 2),
                    "seconds did not come back as the frame they were marked on")
            #expect(reopened.outFrame == Int(fps * 3))
        }
    }
}
