import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

/// **The take's timecode, carried into the proxy as a TRACK** (owner: "таймкод
/// дорожку в прокси").
///
/// The burn-in has always put the timecode in the PICTURE, which an operator
/// reads and no machine can. An editor conforming a daily back to the camera
/// original needs it as a track, which is what every NLE reads to place a clip
/// in time — and what an assistant otherwise types in by hand off the strip,
/// once per take, all day.
///
/// **These runs are ProRes on purpose.** A `tmcd` track is a QuickTime affair
/// and an MPEG-4 writer refuses one outright — measured, as an aborted process
/// before `canAdd` was asked. So an H.264 daily, which is an `.mp4`, has no
/// timecode track and cannot have one; that is pinned below too, beside the
/// sheet's own line about it.
/// **A time limit on the whole suite, because the failure mode is a HANG.**
/// An `AVAssetWriter` that is not real time holds every input back until the
/// laggard catches up, and an input with no samples lags for ever — writing
/// these four bytes at the END of the transcode meant the transcode never
/// reached its end, and the suite sat at 100 % with no output at all. A run
/// that never ends looks like a slow machine; a minute against the second
/// this takes is what tells them apart.
@Suite(.timeLimit(.minutes(1))) struct DailiesTimecodeTrackTests {
    private func timecodeTrack(of url: URL) async throws -> AVAssetTrack? {
        try await AVURLAsset(url: url).tracks(ofType: .timecode).first
    }

    /// The proxy's track reads the take's own start timecode.
    @Test func theProxyCarriesTheTakesTimecode() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C001.mov"), frames: 25)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        let daily: URL = try #require(report.items.first?.output,
                                      "the take produced no daily")
        let read = await TimecodeReader.startTimecode(of: AVURLAsset(url: daily))
        let start: Timecode = try #require(read, """
            the proxy has no timecode track — an editor conforming it has \
            nothing to conform against
            """)
        #expect(start.frameNumber == DailiesRig.startTC.frameNumber, """
            the proxy starts at \(start.description) where the take starts at \
            \(DailiesRig.startTC.description)
            """)
        #expect(start.fps == DailiesRig.startTC.fps)
    }

    /// **And it covers the whole picture.** A track that stops early is worse
    /// than none: the first half of the clip conforms and the rest reads as
    /// whatever the tool decides to do about a gap.
    @Test func theTrackRunsAsLongAsThePicture() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C002.mov"), frames: 50)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        let daily: URL = try #require(report.items.first?.output)
        let asset = AVURLAsset(url: daily)
        let video: AVAssetTrack = try #require(
            try await asset.tracks(ofType: .video).first)
        let timecode: AVAssetTrack = try #require(try await timecodeTrack(of: daily),
                                                  "the proxy has no timecode track")
        let picture = try await video.load(.timeRange).duration.seconds
        let clock = try await timecode.load(.timeRange).duration.seconds
        #expect(abs(picture - clock) < 0.1, """
            the picture runs \(picture)s and its timecode track \(clock)s
            """)
    }

    /// **A clip with no timecode gets no track**, rather than one claiming
    /// midnight. A proxy that says 00:00:00:00 conforms alongside every other
    /// untimecoded clip in the bin at exactly the same place on the timeline,
    /// which is a worse answer than an honest silence — and the burn-in's own
    /// zero counter is deliberately NOT the same decision (a strip that counts
    /// beats an empty one; see `DailiesEngine.timecodeTrack`).
    @Test func aClipWithNoTimecodeGetsNoTimecodeTrack() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeForeignClip(
            at: root.appendingPathComponent("FOREIGN.mp4"), frames: 10)
        let item = DailiesItem(source: source, outputName: "FOREIGN_DAILY",
                               clipName: "FOREIGN", startTimecode: nil)
        let report = await DailiesEngine.run(
            items: [item], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        #expect(report.isFullySucceeded, "items failed: \(report.failed)")
        let daily: URL = try #require(report.items.first?.output)
        let track = try await timecodeTrack(of: daily)
        #expect(track == nil, """
            a clip with no timecode of its own came out with a timecode track \
            — that is a number this app invented
            """)
    }

    /// **An MP4 daily has no timecode track, and that is the CONTAINER.**
    ///
    /// Pinned rather than left as a surprise: the same take rendered ProRes
    /// carries its timecode and rendered H.264 does not, so an assistant who
    /// has to conform has a codec to choose — and the sheet says so under the
    /// picker (`dailies_mp4_limit`).
    @Test func anMP4DailyHasNoTimecodeTrack() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C005.mov"), frames: 10)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"), codec: .h264)
        #expect(report.isFullySucceeded, "items failed: \(report.failed)")
        let daily: URL = try #require(report.items.first?.output)
        #expect(daily.pathExtension == "mp4")
        #expect(!CaptureCodec.h264.dailyCarriesQuickTimeExtras)
        let track = try await timecodeTrack(of: daily)
        #expect(track == nil, """
            an MP4 came out WITH a timecode track — then the container takes \
            one after all and the line under the codec picker is wrong
            """)
    }

    /// …and the take's REMEMBERED start is enough on its own: a camera
    /// original with no timecode track is still a take this app recorded the
    /// start timecode of, and that is a fact about the footage rather than an
    /// invention.
    @Test func theRememberedStartIsEnoughForATrack() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeForeignClip(
            at: root.appendingPathComponent("CARD.mp4"), frames: 10)
        let item = DailiesItem(source: source, outputName: "CARD_DAILY",
                               clipName: "CARD",
                               startTimecode: DailiesRig.startTC)
        let report = await DailiesEngine.run(
            items: [item], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy)
        let daily: URL = try #require(report.items.first?.output)
        let read = await TimecodeReader.startTimecode(of: AVURLAsset(url: daily))
        let start: Timecode = try #require(read, "no track off a remembered start")
        #expect(start.frameNumber == DailiesRig.startTC.frameNumber)
    }
}
