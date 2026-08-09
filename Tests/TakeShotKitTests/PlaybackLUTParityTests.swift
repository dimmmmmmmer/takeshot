import AVFoundation
import CaptureCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TakeShotKit

/// Live and playback have to render the same look the same way.
///
/// This is the invariant the whole colour pipeline is arranged around: the LUT
/// is applied to raw code values on BOTH sides, because a colour-managed render
/// on one of them made the same clip look different in the player than it did
/// on the camera feed — with the LUT on, an operator wiping between live and
/// playback saw a contrast step that no setting explained. The two paths are
/// separate code (`CapturePipeline.applyLUT` and the tap's own compose), so
/// nothing but a test that runs both keeps them together.
@Suite @MainActor struct PlaybackLUTParityTests {
    /// A 2³ .cube that halves every value. Linear inside the cube, so trilinear
    /// interpolation is exact and both paths should land on the same number
    /// rather than merely "somewhere darker".
    private static let halfCube = """
        TITLE "half"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        0.5 0.0 0.0
        0.0 0.5 0.0
        0.5 0.5 0.0
        0.0 0.0 0.5
        0.5 0.0 0.5
        0.0 0.5 0.5
        0.5 0.5 0.5
        """

    /// What the live pipeline puts on screen for one grey frame.
    private func liveGraded(_ cube: CubeLUT, level: UInt8) async -> CVPixelBuffer? {
        var settings = CaptureSettings()
        settings.capture.detectionMode = .manual // nothing here may open a take
        let pipeline = CapturePipeline(config: .init(settings: settings,
                                                     takeNumber: 1))
        pipeline.handleFormat(CaptureFormat(width: 320, height: 180,
                                            frameRate: 25, timecodeFPS: 25,
                                            name: "test"))
        let collector = MediaFixtures.FrameCollector()
        pipeline.setOnDisplayFrame { collector.record($0) }
        defer { pipeline.setOnDisplayFrame(nil) }
        pipeline.setLUT(cube, preview: true, record: false, intensity: 1)

        let source = MediaFixtures.pixelBuffer(level: level)
        pipeline.handleFrame(pixelBuffer: source,
                            pts: CMTime(value: 40, timescale: 1000),
                            timecode: nil, vancTrigger: nil)
        await ControllerWait.untilWritten {
            collector.last != nil && collector.last !== source
        }
        return collector.last
    }

    /// The same look, applied to the same grey through the playback tap, has to
    /// come out at the same code value.
    @Test func theSameLookLandsOnTheSameCodeValueLiveAndInPlayback() async throws {
        let media = try MediaFixtures.makeDirectory("lut-parity")
        defer { try? FileManager.default.removeItem(at: media) }
        let grey: UInt8 = 0x80
        let clip = try await MediaFixtures.writeClip(
            at: media.appendingPathComponent("grey.mov"), frames: 40, level: grey)
        let cube = try CubeLUT.parse(Self.halfCube)

        // live: a raw BGRA frame through the capture pipeline
        let live = try #require(await liveGraded(cube, level: grey),
                                "the live path produced no graded frame")
        let livePixel = MediaFixtures.sample(live, atFractionX: 0.5)

        // playback: the same grey, encoded, decoded, and graded by the tap
        let tap = PlaybackFrameTap()
        let collector = MediaFixtures.FrameCollector()
        tap.setOnDisplayFrame { collector.record($0) }
        tap.setLUT({ cube.makeFilter() }, intensity: 1)
        let item = AVPlayerItem(url: clip)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.isMuted = true
        tap.attach(to: item, url: clip)
        tap.setRunning(true)
        player.play()
        defer {
            player.pause()
            tap.setRunning(false)
            tap.detach()
            tap.setOnDisplayFrame(nil)
        }

        let arrived = await ControllerWait.untilWritten { collector.count > 0 }
        #expect(arrived, "the player produced no frame to grade")
        let playbackPixel = MediaFixtures.sample(try #require(collector.last),
                                                 atFractionX: 0.5)

        // both are darker than what went in — the look is in both frames
        #expect(livePixel.r < Int(grey) - 20, "live: \(livePixel.description)")
        #expect(playbackPixel.r < Int(grey) - 20,
                "playback: \(playbackPixel.description)")
        // …and they agree. The tolerance is the ProRes round trip (±2 per
        // channel, measured), not slack for a different render path.
        let bothSides = "live \(livePixel.description) vs \(playbackPixel.description)"
        for (live, playback) in [(livePixel.r, playbackPixel.r),
                                 (livePixel.g, playbackPixel.g),
                                 (livePixel.b, playbackPixel.b)] {
            #expect(abs(live - playback) <= 4, "\(bothSides)")
        }
    }
}
