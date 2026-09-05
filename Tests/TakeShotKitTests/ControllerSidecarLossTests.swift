import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **A sidecar that would not be read must not be overwritten.**
///
/// The day's ratings, comments, markers and slates live in CSVs beside the
/// footage, and every rating and every take rewrites the WHOLE table from
/// memory — memory holding only what the last folder scan managed to load. The
/// read used `try? Data(contentsOf:)`, which answers the same empty table for
/// "there is no file yet" (the ordinary first take of the day) and for "the
/// file is there and will not open" (a share that had not finished mounting, a
/// card with an I/O error, a permission that changed).
///
/// So the second case looked exactly like a fresh folder, and the next keypress
/// wrote an empty day over a full one. The WRITE side has called this "a
/// day-loss bug" in its own catch since it was written; the read side had no
/// equivalent.
@Suite @MainActor struct ControllerSidecarLossTests {
    /// A folder with no sidecars at all is the ordinary start of a day, and
    /// nothing must be latched for it.
    @Test func anAbsentSidecarIsNotAFault() async throws {
        try await ControllerHarness.run { controller, _ in
            let stored = controller.loadStoredMetadata()
            #expect(stored.unreadable.isEmpty,
                    "an empty record folder was reported as unreadable")
            #expect(stored.meta.isEmpty)
        }
    }

    /// One that is there and will not open is a fault, and it is named.
    @Test func anUnreadableSidecarIsReportedRatherThanReadAsEmpty() async throws {
        try await ControllerHarness.run { controller, root in
            let log = root.appendingPathComponent(TakeLogExporter.fileName)
            try Data("whatever".utf8).write(to: log)
            // Unreadable in the way a share that has not mounted is: the bytes
            // cannot be fetched at all.
            try FileManager.default.setAttributes([.posixPermissions: 0],
                                                  ofItemAtPath: log.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: log.path)
            }

            let stored = controller.loadStoredMetadata()
            #expect(!stored.unreadable.isEmpty, """
                a sidecar that would not open was read as an empty day — the \
                next rating overwrites it
                """)
            #expect(stored.unreadable.first?.contains(
                TakeLogExporter.fileName) == true,
                "the report does not name the file: \(stored.unreadable)")
        }
    }

    /// And the latch stops the write. This is the assertion the whole thing is
    /// for: with a sidecar that cannot be read, the file on disk is left alone.
    ///
    /// The folder is made genuinely unreadable rather than the latch set by
    /// hand — a hand-set latch is cleared by the next folder scan, and the scan
    /// is exactly what runs between a rating and its write.
    @Test func theDayOnDiskSurvivesARatingMadeWhileTheFolderIsUnreadable()
        async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C01", clip: 1)
            // yesterday's table, as it would be on the card
            let log = root.appendingPathComponent(TakeLogExporter.fileName)
            let before = "the day's ratings and comments"
            try Data(before.utf8).write(to: log)
            try FileManager.default.setAttributes([.posixPermissions: 0],
                                                  ofItemAtPath: log.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: log.path)
            }

            controller.scanDestinationFolder()
            let noticed = await ControllerWait.until {
                !controller.unreadableSidecars.isEmpty
            }
            #expect(noticed,
                    "the scan did not notice the folder would not read")
            controller.setRating(.good, for: take)
            try await Task.sleep(for: .milliseconds(400))

            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: log.path)
            let after = try String(contentsOf: log, encoding: .utf8)
            #expect(after == before, """
                a rating rewrote a sidecar the app had not been able to read — \
                the day is gone
                """)
        }
    }

    /// A folder that comes back writes what was held in the meantime, rather
    /// than making the operator redo the edits.
    @Test func aFolderThatComesBackWritesWhatWasHeld() async throws {
        try await ControllerHarness.run { controller, root in
            let take = try RemoteHarness.seedTake(controller, in: root,
                                                  named: "A001C01", clip: 1)
            controller.noteUnreadableSidecars(["\(TakeLogExporter.fileName) — I/O"])
            #expect(controller.persistentAlert != nil,
                    "nothing on screen said the day was not being saved")
            controller.setRating(.good, for: take)

            controller.noteUnreadableSidecars([])
            #expect(controller.persistentAlert == nil,
                    "the banner outlived the fault")
            let wrote = await ControllerWait.until {
                (try? String(contentsOf: root.appendingPathComponent(
                    TakeLogExporter.fileName), encoding: .utf8))?
                    .contains("A001C01") == true
            }
            #expect(wrote, "the held edits were never written after recovery")
        }
    }

    /// **A record folder that is GONE is the volume alarm's business, not this
    /// one's.**
    ///
    /// The first version of the read matched `NSFileReadNoSuchFileError` and
    /// called every other error unreadable — and a path whose parent is blocked
    /// answers `NSFileReadUnknownError` instead. So a vanished record volume
    /// looked like three unreadable sidecars, and "the day's ratings are not
    /// being saved" went on the banner over `alarm_volume_unreachable`: the
    /// wrong message, hiding the more serious one, on the fault an operator
    /// actually has to act on. CI caught it and the development Mac did not.
    @Test func avanishedRecordFolderIsNotReportedAsUnreadableSidecars()
        async throws {
        try await ControllerHarness.run { controller, root in
            // exactly what `ControllerDestinationFailureTests` builds: a
            // regular file standing where a folder should be
            let blocker = root.appendingPathComponent("not-a-folder")
            try Data([0x00]).write(to: blocker)
            controller.settings.capture.destinationPath =
                blocker.appendingPathComponent("takes").path

            let stored = controller.loadStoredMetadata()
            #expect(stored.unreadable.isEmpty, """
                a record folder that is not there was read as sidecars that \
                will not open: \(stored.unreadable)
                """)

            controller.noteUnreadableSidecars(stored.unreadable)
            #expect(controller.persistentAlert == nil, """
                the sidecar banner took the alarm line while the record volume \
                itself is gone — that is the message the operator needs there
                """)
        }
    }
}

/// **The range sidecar joins the rule the other three follow.** It was still
/// read with `try?`, so a `takeshot-ranges.csv` on a share that had not
/// mounted read as an empty day and the next in/out mark rewrote it wholesale.
@Suite @MainActor struct ControllerRangesSidecarTests {
    @Test func anUnreadableRangesFileIsNotRewrittenOver() async throws {
        try await ControllerHarness.run { controller, root in
            let file = root.appendingPathComponent(TakeLogExporter.rangesFileName)
            let before = "yesterday's in and out points"
            try Data(before.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0],
                                                  ofItemAtPath: file.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: file.path)
            }

            let ranges = controller.loadStoredRanges()
            #expect(ranges.isEmpty)
            #expect(!controller.unreadableSidecars.isEmpty, """
                a range file that would not open was read as an empty day — \
                the next in/out mark rewrites it
                """)

            controller.exportClipRanges()
            try await Task.sleep(for: .milliseconds(400))
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: file.path)
            #expect(try String(contentsOf: file, encoding: .utf8) == before,
                    "the range sidecar was rewritten over a file the app could not read")
        }
    }
}
