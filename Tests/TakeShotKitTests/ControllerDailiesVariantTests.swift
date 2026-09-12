import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **More versions of the same day, in one pass over the footage** (owner: "и
/// да, очередь из нескольких вариантов дейликов будет супер").
///
/// The whole value is that nobody has to come back and start a second batch,
/// so what has to hold is that ONE press produces every version — under names
/// that tell them apart, at the sizes and in the codecs they were asked for,
/// and with the queue's own bar counting all of it.
@Suite @MainActor struct ControllerDailiesVariantTests {
    /// **A 1080p source**, because the point of a ceiling is what it does to a
    /// picture bigger than itself: the suite's usual 320x180 fixture comes out
    /// 320x180 under every ceiling there is, and a test of that proves the
    /// never-upscale rule and nothing about the choice.
    private func recordedTake(named name: String, in folder: URL,
                              frames: Int = 25) async throws -> Take {
        let url = try await MediaFixtures.writeClip(
            at: folder.appendingPathComponent("\(name).mov"),
            format: MediaFixtures.format(width: 1920, height: 1080),
            frames: frames)
        return Take(url: url, scene: "", roll: "001", takeNumber: 1,
                    startTimecode: MediaFixtures.startTimecode,
                    durationSeconds: Double(frames) / 25, recordedAt: Date())
    }

    private func raster(of url: URL) async throws -> CGSize {
        let track: AVAssetTrack = try #require(
            try await AVURLAsset(url: url).tracks(ofType: .video).first)
        return try await track.load(.naturalSize)
    }

    /// One press, two files per take, each at its own ceiling.
    @Test func oneRunProducesEveryVersionOfEveryTake() async throws {
        try await ControllerHarness.run { controller, _ in
            let media = try MediaFixtures.makeDirectory("dailies-variants")
            defer { try? FileManager.default.removeItem(at: media) }
            let takes = [try await self.recordedTake(named: "one", in: media),
                         try await self.recordedTake(named: "two", in: media)]
            let folder = media.appendingPathComponent("Dailies")

            controller.dailies.prepare(takes: takes,
                                       settings: controller.settings,
                                       defaultFolder: folder)
            controller.dailies.resolution = .hd
            controller.dailies.extraVariants = [
                DailiesVariant(resolution: .sd, codec: .h264,
                               suffix: "_PHONE"),
            ]
            controller.dailies.start()
            await ControllerWait.untilWritten {
                controller.dailies.report != nil
            }
            let report = try #require(controller.dailies.report)
            #expect(report.isFullySucceeded, "items failed: \(report.failed)")
            #expect(report.items.count == 4,
                    "the report covers \(report.items.count) items")

            for name in ["one_DAILY.mov", "two_DAILY.mov",
                         "one_PHONE.mov", "two_PHONE.mov"] {
                #expect(FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(name).path),
                    "\(name) is missing")
            }
            // …and each version really is its own size
            let daily = try await self.raster(
                of: folder.appendingPathComponent("one_DAILY.mov"))
            let phone = try await self.raster(
                of: folder.appendingPathComponent("one_PHONE.mov"))
            #expect(daily.height == 1080, "the daily is \(daily)")
            #expect(phone.height == 540, "the phone copy is \(phone)")
            #expect(phone.width < daily.width,
                    "\(phone) is not smaller than \(daily)")
        }
    }

    /// **The bar counts the whole run**, in two numbers that go wrong
    /// differently: without the offset it jumps back to the start of the line
    /// at every pass, and without the total it fills up and starts again.
    /// Pinned directly, because a polled progress value can miss a snapshot
    /// and a test that could miss one is a test that sometimes passes.
    @Test func aPassesSnapshotIsRenumberedOntoTheWholeRun() {
        let snapshot = DailiesProgress(
            itemIndex: 1, itemCount: 2, currentFile: "one.mov",
            framesDone: 10, framesTotal: 50, isPaused: false,
            isCancelling: false)
        let whole = DailiesQueueModel.whole(snapshot, after: 4, of: 6)
        #expect(whole.itemIndex == 5, "the bar jumped back to the line's start")
        #expect(whole.itemCount == 6, "the bar counted one pass")
        // everything else about the item in flight is untouched
        #expect(whole.currentFile == "one.mov")
        #expect(whole.framesDone == 10)
        #expect(whole.framesTotal == 50)
        // …and the first pass is exactly what the engine said
        #expect(DailiesQueueModel.whole(snapshot, after: 0, of: 2) == snapshot)
    }

    /// **The bar counts the whole run.** Each engine call reports "item i of
    /// its own list" and the operator is watching one queue, so a two-variant
    /// run over two takes is four items — not two, twice.
    @Test func theProgressBarCountsEveryPass() async throws {
        try await ControllerHarness.run { controller, _ in
            let media = try MediaFixtures.makeDirectory("dailies-variant-bar")
            defer { try? FileManager.default.removeItem(at: media) }
            let takes = [try await self.recordedTake(named: "one", in: media)]
            let folder = media.appendingPathComponent("Dailies")

            controller.dailies.prepare(takes: takes,
                                       settings: controller.settings,
                                       defaultFolder: folder)
            controller.dailies.extraVariants = [
                DailiesVariant(resolution: .sd, codec: .h264, suffix: "_A"),
                DailiesVariant(resolution: .hd720, codec: .h264, suffix: "_B"),
            ]
            var counts: Set<Int> = []
            controller.dailies.start()
            await ControllerWait.untilWritten {
                if let count = controller.dailies.progress?.itemCount {
                    counts.insert(count)
                }
                return controller.dailies.report != nil
            }
            #expect(counts == [3],
                    "the bar counted \(counts.sorted()) items, not three")
        }
    }

    /// An empty list is the run this app has always made — same items, same
    /// names, same count.
    @Test func noExtraVersionsIsTheRunItAlwaysWas() async throws {
        try await ControllerHarness.run { controller, _ in
            let media = try MediaFixtures.makeDirectory("dailies-variant-none")
            defer { try? FileManager.default.removeItem(at: media) }
            let takes = [try await self.recordedTake(named: "one", in: media)]
            let folder = media.appendingPathComponent("Dailies")

            controller.dailies.prepare(takes: takes,
                                       settings: controller.settings,
                                       defaultFolder: folder)
            #expect(controller.dailies.extraVariants.isEmpty)
            controller.dailies.start()
            await ControllerWait.untilWritten {
                controller.dailies.report != nil
            }
            let report = try #require(controller.dailies.report)
            #expect(report.items.count == 1)
            let written = try FileManager.default
                .contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasSuffix(".mov") }
            #expect(written == ["one_DAILY.mov"], "\(written)")
        }
    }

    // MARK: - the list itself

    /// A new row is a SMALLER copy of the daily rather than an empty form, and
    /// it never lands on a suffix the list is already using: two variants with
    /// one suffix is two passes writing over each other's names.
    @Test func addingAVersionSeedsSomethingUsableAndUnique() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.dailies
            model.resolution = .hd
            model.addVariant()
            model.addVariant()
            model.addVariant()
            #expect(model.extraVariants.count == 3)
            #expect(Set(model.extraVariants.map(\.suffix)).count == 3,
                    Comment(rawValue: "two versions share a suffix: "
                        + "\(model.extraVariants.map(\.suffix))"))
            for variant in model.extraVariants {
                #expect(variant.resolution != .hd,
                        "a second copy the same size as the first buys nothing")
                #expect(!variant.suffix.isEmpty)
            }
        }
    }

    /// The ceiling is the list's, and the button stops at it: the cost of a
    /// variant is a decode of every take, not a row.
    @Test func theListStopsAtItsCeiling() async throws {
        try await ControllerHarness.run { controller, _ in
            let model = controller.dailies
            for _ in 0..<(DailiesVariant.limit + 4) { model.addVariant() }
            #expect(model.extraVariants.count == DailiesVariant.limit)
            #expect(!controller.canAddDailiesVariant)
            model.removeVariant(try #require(model.extraVariants.first).id)
            #expect(controller.canAddDailiesVariant)
        }
    }

    /// They persist like every other choice on that sheet — a show that ships
    /// a phone copy ships one every day.
    @Test func theVersionsPersistLikeEveryOtherChoice() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.dailies.extraVariants = [
                DailiesVariant(resolution: .sd, codec: .h264, suffix: "_PHONE"),
            ]
            controller.rememberDailiesChoices(from: controller.dailies)
            #expect(controller.settings.dailies.variants == ["540|H.264|_PHONE"])

            let model = DailiesQueueModel()
            model.prepare(takes: [], settings: controller.settings,
                          defaultFolder: URL(fileURLWithPath: "/tmp"))
            #expect(model.extraVariants.map(\.suffix) == ["_PHONE"])
            #expect(model.extraVariants.first?.resolution == .sd)

            // …and an empty list writes no key at all, so a blob from a build
            // without this feature is what a run with no extras produces
            controller.dailies.extraVariants = []
            controller.rememberDailiesChoices(from: controller.dailies)
            #expect(controller.settings.dailies.variants == nil)
        }
    }
}
