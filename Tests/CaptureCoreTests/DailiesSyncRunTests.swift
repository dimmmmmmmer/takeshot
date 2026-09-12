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
}
