import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The app side of the DIT offload: what the sheet lets the operator ask for,
/// and what a finished run does to the rest of the UI.
///
/// The engine itself is covered in CaptureCoreTests; what matters here is that a
/// clean run ends as a toast and a bad one as a STICKY alarm — the card is about
/// to be formatted on the strength of it, and a five-second toast that scrolled
/// past while the operator was lighting the next setup is how footage
/// disappears.
@Suite @MainActor struct ControllerOffloadTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-offload-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// A tiny card: two files, one of them in a subfolder.
    private func makeCard(_ name: String) throws -> URL {
        let source = try scratch(name)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("A001C001.mov"))
        let nested = source.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        try Data([4, 5]).write(to: nested.appendingPathComponent("A001C002.mov"))
        return source
    }

    // MARK: - the sheet's own state

    /// The same two or three SSDs come back every shooting day; re-picking them
    /// through a file panel per card is the part of the old flow that hurt.
    ///
    /// The saved `sha256` is there on purpose: the checksum picker is gone
    /// (owner item 19) and a build that once wrote SHA-256 into the settings
    /// must not quietly bring the slow path back for the rest of that Mac's
    /// life. The engine still supports both, and a manifest written in either
    /// still verifies — what went is the question.
    @Test func theSheetSeedsItselfFromTheSavedRig() async throws {
        let rig: (inout CaptureSettings) -> Void = {
            $0.offloadDestinationPaths = ["/Volumes/SSD1", "/Volumes/SSD2"]
            $0.offloadHashAlgorithm = "sha256"
        }
        try await ControllerHarness.run(configure: rig) { controller, _ in
            controller.showOffloadSheet()

            #expect(controller.offloadSheetPresented)
            #expect(controller.offload.destinations.map(\.path)
                == ["/Volumes/SSD1", "/Volumes/SSD2"])
            #expect(OffloadSheetModel.algorithm == .xxh64)
        }
    }

    /// The folder the old two-panel flow left in `backupPath` is still worth
    /// something: it is the destination that operator had already chosen.
    @Test func theOldSingleDestinationSettingIsAdopted() async throws {
        let legacy: (inout CaptureSettings) -> Void = {
            $0.backupPath = "/Volumes/OLD"
        }
        try await ControllerHarness.run(configure: legacy) { controller, _ in
            controller.showOffloadSheet()

            #expect(controller.offload.destinations.map(\.path) == ["/Volumes/OLD"])
        }
    }

    /// Reopening the sheet for the next card must not show the last card's
    /// verdict — a stale "verified" is the most dangerous thing on the screen.
    @Test func reopeningTheSheetClearsTheLastResult() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("stale-src")
            let dest = try self.scratch("stale-dst")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: dest)
            }
            controller.offload.source = source
            controller.offload.addDestination(dest)
            controller.offload.start()
            _ = await ControllerWait.untilWritten { controller.offload.report != nil }

            controller.showOffloadSheet()

            #expect(controller.offload.report == nil)
            #expect(controller.offload.progress == nil)
        }
    }

    @Test func theCopyLandsInAFolderNamedAfterTheCard() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.source = URL(fileURLWithPath: "/Volumes/CARD_A001")
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1/Dailies"))

            #expect(model.destinationFolders.map(\.path)
                == ["/Volumes/SSD1/Dailies/CARD_A001"])
            #expect(model.canStart)
        }
    }

    @Test func theSameDestinationTwiceIsRefused() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.source = URL(fileURLWithPath: "/Volumes/CARD")
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))

            #expect(model.validationMessage != nil)
            #expect(!model.canStart)
            // and it is fixable from the sheet
            model.removeDestination(model.rows[1].id)
            #expect(model.validationMessage == nil)
            #expect(model.canStart)
        }
    }

    /// Copying a card into itself grows forever and can never verify.
    @Test func aDestinationInsideTheCardIsRefused() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.source = URL(fileURLWithPath: "/Volumes/CARD")
            model.addDestination(URL(fileURLWithPath: "/Volumes/CARD/DCIM"))

            #expect(model.validationMessage != nil)
            #expect(!model.canStart)
        }
    }

    @Test func nothingCanStartWithoutASourceAndADestination() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            #expect(!model.canStart)
            model.source = URL(fileURLWithPath: "/Volumes/CARD")
            #expect(!model.canStart)
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))
            #expect(model.canStart)
            // a row can be re-pointed rather than removed and re-added
            model.setDestination(URL(fileURLWithPath: "/Volumes/SSD2"),
                                 at: model.rows[0].id)
            #expect(model.destinations.map(\.path) == ["/Volumes/SSD2"])
        }
    }

    // MARK: - a run, end to end

    @Test func aCleanRunEndsAsANoticeAndRemembersTheRig() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("run-src")
            let first = try self.scratch("run-a")
            let second = try self.scratch("run-b")
            defer {
                for url in [source, first, second] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            model.source = source
            model.addDestination(first)
            model.addDestination(second)

            model.start()
            // the status line for the takes panel is up before any file moves
            #expect(controller.offloadStatus != nil)
            #expect(await ControllerWait.untilWritten { model.report != nil })

            let report = try #require(model.report)
            #expect(report.isFullyVerified)
            #expect(report.destinations.count == 2)
            #expect(!model.isRunning)
            #expect(controller.offloadStatus == nil)
            #expect(controller.lastNotice != nil)
            #expect(controller.persistentAlert == nil)
            for root in [first, second] {
                let card = root.appendingPathComponent(source.lastPathComponent)
                #expect(try Data(contentsOf: card
                    .appendingPathComponent("DCIM/A001C002.mov")) == Data([4, 5]))
            }
            // the destinations are remembered for the next card
            let saved = CaptureSettings.loaded(from: controller.defaults)
            #expect(saved.offloadDestinationPaths == [first.path, second.path])
            #expect(saved.offloadHashAlgorithm == "xxh64")
        }
    }

    /// The one that matters: a destination that failed must not be reported by
    /// something that disappears on its own.
    @Test func aFailedDestinationRaisesTheStickyAlarm() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("bad-src")
            let good = try self.scratch("bad-good")
            let broken = try self.scratch("bad-broken")
            defer {
                for url in [source, good, broken] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            // a regular file where this destination's card folder has to go
            try Data([0]).write(to: broken
                .appendingPathComponent(source.lastPathComponent))
            let model = controller.offload
            model.source = source
            model.addDestination(good)
            model.addDestination(broken)

            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            let report = try #require(model.report)
            #expect(!report.isFullyVerified)
            #expect(report.failedDestinations.count == 1)
            #expect(controller.lastNotice == nil)
            let alert = try #require(controller.persistentAlert)
            #expect(alert.contains("1"))
            // the healthy disk still got everything
            let survivor = try #require(report.destinations
                .first { $0.url.path.hasPrefix(good.path) })
            #expect(survivor.outcome == .verified)
            #expect(survivor.totals.filesVerified == 2)
        }
    }

    /// Cancel is offered while a run is in flight and only then.
    @Test func cancelOnlyAppliesToARunningOffload() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.cancel()
            #expect(!model.isCancelling)
            #expect(controller.offloadStatus == nil)
        }
    }

    /// The takes-panel menu item still calls the old name; it has to keep
    /// opening the sheet until the footer reorg lands.
    @Test func theLegacyMenuEntryOpensTheSheet() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.showOffloadSheet()

            #expect(controller.offloadSheetPresented)
        }
    }

    // MARK: - the sheet closes over a live run (owner item 16)

    /// The sheet is dismissible now, and the run does not care: it is owned by
    /// the controller, and closing the window it was started from must not stop
    /// it, clear its progress or hide its status line.
    @Test func closingTheSheetLeavesTheRunGoing() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.isRunning = true
            model.progress = OffloadProgress(
                filesTotal: 128, bytesTotal: 1000, currentFile: "A001C001.mov",
                destinations: [], elapsed: 1, isCancelling: false)
            controller.offloadStatus = "Offload 41/128"

            // what the sheet's Close button does, and nothing else
            controller.offloadSheetPresented = false

            #expect(model.isRunning)
            #expect(model.progress != nil)
            #expect(controller.offloadStatus != nil)
        }
    }

    /// …and the way back in is the same menu item that opened it. Answering
    /// "an offload is already running" to somebody trying to WATCH that offload
    /// is the reason this needed saying twice.
    @Test func theMenuReopensARunningOffloadRatherThanRefusing() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.source = URL(fileURLWithPath: "/Volumes/CARD")
            model.addDestination(URL(fileURLWithPath: "/Volumes/SSD1"))
            model.isRunning = true
            model.report = nil
            controller.offloadSheetPresented = false

            controller.showOffloadSheet()

            #expect(controller.offloadSheetPresented)
            #expect(controller.lastError == nil, "it claimed to be busy")
            // and the sheet the operator gets back is the one still running,
            // not a form reset over the top of it
            #expect(controller.offload.destinations.count == 1)
        }
    }

    /// The strip's own button reaches whichever job is up, and Stop from the
    /// strip means the same thing as Stop in the sheet.
    @Test func theStripReachesAndStopsTheRunningJob() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.isRunning = true
            controller.offloadSheetPresented = false
            controller.verifySheetPresented = true

            controller.showRunningDiskJob()
            #expect(controller.offloadSheetPresented)
            #expect(!controller.verifySheetPresented)

            controller.cancelRunningDiskJob()
            #expect(model.isCancelling)
            #expect(!controller.verify.isCancelling, "it stopped the wrong job")
        }
    }
}
