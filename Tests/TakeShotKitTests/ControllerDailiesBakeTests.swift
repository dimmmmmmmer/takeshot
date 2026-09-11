import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **What the app hands the transcode when the operator asks it to bake.**
///
/// `DailiesMetadataTests` measures what the ENGINE does with a look and a
/// squeeze; this is the other half — the switches, the operator's own cube and
/// factor, and the fact that both reach a detached task at all. Worth an
/// end-to-end run of its own because they are built on the main actor and
/// carried across an isolation boundary, which is the crossing this file has
/// been bitten by before.
@Suite @MainActor struct ControllerDailiesBakeTests {
    /// A take backed by a real playable file, written by the app's own writer.
    private func recordedTake(named name: String, in folder: URL,
                              frames: Int = 50) async throws -> Take {
        let url = try await MediaFixtures.writeClip(
            at: folder.appendingPathComponent("\(name).mov"), frames: frames)
        return Take(url: url, scene: "", roll: "001", takeNumber: 1,
                    startTimecode: MediaFixtures.startTimecode,
                    durationSeconds: Double(frames) / 25, recordedAt: Date())
    }

    /// The look a finished file says is in its pixels.
    ///
    /// `nonisolated`, and the metadata never leaves it: this suite is on the
    /// main actor and an `[AVMetadataItem]` crossing back into it is the
    /// "sending risks causing data races" the older toolchain rejects — the
    /// case docs/ARCHITECTURE.md names. Only the answer, a `String?`, comes
    /// out.
    /// The raster a finished file has, read off the track itself.
    nonisolated private static func raster(of url: URL) async throws -> CGSize {
        let track = try #require(
            try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
                .first)
        return try await track.load(.naturalSize)
    }

    nonisolated private static func bakedLook(of url: URL) async -> String? {
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        return await TakeWriter.bakedLookName(metadata)
    }

    /// **The whole path from the switch to the file** (owner: "о в дейликах
    /// хочу еще возможность чтоб лут в них запекался").
    ///
    /// `DailiesMetadataTests` measures what the engine does with a look; this
    /// is the app's half — the switch, the cube the operator has loaded, the
    /// name that goes on the file, and the fact that the run is handed a look
    /// at all. It is worth its own end-to-end run because the look is built on
    /// the main actor and carried into a detached task, which is exactly the
    /// crossing this file has been bitten by before.
    @Test func theQueueBakesTheViewingLookWhenAskedTo() async throws {
        try await ControllerHarness.run { controller, _ in
            let media = try MediaFixtures.makeDirectory("dailies-look")
            defer { try? FileManager.default.removeItem(at: media) }
            let take = try await self.recordedTake(named: "A001C001",
                                                   in: media, frames: 8)
            let folder = media.appendingPathComponent("Dailies")

            controller.currentCube = try CubeLUT.parse("""
                LUT_3D_SIZE 2
                \(Array(repeating: "1.0 0.0 0.0", count: 8)
                    .joined(separator: "\n"))
                """)
            controller.settings.lut.fileName = "Show.cube"
            let model = controller.dailies
            model.prepare(takes: [take], settings: controller.settings,
                          defaultFolder: folder)
            model.bakeLook = true
            // …and the squeeze, which travels the same way: the operator's own
            // factor read on this side and handed to the run.
            controller.settings.assist.desqueezeOn = true
            controller.settings.assist.desqueezeFactor = 2
            model.bakeDesqueeze = true
            // ProRes, because the marker rides in the QuickTime metadata key
            // space and an `.mp4` has none — the same measured limit the
            // take's identity runs into (`theProxysMetadataFollowsItsContainer`).
            // An H.264 daily is still baked; it just cannot say so in a key,
            // which is written up at `DailiesSession.open`.
            model.codec = .proResProxy
            model.start()

            await ControllerWait.untilWritten { model.report != nil }
            let report = try #require(model.report)
            #expect(report.isFullySucceeded, "items failed: \(report.failed)")
            let daily: URL = try #require(report.items.first?.output)
            let raster = try await Self.raster(of: daily)
            #expect(raster.width > raster.height * 2, """
                the daily is \(raster) — a 2x squeeze on a 16:9 source makes a \
                very wide picture, and this one still has the camera's shape
                """)
            #expect(await Self.bakedLook(of: daily) == "Show.cube", """
                the daily does not name the look in its pixels — the player \
                will grade it a second time
                """)
        }
    }
}
