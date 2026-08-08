import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The creative metadata as the operator meets it: typed into the footer before
/// a take, embedded in the file the take produces, corrected afterwards, and
/// still there after the app has forgotten everything and rescanned the folder.
@Suite @MainActor struct ControllerSlateTests {
    /// Roll a take for roughly `seconds` — the capture suite's own helper, and
    /// for the same reason: the synthetic source's timecode is frozen, so the
    /// wall clock is what paces a take and every assertion after it waits on
    /// real state.
    private func record(_ controller: CaptureController,
                        seconds: Double = 1.2) async {
        controller.toggleManualRecord()
        await ControllerWait.until { controller.isRecording }
        let deadline = Date().addingTimeInterval(seconds)
        await ControllerWait.until({ Date() >= deadline },
                                   timeout: .seconds(seconds + 45))
        controller.toggleManualRecord()
        await ControllerWait.until { !controller.isRecording }
    }

    /// One namespaced metadata value off a finished file.
    ///
    /// `nonisolated` so that the `[AVMetadataItem]` never leaves this scope —
    /// it is not Sendable, and returning it to the main-actor suite is a
    /// crossing the macOS 15 SDK rejects and the macOS 26 one allows. Only the
    /// `String?` comes back. Same reduction as the `Sources` side
    /// (docs/ARCHITECTURE.md).
    private nonisolated func embedded(_ key: String,
                                      of url: URL) async throws -> String? {
        let items = try await AVURLAsset(url: url).load(.metadata)
        guard let item = items.first(where: { ($0.key as? String) == key })
        else { return nil }
        return try await item.load(.stringValue)
    }

    /// Forget everything the session knew and let the folder speak for itself.
    /// The budget is the I/O one: the scan reads metadata, duration and the
    /// timecode track of every file before a take can come back.
    private func rescan(_ controller: CaptureController) async {
        controller.takes.removeAll()
        controller.scannedPaths.removeAll()
        controller.scanDestinationFolder()
        await ControllerWait.untilWritten {
            !controller.scanInFlight && controller.takes.count == 1
        }
    }

    /// Wait for the sidecar the background writer is about to produce.
    private func sidecar(_ root: URL, _ file: String,
                         containing needle: String) async -> String {
        let url = root.appendingPathComponent(file)
        func text() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        await ControllerWait.until { text()?.contains(needle) == true }
        return text() ?? ""
    }

    // MARK: - take numbering

    /// The clip counter and the scene's take number are two different numbers.
    /// Until a scene is opened there is no creative take at all — an unslated
    /// shoot must keep exporting exactly the clip counter it always did.
    @Test func withNoSceneThereIsNoSeparateTakeNumber() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.nextTakeNumber = 7
            #expect(!controller.isSlating)
            #expect(controller.slateTakeNumber == 0)
            #expect(controller.pendingSlate.isEmpty)
            #expect(controller.slateDisplay == "—")
        }
    }

    /// Opening a scene starts its numbering at 1, whatever the clip counter is
    /// up to — that is the whole reason the two are separate.
    @Test func aNewSceneRestartsItsOwnTakeNumbering() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.nextTakeNumber = 42
            controller.scene = "12"
            #expect(controller.slateTakeNumber == 1)
            #expect(controller.slateDisplay == "12 T1")

            controller.shot = "B"
            controller.slateTakeOverride = 3
            #expect(controller.pendingSlate
                == SlateMetadata(scene: "12", shot: "B", take: 3))
            #expect(controller.slateDisplay == "12/B T3")

            // the next scene starts over, and the clip counter is untouched
            controller.scene = "12A"
            #expect(controller.slateTakeNumber == 1)
            #expect(controller.nextTakeNumber == 42)
        }
    }

    /// Clearing the scene hands numbering back to the clip counter rather than
    /// leaving the last scene's number stuck on every following file.
    @Test func clearingTheSceneHandsNumberingBack() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.scene = "12"
            controller.slateTakeOverride = 5
            controller.scene = ""
            #expect(controller.slateTakeOverride == nil)
            #expect(controller.slateTakeNumber == 0)
            #expect(controller.pendingSlate.isEmpty)
        }
    }

    /// Typing in the field, and stepping it. An emptied field is not "take 0",
    /// it is "follow the clip counter" — the only way the operator can undo an
    /// override without restarting the scene.
    @Test func theTakeFieldOverridesAndReleases() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.nextTakeNumber = 9
            controller.shot = "A" // slating, without a scene number
            #expect(controller.slateTakeNumber == 9)

            controller.commitSlateTakeText("12")
            #expect(controller.slateTakeOverride == 12)
            controller.stepSlateTake(1)
            #expect(controller.slateTakeNumber == 13)
            controller.stepSlateTake(-20)
            #expect(controller.slateTakeNumber == 1, "clamped at the first take")

            controller.commitSlateTakeText("")
            #expect(controller.slateTakeOverride == nil)
            #expect(controller.slateTakeNumber == 9)
        }
    }

    /// A landed take moves the scene's numbering on, the way the clip counter
    /// moves on — the next REC is the next take of the same setup.
    @Test func aLandedTakeAdvancesTheScenesNumbering() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.scene = "12"
            controller.shot = "B"

            await record(controller)
            await ControllerWait.untilWritten { controller.takes.count == 1 }

            #expect(controller.takes.first?.slate
                == SlateMetadata(scene: "12", shot: "B", take: 1))
            #expect(controller.slateTakeNumber == 2)
            #expect(controller.nextTakeNumber == 2)
        }
    }

    // MARK: - the file itself

    /// The point of the feature: what the operator slated is INSIDE the .mov,
    /// so a copy that leaves the sidecars behind still knows its scene.
    @Test func theSlateReachesTheRecordedFile() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.scene = "12A"
            controller.shot = "B"
            controller.slateTakeOverride = 3

            await record(controller)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)

            #expect(try await embedded(TakeWriter.sceneKey, of: take.url) == "12A")
            #expect(try await embedded(TakeWriter.shotKey, of: take.url) == "B")
            #expect(try await embedded(TakeWriter.takeKey, of: take.url) == "3")

            // …and beside the footage, in the sidecar the corrections use
            let csv = await sidecar(root, TakeLogExporter.slateFileName,
                                    containing: take.url.lastPathComponent)
            #expect(csv.hasPrefix("File Name,Scene,Shot,Take,Description"))
            #expect(csv.contains("\(take.url.lastPathComponent),12A,B,3,"))
        }
    }

    /// A slate typed mid-take must not retag the footage already written: the
    /// pipeline latches it at the start, like the audio channel mask.
    @Test func aSlateTypedMidTakeAppliesToTheNextOne() async throws {
        try await ControllerHarness.run(live: true) { controller, _ in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.scene = "12"

            controller.toggleManualRecord()
            await ControllerWait.until { controller.isRecording }
            controller.scene = "99"
            let deadline = Date().addingTimeInterval(1.2)
            await ControllerWait.until({ Date() >= deadline },
                                       timeout: .seconds(46))
            controller.toggleManualRecord()
            await ControllerWait.until { !controller.isRecording }
            await ControllerWait.untilWritten { controller.takes.count == 1 }

            let take = try #require(controller.takes.first)
            #expect(take.slate.scene == "12")
            #expect(try await embedded(TakeWriter.sceneKey, of: take.url) == "12")
        }
    }

    // MARK: - correcting a take that has already been recorded

    /// The honest contract: a correction rewrites the sidecar and never the
    /// file. Asserted by comparing the recording BYTE FOR BYTE either side of
    /// the edit — a writer that quietly re-muxed the movie would pass every
    /// metadata assertion and fail this one.
    @Test func aCorrectionUpdatesTheSidecarAndNotTheRecording() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.scene = "12"
            await record(controller)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            let before = try Data(contentsOf: take.url)

            controller.setSlate(SlateMetadata(scene: "13", shot: "C", take: 7),
                                description: "the corrected setup", for: take)

            #expect(controller.takes.first?.slate
                == SlateMetadata(scene: "13", shot: "C", take: 7))
            #expect(controller.takes.first?.logDescription
                == "the corrected setup")

            let csv = await sidecar(root, TakeLogExporter.slateFileName,
                                    containing: "the corrected setup")
            #expect(csv.contains(
                "\(take.url.lastPathComponent),13,C,7,the corrected setup"))

            // the recording is untouched — including its own, now older, slate
            #expect(try Data(contentsOf: take.url) == before,
                    "the recorded file was rewritten by a metadata edit")
            #expect(try await embedded(TakeWriter.sceneKey, of: take.url) == "12")
        }
    }

    // MARK: - the round trip through the folder

    /// The sidecar is the newer of the two copies, so it wins the restore; the
    /// file's own keys are the fallback that makes a folder without sidecars
    /// still worth something.
    @Test func aRescanPrefersTheSidecarAndFallsBackToTheFile() async throws {
        try await ControllerHarness.run(live: true) { controller, root in
            await ControllerWait.until { controller.signalFormat != nil }
            controller.scene = "12"
            controller.shot = "B"
            await record(controller)
            await ControllerWait.untilWritten { controller.takes.count == 1 }
            let take = try #require(controller.takes.first)
            let name = take.url.lastPathComponent
            controller.stopCapture()

            controller.setSlate(SlateMetadata(scene: "13", shot: "C", take: 7),
                                description: "corrected", for: take)
            _ = await sidecar(root, TakeLogExporter.slateFileName,
                              containing: "corrected")
            try ControllerFixtures.settle(take.url)

            await rescan(controller)
            let corrected = try #require(controller.takes.first)
            #expect(corrected.url.lastPathComponent == name)
            #expect(corrected.slate
                == SlateMetadata(scene: "13", shot: "C", take: 7))
            #expect(corrected.logDescription == "corrected")

            // now take the sidecar away, as a copy to another drive would
            try FileManager.default.removeItem(
                at: root.appendingPathComponent(TakeLogExporter.slateFileName))
            await rescan(controller)
            let fromFile = try #require(controller.takes.first)
            #expect(fromFile.slate == SlateMetadata(scene: "12", shot: "B",
                                                    take: 1),
                    "the file's own slate did not survive the sidecar")
            #expect(fromFile.logDescription == "")
        }
    }
}
