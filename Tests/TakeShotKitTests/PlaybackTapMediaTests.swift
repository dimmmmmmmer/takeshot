import AVFoundation
import CaptureCore
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// The playback tap pulling frames out of a real AVPlayer.
///
/// `ModelPlaybackTapTests` covers the composite with hand-built buffers; this
/// suite is the other half of the same contract — that the tap gets anything at
/// all out of a decoded clip. The pull side is where playback silently stops
/// working: an output attached to the wrong item, a poll timer that never
/// starts, or a pixel-format request the decoder refuses all show up as a black
/// player with a running transport, and none of them are visible without media.
@Suite @MainActor struct PlaybackTapMediaTests {
    /// A muted player on `url`, wired to `tap` and rolling. Muted twice over:
    /// the fixtures write silent audio and these clips carry no audio track at
    /// all, and even so nothing in a test suite may open an output device.
    private func startPlayback(of url: URL,
                               through tap: PlaybackFrameTap) -> AVPlayer {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.isMuted = true
        tap.attach(to: item)
        tap.setRunning(true)
        player.play()
        return player
    }

    private func stop(_ player: AVPlayer, _ tap: PlaybackFrameTap) {
        player.pause()
        tap.setRunning(false)
        tap.detach()
        tap.setOnDisplayFrame(nil)
    }

    /// Frames arrive, at the clip's own size. The size is the assertion that
    /// matters: the tap requests 32BGRA and a decoder that hands back something
    /// else would deliver an empty extent, which reads on screen as black.
    @Test func framesFromARealClipArriveAtTheClipsSize() async throws {
        let media = try MediaFixtures.makeDirectory("tap-frames")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("clip.mov"), frames: 40)

        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0) }
        let player = startPlayback(of: clip, through: tap)
        defer { stop(player, tap) }

        let arrived = await ControllerWait.untilWritten { collector.count > 0 }
        #expect(arrived, "no frame ever came out of the player")
        let frame = try #require(collector.last)
        #expect(CVPixelBufferGetWidth(frame) == 320)
        #expect(CVPixelBufferGetHeight(frame) == 180)
        #expect(CVPixelBufferGetPixelFormatType(frame)
                == kCVPixelFormatType_32BGRA)
        // …and the pin-as-reference read sees the same frame
        #expect(tap.currentBuffer() != nil)
    }

    /// Compare against the live signal, on decoded frames rather than
    /// hand-filled ones: left of the seam is the clip, right of it is live.
    @Test func aWipeOverRealFramesShowsTheClipAgainstTheLiveSignal() async throws {
        let media = try MediaFixtures.makeDirectory("tap-wipe")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("dark.mov"), frames: 40, level: 0x20)

        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0) }
        let live = MediaFixtures.pixelBuffer(level: 0xE0)
        tap.setLiveBufferProvider { live }
        tap.setCompare(.wipe(axis: .vertical, position: 0.5))
        let player = startPlayback(of: clip, through: tap)
        defer { stop(player, tap) }

        let composed = await ControllerWait.untilWritten {
            guard let frame = collector.last else { return false }
            return MediaFixtures.sample(frame, atFractionX: 0.9).r > 0xA0
        }
        #expect(composed, "the live half never reached the composite")
        let frame = try #require(collector.last)
        #expect(CVPixelBufferGetWidth(frame) == 320)
        let left = MediaFixtures.sample(frame, atFractionX: 0.1)
        let right = MediaFixtures.sample(frame, atFractionX: 0.9)
        #expect(left.r < 0x60, "left of the seam is not the clip: \(left.r)")
        #expect(right.r > 0xA0, "right of the seam is not live: \(right.r)")
    }

    /// Take vs take: with a B-side clip set, the back half must come from that
    /// clip and NOT from the live signal — the whole point of the mode is
    /// comparing two recordings while the camera is pointed somewhere else.
    @Test func aBSideClipFeedsTheBackHalfInsteadOfTheLiveSignal() async throws {
        let media = try MediaFixtures.makeDirectory("tap-bside")
        defer { try? FileManager.default.removeItem(at: media) }
        let front = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("a.mov"), frames: 50, level: 0x20)
        let back = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("b.mov"), frames: 50, level: 0xE0)

        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0) }
        // a mid-grey live signal, so a back half that came from the camera
        // instead of the B clip is unmistakable
        let live = MediaFixtures.pixelBuffer(level: 0x80)
        tap.setLiveBufferProvider { live }
        tap.setCompare(.wipe(axis: .vertical, position: 0.5))
        let player = startPlayback(of: front, through: tap)
        defer { stop(player, tap) }
        tap.setCompareClip(url: back, syncTo: player)

        let composed = await ControllerWait.untilWritten {
            guard let frame = collector.last else { return false }
            return MediaFixtures.sample(frame, atFractionX: 0.9).r > 0xB0
        }
        #expect(composed, "the B clip never reached the back half of the wipe")
        let frame = try #require(collector.last)
        let left = MediaFixtures.sample(frame, atFractionX: 0.1)
        #expect(left.r < 0x60, "the front half is not clip A: \(left.r)")
    }

    /// The preview LUT, built from a real .cube on disk and applied to decoded
    /// frames. A LUT that parses but does not reach the player is the failure
    /// mode an operator reads as "the show LUT does nothing in playback".
    @Test func aCubeFromDiskReachesDecodedFrames() async throws {
        let media = try MediaFixtures.makeDirectory("tap-lut")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("grey.mov"), frames: 40, level: 0x80)
        let cubeURL = try MediaFixtures.writeRedCube(
            at: media.appendingPathComponent("red.cube"))
        let cube = try CubeLUT.load(url: cubeURL)
        #expect(cube.size == 2)

        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0) }
        let filter: CIFilter = try #require(cube.makeFilter())
        tap.setLUT(filter, intensity: 1)
        let player = startPlayback(of: clip, through: tap)
        defer { stop(player, tap) }

        let graded = await ControllerWait.untilWritten {
            guard let frame = collector.last else { return false }
            let pixel = MediaFixtures.sample(frame, atFractionX: 0.5)
            return pixel.r > pixel.g + 60 && pixel.r > pixel.b + 60
        }
        let pixel = MediaFixtures.sample(try #require(collector.last),
                                         atFractionX: 0.5)
        #expect(graded,
                "the .cube never reached the frame: \(pixel.r)/\(pixel.g)/\(pixel.b)")
    }

    /// Scopes read the COMPOSED output, not the frame that came off the
    /// decoder: an operator judging exposure through a show LUT has to be
    /// measuring what is on the screen.
    @Test func scopesMeasureTheGradedFrameAndNotTheDecodedOne() async throws {
        let media = try MediaFixtures.makeDirectory("tap-scopes")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("grey.mov"), frames: 50, level: 0x80)
        let cube = try CubeLUT.load(url: MediaFixtures.writeRedCube(
            at: media.appendingPathComponent("red.cube")))

        let tap = PlaybackFrameTap()
        let scopes = ScopeCollector()
        tap.onScopeData = { scopes.record($0) }
        let filter: CIFilter = try #require(cube.makeFilter())
        tap.setLUT(filter, intensity: 1)
        tap.setScopesEnabled(true)
        let player = startPlayback(of: clip, through: tap)
        defer { stop(player, tap) }

        let measured = await ControllerWait.untilWritten { scopes.last != nil }
        #expect(measured, "no scope data came out of playback")
        let data = try #require(scopes.last)
        let red = Self.meanBin(data.histR)
        let green = Self.meanBin(data.histG)
        #expect(red > green + 60,
                "the scopes measured the ungraded frame: R\(red) G\(green)")
    }

    /// Turning scopes off has to stop the analysis: it runs per frame and the
    /// player is not the only thing that needs the CPU during a take.
    @Test func scopeAnalysisStopsWhenTheScopesClose() async throws {
        let media = try MediaFixtures.makeDirectory("tap-scopes-off")
        defer { try? FileManager.default.removeItem(at: media) }
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("clip.mov"), frames: 50)

        let tap = PlaybackFrameTap()
        let scopes = ScopeCollector()
        tap.onScopeData = { scopes.record($0) }
        tap.setScopesEnabled(true)
        let player = startPlayback(of: clip, through: tap)
        defer { stop(player, tap) }

        await ControllerWait.untilWritten { scopes.count > 0 }
        tap.setScopesEnabled(false)
        tap.queue.sync {}
        let settled = scopes.count
        // a full short budget rather than a single sleep: this is the direction
        // where the assertion is that nothing more happens
        await ControllerWait.until({ scopes.count > settled + 1 },
                                   timeout: .seconds(2))
        #expect(scopes.count <= settled + 1,
                "analysis kept running after the scopes closed")
    }

    /// Registration is per mount (one layer lives in one view), and unmounting
    /// has to take the layer back out or a closed fullscreen window keeps being
    /// drawn into for the rest of the session.
    @Test func sinksJoinAndLeaveTheTap() {
        let tap = PlaybackFrameTap()
        let layer = MetalPreviewLayer()
        #expect(tap.sinks.all().isEmpty)

        tap.addSink(layer)
        #expect(tap.sinks.all().count == 1)
        tap.setViewAssist(ViewAssist())
        tap.setLetterbox(CIColor(red: 0, green: 0, blue: 1))
        #expect(abs(layer.letterboxColor.blue - 1) < 0.001)

        tap.removeSink(layer)
        #expect(tap.sinks.all().isEmpty)
    }

    /// The weighted mean bin of a 256-bin histogram — "where the channel sits".
    private static func meanBin(_ histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let weighted = histogram.enumerated().reduce(0) { $0 + $1.offset * $1.element }
        return weighted / total
    }
}

/// Scope data is handed over on the main queue while the test polls from the
/// main actor; a lock keeps the two honest without an actor hop.
private final class ScopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScopeData] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    var last: ScopeData? {
        lock.lock()
        defer { lock.unlock() }
        return items.last
    }

    func record(_ data: ScopeData) {
        lock.lock()
        items.append(data)
        lock.unlock()
    }
}
