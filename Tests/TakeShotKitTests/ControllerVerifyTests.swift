import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The app side of "verify disk against MHL".
///
/// The engine is covered in CaptureCoreTests. What matters here is what a
/// finished pass does to the rest of the UI, and the split is the same one the
/// offload draws: a good disk is a toast, a damaged one is a STICKY alarm. This
/// result is read before a backup is retired or the last copy of a day is
/// deleted, and a five-second toast that scrolled past while the operator was
/// lighting the next setup is how footage disappears.
@Suite @MainActor struct ControllerVerifyTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-verify-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// A disk with a real offload on it: two files, one nested, and the ascmhl
    /// manifest plus the summary the engine leaves beside them.
    private func offloadedDisk(_ name: String) throws -> (card: URL, disk: URL) {
        let card = try scratch("\(name)-card")
        try Data([1, 2, 3]).write(to: card.appendingPathComponent("A001C001.mov"))
        let nested = card.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        try Data([4, 5]).write(to: nested.appendingPathComponent("A001C002.mov"))
        let disk = try scratch("\(name)-disk")
        let report = OffloadEngine.run(OffloadPlan(source: card,
                                                   destinations: [disk]))
        #expect(report.isFullyVerified, "the fixture offload itself failed")
        return (card, disk)
    }

    private func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - a pass, end to end

    @Test func aGoodDiskEndsAsANoticeAndNoAlarm() async throws {
        try await ControllerHarness.run { controller, _ in
            let fixture = try self.offloadedDisk("clean")
            defer { self.remove(fixture.card, fixture.disk) }

            controller.startVerify(at: fixture.disk)

            // the takes-panel status line is up before any file is hashed
            #expect(controller.verifySheetPresented)
            #expect(controller.offloadStatus != nil)
            #expect(await ControllerWait.untilWritten {
                controller.verify.report != nil
            })

            let report = try #require(controller.verify.report)
            #expect(report.isIntact)
            #expect(report.verified.count == 2)
            #expect(report.extra.isEmpty,
                    "the offload's own manifest and summary were called strays")
            #expect(!controller.verify.isRunning)
            #expect(controller.offloadStatus == nil)
            #expect(controller.lastNotice != nil)
            #expect(controller.persistentAlert == nil)
        }
    }

    /// The one that matters. A file that came back wrong must be reported by
    /// something that does not disappear on its own, and the alarm has to name
    /// the file — "something is wrong with this disk" is not actionable at 2am.
    @Test func aCorruptedFileRaisesTheStickyAlarmAndNamesIt() async throws {
        try await ControllerHarness.run { controller, _ in
            let fixture = try self.offloadedDisk("bad")
            defer { self.remove(fixture.card, fixture.disk) }
            let victim = fixture.disk.appendingPathComponent("DCIM/A001C002.mov")
            try Data([9, 9]).write(to: victim)

            controller.startVerify(at: fixture.disk)
            #expect(await ControllerWait.untilWritten {
                controller.verify.report != nil
            })

            let report = try #require(controller.verify.report)
            #expect(!report.isIntact)
            #expect(report.mismatched.map(\.relativePath) == ["DCIM/A001C002.mov"])
            #expect(controller.lastNotice == nil)
            let alert = try #require(controller.persistentAlert)
            #expect(alert.contains("A001C002.mov"), "alert: \(alert)")
        }
    }

    /// A file the manifest lists and the disk no longer has is the same class of
    /// news, and the alarm names it too.
    @Test func aDeletedFileRaisesTheStickyAlarm() async throws {
        try await ControllerHarness.run { controller, _ in
            let fixture = try self.offloadedDisk("gone")
            defer { self.remove(fixture.card, fixture.disk) }
            try FileManager.default.removeItem(
                at: fixture.disk.appendingPathComponent("A001C001.mov"))

            controller.startVerify(at: fixture.disk)
            #expect(await ControllerWait.untilWritten {
                controller.verify.report != nil
            })

            let report = try #require(controller.verify.report)
            #expect(report.missing == ["A001C001.mov"])
            let alert = try #require(controller.persistentAlert)
            #expect(alert.contains("A001C001.mov"), "alert: \(alert)")
            #expect(controller.lastNotice == nil)
        }
    }

    /// A stray file is reported and does NOT downgrade the verdict: the manifest
    /// is still fully satisfied. A tool that refuses to say "verified" until
    /// somebody clears a .DS_Store off the disk teaches its operator to stop
    /// reading it.
    @Test func aStrayFileStillEndsAsANotice() async throws {
        try await ControllerHarness.run { controller, _ in
            let fixture = try self.offloadedDisk("stray")
            defer { self.remove(fixture.card, fixture.disk) }
            try Data([7]).write(to: fixture.disk
                .appendingPathComponent("shot-list.txt"))

            controller.startVerify(at: fixture.disk)
            #expect(await ControllerWait.untilWritten {
                controller.verify.report != nil
            })

            let report = try #require(controller.verify.report)
            #expect(report.extra == ["shot-list.txt"])
            #expect(report.isIntact)
            #expect(controller.persistentAlert == nil)
            #expect(controller.lastNotice != nil)
        }
    }

    // MARK: - the folder that cannot be checked

    /// Picking the wrong folder is the first mistake anyone makes with this, and
    /// it must not look like a verified empty disk.
    ///
    /// An error toast rather than the sticky alarm: the alarm means footage is
    /// at risk, and a folder nothing ever offloaded to is not footage at risk.
    @Test func aFolderWithNoManifestIsAnErrorAndNotAnAlarm() async throws {
        try await ControllerHarness.run { controller, _ in
            let plain = try self.scratch("no-manifest")
            defer { self.remove(plain) }
            try Data([1]).write(to: plain.appendingPathComponent("A001C001.mov"))

            controller.startVerify(at: plain)
            #expect(await ControllerWait.untilWritten {
                controller.verify.failure != nil
            })

            #expect(controller.verify.report == nil)
            #expect(controller.persistentAlert == nil)
            #expect(!controller.verify.isRunning)
            #expect(controller.offloadStatus == nil)
            let failure = try #require(controller.verify.failure)
            #expect(failure.contains(plain.lastPathComponent), "failure: \(failure)")
            // …and the same sentence reaches the toast, because the sheet may
            // not be the thing the operator is looking at
            #expect(controller.lastError == failure)
        }
    }

    /// The message is the operator's language, not CaptureCore's English — but
    /// only for the case an operator can act on. The technical ones travel as
    /// they are rather than being wrapped in a translation that hides them.
    @Test func theMissingManifestSentenceIsLocalized() async throws {
        try await ControllerHarness.run { _, _ in
            let folder = URL(fileURLWithPath: "/Volumes/DAILIES_SSD_1")
            let missing = CaptureController.verifyFailureMessage(
                OffloadVerifyError.noManifest("DAILIES_SSD_1"), at: folder)
            let other = CaptureController.verifyFailureMessage(
                OffloadVerifyError.unreadableManifest(name: "0001_x.mhl",
                                                      reason: "malformed XML"),
                at: folder)

            for language in [AppLanguage.english, .russian] {
                let localized = ViewRender.withLanguage(language) {
                    CaptureController.verifyFailureMessage(
                        OffloadVerifyError.noManifest("DAILIES_SSD_1"),
                        at: folder)
                }
                #expect(localized.contains("DAILIES_SSD_1"))
                #expect(!localized.hasPrefix("verify_"),
                        "\(language.rawValue) has no verify_error_no_manifest")
            }
            #expect(missing != other)
            #expect(other.contains("malformed XML"),
                    "the technical reason was swallowed: \(other)")
        }
    }

    // MARK: - stopping

    /// The two disk jobs take turns. They share the offload queue and the takes
    /// panel's one status line, so a verify started over a running offload would
    /// sit behind it while overwriting everything it says about itself — and
    /// both have a menu-bar item, which stays live while the other's sheet is
    /// up. Refused out loud, because a menu item that quietly ignores a click
    /// reads as a broken app.
    @Test func aSecondDiskJobIsRefusedWhileOneIsRunning() async throws {
        try await ControllerHarness.run { controller, _ in
            let fixture = try self.offloadedDisk("busy")
            defer { self.remove(fixture.card, fixture.disk) }
            // an offload the test never lets finish
            controller.offload.isRunning = true

            controller.startVerify(at: fixture.disk)

            #expect(!controller.verifySheetPresented)
            #expect(controller.verify.root == nil)
            #expect(controller.lastError != nil)
            // …and the same the other way round
            controller.offload.isRunning = false
            controller.verify.isRunning = true
            controller.lastError = nil
            controller.showOffloadSheet()
            #expect(!controller.offloadSheetPresented)
            #expect(controller.lastError != nil)
            controller.verify.isRunning = false
        }
    }

    @Test func stopOnlyAppliesToARunningPass() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.verify.cancel()

            #expect(!controller.verify.isCancelling)
            #expect(controller.offloadStatus == nil)
        }
    }

    /// Opening the sheet again for the next disk must not show the last disk's
    /// verdict — a stale "verified" is the most dangerous thing on the screen.
    @Test func startingAgainClearsTheLastResult() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.offloadedDisk("first")
            let plain = try self.scratch("second")
            defer { self.remove(first.card, first.disk, plain) }

            controller.startVerify(at: first.disk)
            #expect(await ControllerWait.untilWritten {
                controller.verify.report != nil
            })

            controller.startVerify(at: plain)

            #expect(controller.verify.report == nil)
            #expect(await ControllerWait.untilWritten {
                controller.verify.failure != nil
            })
        }
    }
}
