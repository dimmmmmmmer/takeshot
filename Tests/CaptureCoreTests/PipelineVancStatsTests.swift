import CoreMedia
import Foundation
import Testing
@testable import CaptureCore

/// The VANC monitor's numbers, from the frame path that produces them.
///
/// This is the instrument an operator reaches for when REC will not trigger: it
/// says which ancillary packets the board is actually delivering, how often, on
/// what line, and what is in them — which is how a vendor's own trigger format
/// gets reverse-engineered on set. The parser has always been covered; the
/// aggregation that feeds the panel had not been run at all.
@Suite struct PipelineVancStatsTests {
    private static let format = CaptureFormat(
        width: 320, height: 180, frameRate: 25, timecodeFPS: 25, name: "test 25")

    private func pipeline(root: URL) -> CapturePipeline {
        var settings = CaptureSettings()
        settings.capture.codec = .proResProxy
        settings.capture.destinationPath = root.path
        settings.capture.detectionMode = .manual // no take: this is about the monitor
        settings.capture.preRollSeconds = 0
        return CapturePipeline(config: .init(settings: settings,
                                             slate: .empty, takeNumber: 1))
    }

    /// Push frames carrying `packets` until the monitor publishes, at the live
    /// pace. The loop ends on the OUTCOME — the publication — rather than on a
    /// frame count, and the ceiling only decides whether a broken pipeline
    /// fails the test or spins forever.
    private func pushUntilPublished(_ pipeline: CapturePipeline,
                                    packets: [AncillaryPacket],
                                    published: EventCollector<[VancPacketStat]>,
                                    limit: Int = 200) async throws -> Int {
        let buffer = TestMedia.pixelBuffer()
        let timecode = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25)
        var index = 0
        while published.isEmpty, index < limit {
            index += 1
            pipeline.handleFrame(
                pixelBuffer: buffer,
                pts: CMTime(value: CMTimeValue(index * 40), timescale: 1000),
                timecode: timecode, vancTrigger: nil, ancillaryPackets: packets)
            try await Task.sleep(for: .milliseconds(20))
        }
        return index
    }

    @Test func theMonitorReportsWhatTheBoardIsActuallyDelivering() async throws {
        let root = TestMedia.scratchDirectory("VancStats")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let published = EventCollector<[VancPacketStat]>()
        pipeline.onVancStats = { published.append($0) }
        pipeline.handleFormat(Self.format)

        // two streams at once: a recognized trigger and a vendor packet nobody
        // has decoded yet — the second is the whole reason the monitor exists
        let trigger = AncillaryPacket(did: 0x51, sdid: 0x53, lineNumber: 9,
                                      data: [0x0A, 0x01, 0x00, 0x00])
        let unknown = AncillaryPacket(did: 0x41, sdid: 0x05, lineNumber: 13,
                                      data: [0xDE, 0xAD, 0xBE, 0xEF])
        let frames = try await pushUntilPublished(
            pipeline, packets: [trigger, unknown], published: published)

        let stats = try #require(published.first, "the monitor published nothing")
        #expect(stats.count == 2)
        // sorted by DID/SDID, so the panel's rows do not jump around
        #expect(stats.map(\.key) == ["41/05", "51/53"])

        let vendor = try #require(stats.first { $0.key == "41/05" })
        #expect(vendor.did == 0x41 && vendor.sdid == 0x05)
        #expect(vendor.lastLine == 13)
        #expect(vendor.lastDataHex == "DE AD BE EF")
        // one per frame since the session began — the tally is what says
        // whether a trigger is arriving at all. Bounded rather than exact: the
        // publication crosses to the main queue, so the feed is a frame or two
        // further on by the time the test sees it.
        #expect(vendor.count >= Int(Self.format.frameRate))
        #expect(vendor.count <= frames)
    }

    /// …at most about once a second, whatever the frame rate. Publishing every
    /// frame would poke the UI 25 times a second for a panel that is usually
    /// not even open.
    @Test func theMonitorIsNotPokedOnEveryFrame() async throws {
        let root = TestMedia.scratchDirectory("VancRate")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let published = EventCollector<[VancPacketStat]>()
        pipeline.onVancStats = { published.append($0) }
        pipeline.handleFormat(Self.format)

        let packet = AncillaryPacket(did: 0x60, sdid: 0x60, lineNumber: 10,
                                     data: [0x01])
        let frames = try await pushUntilPublished(pipeline, packets: [packet],
                                                  published: published)

        // the first publication waits out a whole second of frames
        #expect(frames >= Int(Self.format.frameRate),
                "the monitor published after only \(frames) frame(s)")
        #expect(published.all.count == 1)
    }

    /// A session that ends clears the counts: the next one's numbers are its
    /// own, and a panel still showing yesterday's tally is worse than an empty
    /// one — it says a trigger is arriving when nothing is connected.
    @Test func stoppingCaptureEmptiesTheMonitor() async throws {
        let root = TestMedia.scratchDirectory("VancReset")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = pipeline(root: root)
        let published = EventCollector<[VancPacketStat]>()
        pipeline.onVancStats = { published.append($0) }
        pipeline.handleFormat(Self.format)

        let packet = AncillaryPacket(did: 0x51, sdid: 0x53, lineNumber: 9,
                                     data: [0x0A, 0x01, 0x00, 0x00])
        _ = try await pushUntilPublished(pipeline, packets: [packet],
                                         published: published)
        try #require(published.first?.isEmpty == false)

        pipeline.captureStopped()

        #expect(await TestWait.becomesTrue(timeout: .seconds(5)) {
            published.last?.isEmpty == true
        }, "the monitor kept the old session's packets")
    }
}
