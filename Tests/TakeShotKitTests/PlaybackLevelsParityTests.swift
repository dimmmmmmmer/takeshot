import AVFoundation
import CaptureCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// A take has to play back as the monitor showed it while it was recording.
///
/// The two halves are far apart and neither can see the other: the capture
/// pipeline expands the wire for the screen and writes the WIRE codes to the
/// file, and the player reads that file back through the decoder. Those are
/// different code paths with different arithmetic, and a video-range picture
/// shown without expansion is washed blacks — this app's oldest colour bug. So
/// the invariant is measured end to end here, on one synthetic frame whose
/// codes are known, recorded and played back for real.
@Suite struct PlaybackLevelsParityTests {
    /// Footroom, nominal black, a mid tone, nominal white, headroom.
    private static let wire = [4, 64, 500, 940, 1019]
    private static let bandWidth = 64
    private static let width = wire.count * bandWidth
    private static let height = 64

    /// The centre of each band, as a fraction across the frame.
    private static func bandFraction(_ band: Int) -> Double {
        (Double(band) + 0.5) / Double(wire.count)
    }

    /// An r210 wire frame of vertical bands, grey so nothing here measures
    /// chroma subsampling.
    private static func wireFrame() -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            TenBitConverter.r210,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &out)
        guard let buffer = out else { fatalError("no r210 buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let code = UInt32(wire[x / bandWidth])
                row[x] = ((code << 20) | (code << 10) | code).bigEndian
            }
        }
        return buffer
    }

    private func bandValues(_ buffer: CVPixelBuffer) -> [Int] {
        (0..<Self.wire.count).map {
            MediaFixtures.sample(buffer, atFractionX: Self.bandFraction($0)).r
        }
    }

    /// Record the wire frame as a take and report both what the monitor showed
    /// and where the file landed.
    private func recordTake(in root: URL) async throws -> (take: Take,
                                                           shown: CVPixelBuffer) {
        var settings = CaptureSettings()
        settings.destinationPath = root.path
        settings.detectionMode = .manual // the take is started here, by hand
        settings.preRollFrames = 0
        settings.codec = .proResProxy    // the suite encodes in real time
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.setVideoLevels("limited")
        pipeline.handleFormat(CaptureFormat(width: Self.width, height: Self.height,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "bands", isRGB444: true))
        let collector = MediaFixtures.FrameCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        let takes = TakeSink()
        pipeline.onTakeFinished = { takes.record($0) }

        let source = Self.wireFrame()
        // the signal is running before REC is pressed, as it is on a set — the
        // take states what its codes mean, and the levels stage is what knows
        func push(_ frames: ClosedRange<Int>) async throws {
            for frame in frames {
                pipeline.handleFrame(
                    pixelBuffer: source,
                    pts: CMTime(value: CMTimeValue(frame * 40), timescale: 1000),
                    timecode: nil, vancTrigger: nil)
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await push(1...3)
        pipeline.toggleManualRecord()
        try await push(4...15)
        pipeline.toggleManualRecord()
        _ = await ControllerWait.untilWritten { takes.last != nil }
        await pipeline.finishPendingWrites()
        let take = try #require(takes.last, "no take was finished")
        return (take, try #require(collector.last, "nothing reached the screen"))
    }

    /// What the file holds before the player expands anything — the same read a
    /// foreign tool would make.
    private func decodedWithoutExpansion(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer(),
                                  "the take decoded no frames")
        return bandValues(try #require(CMSampleBufferGetImageBuffer(sample)))
    }

    @Test func aTakePlaysBackExactlyAsTheMonitorShowedIt() async throws {
        let root = try MediaFixtures.makeDirectory("levels-parity")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = try await recordTake(in: root)

        // the monitor: the nominal pair on the ends, the excursions clipped
        let live = bandValues(recorded.shown)
        #expect(live == [0, 0, 127, 255, 255], "live display: \(live)")

        // the file, read the way any other tool reads it: studio swing, which
        // is washed until something expands it — if this ever equals `live`
        // the test below has stopped proving anything
        let raw = try await decodedWithoutExpansion(recorded.take.url)
        #expect(raw[1] > 12, "the file is not carrying wire codes: \(raw)")

        // the player: attach the way the app does and let the tap read the
        // file's own statement of what its codes mean
        let tap = PlaybackFrameTap()
        let shown = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { shown.record($0) }
        let item = AVPlayerItem(url: recorded.take.url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.isMuted = true
        tap.attach(to: item, url: recorded.take.url)
        tap.setRunning(true)
        player.play()
        defer {
            player.pause()
            tap.setRunning(false)
            tap.detach()
            tap.setOnDisplayFrame(nil)
        }
        let told = await ControllerWait.untilWritten { tap.carriesWireCodes }
        #expect(told, "the take never told the player what it carries")
        let mark = shown.count
        _ = await ControllerWait.untilWritten { shown.count > mark + 1 }

        let playback = bandValues(try #require(shown.last, "no frame was played"))
        // ±2 is the ProRes round trip (measured), not slack for a second
        // opinion about levels: three of the five bands come back exact
        let both = "all live \(live), playback \(playback)"
        for (band, value) in playback.enumerated() {
            #expect(abs(value - live[band]) <= 2,
                    "band \(band): live \(live[band]) vs \(value); \(both)")
        }
    }

    /// Collects finished takes off the pipeline's callback queue.
    private final class TakeSink: @unchecked Sendable {
        private let lock = NSLock()
        private var takes: [Take] = []

        func record(_ take: Take) {
            lock.lock()
            takes.append(take)
            lock.unlock()
        }

        var last: Take? {
            lock.lock()
            defer { lock.unlock() }
            return takes.last
        }
    }
}
