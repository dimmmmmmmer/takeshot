import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The app side of resuming an interrupted offload: what the operator is asked,
/// and that nothing is skipped before they answer.
///
/// The engine's gates are covered in CaptureCoreTests. What matters here is the
/// order of events — Start does not start a copy any more, it asks a question —
/// because a resume nobody agreed to is a silent skip, and `OffloadEngine`'s own
/// comment says a skipped folder is how footage goes missing.
@Suite @MainActor struct ControllerOffloadResumeTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-resume-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    /// Two files, one of them nested — five bytes in total.
    private func makeCard(_ name: String, salt: UInt8 = 0) throws -> URL {
        let source = try scratch(name)
        try Data([1 + salt, 2, 3])
            .write(to: source.appendingPathComponent("A001C001.mov"))
        let nested = source.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: nested,
                                                withIntermediateDirectories: true)
        try Data([4 + salt, 5])
            .write(to: nested.appendingPathComponent("A001C002.mov"))
        return source
    }

    /// Start, wait for the question, and hand it back.
    private func ask(_ model: OffloadSheetModel) async throws
        -> OffloadResumeReview {
        model.report = nil
        model.start()
        // The survey walks the card off the main thread, so this is an I/O wait
        // for an outcome — never a window in which it is assumed to have run.
        #expect(await ControllerWait.untilWritten { model.resumeReview != nil })
        return try #require(model.resumeReview)
    }

    // MARK: - the question

    /// The whole rule in one test: a second offload of the same card to the same
    /// disk asks first, says how much is already there, and copies nothing until
    /// the operator answers.
    @Test func theSheetAsksBeforeItSkipsAnything() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("ask-src")
            let dest = try self.scratch("ask-dst")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: dest)
            }
            let model = controller.offload
            model.source = source
            model.addDestination(dest)

            // A first offload has nothing to ask about and runs straight through.
            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })
            #expect(model.resumeReview == nil)
            #expect(model.report?.destinations.first?.resume == nil)

            let review = try await self.ask(model)

            #expect(review.card.files == 2)
            #expect(review.bestCase == 2)
            #expect(review.offers.first?.files == 2)
            #expect(review.offers.first?.isUsable == true)
            // nothing has started, and Start cannot be pressed again over it
            #expect(!model.isRunning)
            #expect(model.report == nil)
            #expect(!model.canStart)
            #expect(!model.isSurveying)
            // the takes-panel line is not claiming a run either
            #expect(controller.offloadStatus == nil)

            model.resumeRun()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            let result = try #require(model.report?.destinations.first)
            #expect(result.outcome == .verified)
            #expect(result.resume?.reused == 2)
            #expect(result.totals.bytesWritten == 0)
            #expect(result.totals.filesVerified == 2)
            #expect(controller.persistentAlert == nil)
            #expect(controller.lastNotice != nil)
        }
    }

    /// Copying the whole card is always the other answer, and taking it means the
    /// run is not a resume at all — nothing is reused and nothing is skipped.
    @Test func copyingTheWholeCardIsAlwaysOnOffer() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("all-src")
            let dest = try self.scratch("all-dst")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: dest)
            }
            let model = controller.offload
            model.source = source
            model.addDestination(dest)
            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })
            _ = try await self.ask(model)

            model.copyEverything()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            let result = try #require(model.report?.destinations.first)
            #expect(result.resume == nil, "it resumed anyway")
            #expect(result.totals.bytesWritten == 5)
            #expect(result.outcome == .verified)
            // the second copy is beside the first rather than over it — the
            // never-clobber rule, which only a resumed run is allowed to relax
            let folder = dest.appendingPathComponent(source.lastPathComponent)
            #expect(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("A001C001_2.mov").path))
        }
    }

    /// The status line says what the app is doing while it asks. It used to be
    /// possible to press Start and see nothing at all happen.
    @Test func theStatusLineSaysItIsCheckingTheDestinations() async throws {
        try await ControllerHarness.run { controller, _ in
            let source = try self.makeCard("status-src")
            let dest = try self.scratch("status-dst")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: dest)
            }
            let model = controller.offload
            model.source = source
            model.addDestination(dest)

            model.start()

            // set before the survey is dispatched, so this is a fact and not a
            // race: the operator never sees a dead sheet.
            #expect(model.isSurveying)
            #expect(controller.offloadStatus != nil)
            #expect(!model.canStart)
            #expect(await ControllerWait.untilWritten { model.report != nil })
        }
    }

    // MARK: - when there is nothing to ask about

    /// A disk holding another card's copy is not offered, and the run does not
    /// stop to say so: there is no question, because there is nothing this run
    /// could reuse. The destination's own summary records the refusal.
    @Test func aDiskHoldingAnotherCardsCopyIsNotOffered() async throws {
        try await ControllerHarness.run { controller, _ in
            let first = try self.makeCard("other-a")
            let second = try self.makeCard("other-b", salt: 40)
            let dest = try self.scratch("other-dst")
            defer {
                for url in [first, second, dest] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let model = controller.offload
            model.source = first
            model.addDestination(dest)
            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            // the same disk, the next card — and the copy already on it is named
            // after the OTHER card, so this one has its own folder anyway
            model.source = second
            model.report = nil
            model.start()
            #expect(await ControllerWait.untilWritten { model.report != nil })

            #expect(model.resumeReview == nil, "it asked about another card")
            let result = try #require(model.report?.destinations.first)
            #expect(result.outcome == .verified)
            #expect(result.totals.bytesWritten == 5)
        }
    }

    /// Reopening the sheet clears a question nobody answered, along with the last
    /// result: a stale "400 files are already there" over the next card is the
    /// same class of danger as a stale verdict.
    @Test func reopeningTheSheetClearsAnUnansweredQuestion() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.offload
            model.resumeReview = OffloadResumeReview(
                card: OffloadVolume(files: 900, bytes: 1000),
                offers: [OffloadResumeOffer(
                    destination: URL(fileURLWithPath: "/Volumes/SSD1/CARD"),
                    manifest: nil, claimed: [], refusal: nil)])

            controller.showOffloadSheet()

            #expect(model.resumeReview == nil)
        }
    }
}
