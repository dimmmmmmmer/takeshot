import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **A run over camera originals that knows what the takes say** (owner: "а
/// можем ли мы рендерить дейлики из сорсов и чтоб пользователь отметил галку
/// допустим «синковать информацию с тейками», чтоб у нас ин/аут сработал
/// таким образом?").
///
/// End to end, because the parts that can go wrong are the joins: the reader's
/// window, the timecode that has to be re-based onto it, and the recipe that
/// has to know the item was trimmed.
@Suite(.timeLimit(.minutes(3))) struct DailiesSyncRunTests {
    /// 10:00:00:00 at 25 fps, in seconds since midnight — the fixture's own
    /// start timecode.
    private var tenAM: Double {
        Double(DailiesRig.startTC.frameNumber) / 25
    }

    private func candidate(range: ClipRange?, duration: Double = 4,
                           markers: [TakeMarker] = []) -> TakeSync.Candidate {
        TakeSync.Candidate(start: tenAM, duration: duration, name: "A001C001",
                           slate: SlateMetadata(scene: "12", shot: 1, take: 3),
                           markers: markers, range: range, rating: .good)
    }

    private func seconds(of url: URL) async throws -> Double {
        let track: AVAssetTrack = try #require(
            try await AVURLAsset(url: url).tracks(ofType: .video).first)
        return try await track.load(.timeRange).duration.seconds
    }

    /// **The in/out reaches the file.** A 100-frame source trimmed to
    /// 1…3 seconds comes out two seconds long.
    @Test func theInOutTrimsTheDaily() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0007.mov"), frames: 100)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [candidate(range: ClipRange(inPoint: 1, outPoint: 3))])
        let daily: URL = try #require(report.items.first?.output)
        let length = try await seconds(of: daily)
        #expect(abs(length - 2) < 0.1, "the daily is \(length)s long")
    }

    /// **And the proxy's timecode starts where the picture does.** A trimmed
    /// read keeps the clip's own timeline, so a track written from the clip's
    /// START would be a whole in-point out — and it would look right.
    @Test func theTrimmedProxyStartsAtTheInPointsTimecode() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0008.mov"), frames: 100)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [candidate(range: ClipRange(inPoint: 1, outPoint: 3))])
        let daily: URL = try #require(report.items.first?.output)
        let start: Timecode = try #require(
            await TimecodeReader.startTimecode(of: AVURLAsset(url: daily)),
            "the trimmed proxy has no timecode track")
        // the take starts at 10:00:00:00 and the in point is one second in
        #expect(start.description == "10:00:01:00", "\(start.description)")
    }

    /// The markers that survive the trim are chapters at their own moments,
    /// counted from the in point — and the ones outside it are gone.
    @Test func theChaptersFollowTheTrim() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0009.mov"), frames: 100)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [candidate(
                range: ClipRange(inPoint: 1, outPoint: 3),
                markers: [TakeMarker(seconds: 0.5, note: "before"),
                          TakeMarker(seconds: 1.5, note: "inside"),
                          TakeMarker(seconds: 3.5, note: "after")])])
        let daily: URL = try #require(report.items.first?.output)
        let asset = AVURLAsset(url: daily)
        let locales: [Locale] = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(
            withTitleLocale: try #require(locales.first),
            containingItemsWithCommonKeys: [])
        var titles: [String] = []
        for group in groups {
            let item = group.items.first { $0.commonKey == .commonKeyTitle }
            titles.append(try await item?.load(.stringValue) ?? "")
        }
        #expect(titles == ["inside"], "\(titles)")
    }

    /// A clip the day's takes have nothing to say about is rendered exactly as
    /// it was: a card holds footage from before the app was running.
    @Test func aClipThatMatchesNothingIsRenderedWhole() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0010.mov"), frames: 50)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            // a take an hour later: no overlap at all
            syncWith: [TakeSync.Candidate(start: tenAM + 3600, duration: 60,
                                          name: "A001C009")])
        let daily: URL = try #require(report.items.first?.output)
        #expect(abs(try await seconds(of: daily) - 2) < 0.1)
    }

    /// **A run that trims is a different deliverable.** The item's own marks
    /// are in its recipe, so a folder of whole dailies is not "already
    /// rendered" — and a take whose in point MOVED is rendered again.
    @Test func aTrimmedItemIsNotWhatTheFolderAlreadyHolds() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0011.mov"), frames: 100)
        let folder = root.appendingPathComponent("D")
        // whole first
        _ = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder,
            codec: .proResProxy, skipFinished: true)
        // …then trimmed: not the same daily, so not a skip
        let trimmed = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder,
            codec: .proResProxy,
            syncWith: [candidate(range: ClipRange(inPoint: 1, outPoint: 3))],
            skipFinished: true)
        #expect(trimmed.items.first?.wasSkipped == false,
                "a trimmed run skipped the whole daily")
        // …and running the SAME trim again is a skip
        let again = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder,
            codec: .proResProxy,
            syncWith: [candidate(range: ClipRange(inPoint: 1, outPoint: 3))],
            skipFinished: true)
        #expect(again.items.first?.wasSkipped == true,
                "the same trim rendered a second time")
    }
    // MARK: - only the circled takes, off a card

    /// **The switch the app could not offer for a card until now** (owner: "а,
    /// давай еще сделаем галку где-нибудь типа рендерить только удачные
    /// тейки"). A clip off a card has no rating of its own; matched to a take
    /// it has one, and the run can leave the rest.
    @Test func onlyTheCircledTakesAreRenderedOffACard() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0001.mov"), frames: 25)
        let bad = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0002.mov"), frames: 25)
        // one take over each clip, circled and not
        let takes = [TakeSync.Candidate(start: tenAM, duration: 1,
                                        name: "A001C001", rating: .good),
                     TakeSync.Candidate(start: tenAM, duration: 1,
                                        name: "A001C002", rating: .bad)]

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: good)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [takes[0]], circledOnly: true)
        #expect(report.items.first?.output != nil,
                "a circled take was left out")
        #expect(report.items.first?.wasFiltered == false)

        let rejected = await DailiesEngine.run(
            items: [DailiesRig.item(for: bad)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D2"), codec: .proResProxy,
            syncWith: [takes[1]], circledOnly: true)
        #expect(rejected.items.first?.wasFiltered == true,
                "a rejected take was rendered anyway")
        #expect(rejected.items.first?.output == nil)
        #expect(rejected.items.first?.failure == nil,
                "leaving a clip out is not a failure")
    }

    /// **A clip no take covers is left out too**, which is the literal reading
    /// of the switch: a clip nothing circled is not a circled take. It is
    /// REPORTED rather than dropped, so the length of the report still matches
    /// the queue's and the panel can say how many were left.
    @Test func aClipThatMatchesNothingIsLeftOutAndSaidSo() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0003.mov"), frames: 25)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            // a take an hour away: nothing matches
            syncWith: [TakeSync.Candidate(start: tenAM + 3600, duration: 60,
                                          name: "A001C009", rating: .good)],
            circledOnly: true)
        #expect(report.items.count == 1, "the report lost an item")
        #expect(report.items.first?.wasFiltered == true)
        #expect(report.filtered.count == 1)
    }

    /// …and with the switch OFF everything is rendered, whatever it is rated.
    @Test func withoutTheSwitchEveryClipIsRendered() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0004.mov"), frames: 25)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [TakeSync.Candidate(start: tenAM, duration: 1,
                                          name: "A001C001", rating: .bad)])
        #expect(report.items.first?.output != nil)
        #expect(report.filtered.isEmpty)
    }

    /// **A day with some clips left out is a day that succeeded.** The
    /// operator asked for them to be left, and a report that called the run
    /// unsuccessful for obeying would be the app arguing with the checkbox —
    /// which is what the panel would then show as a failure with nothing
    /// failed in it.
    @Test func leavingSomeClipsOutStillCountsAsASuccessfulRun() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0006.mov"), frames: 25)
        let bad = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0007.mov"), frames: 25)
        // both clips sit on the same moment; the takes differ in rating, and
        // the matcher gives each clip the take it shares the most with
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: good), DailiesRig.item(for: bad)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [TakeSync.Candidate(start: tenAM, duration: 1,
                                          name: "A001C001", rating: .good)],
            circledOnly: true)
        #expect(report.items.count == 2)
        #expect(report.filtered.isEmpty,
                "both clips match the circled take and both should render")
        #expect(report.isFullySucceeded)

        // …and now one of them matches NOTHING — a clip with no timecode at
        // all, which is what a camera original from before the app was
        // running looks like. It is left out, and the run is still a success.
        let stray = try await DailiesRig.writeForeignClip(
            at: root.appendingPathComponent("C0008.mp4"), frames: 10)
        let mixed = await DailiesEngine.run(
            items: [DailiesRig.item(for: good), DailiesRig.item(for: stray)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D2"), codec: .proResProxy,
            syncWith: [TakeSync.Candidate(start: tenAM, duration: 1,
                                          name: "A001C001", rating: .good)],
            circledOnly: true)
        #expect(mixed.items.count == 2)
        #expect(mixed.filtered.count == 1,
                "the clip that matched nothing was not left out")
        #expect(mixed.completed.count == 1)
        #expect(mixed.isFullySucceeded,
                "a run that left a clip out on purpose was called a failure")
    }

    /// **A run that left everything out is not a failed run.** The operator
    /// asked for it, and a report that called the day unsuccessful would be
    /// the app arguing with the checkbox.
    @Test func aRunThatLeftEverythingOutIsNotAFailure() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("C0005.mov"), frames: 25)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"), codec: .proResProxy,
            syncWith: [TakeSync.Candidate(start: tenAM, duration: 1,
                                          name: "A001C001", rating: .bad)],
            circledOnly: true)
        #expect(report.failed.isEmpty)
        #expect(!report.isFullySucceeded,
                "a run that made nothing did not make everything")
        #expect(report.filtered.count == report.items.count)
    }

}
