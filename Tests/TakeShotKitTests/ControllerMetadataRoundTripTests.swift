import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// The day's paperwork survives the app only in the two CSVs next to the takes,
/// and the only thing that reads them back is the folder scan. So the round trip
/// that matters is the whole one: mark up a day, let it be written, forget every
/// take, rescan the folder and see what came back.
///
/// The rating is ternary and Resolve's Good Take column is a checkbox, which is
/// what makes the middle state interesting: "unmarked" has to come back
/// unmarked, not rejected. The markers are here for the same reason — their
/// position is now the timecode column and nothing else.
@Suite @MainActor struct ControllerMetadataRoundTripTests {
    /// Three real takes in the record folder, tagged as ours and carrying a
    /// timecode track — the scan adopts nothing else.
    private func recordClips(_ controller: CaptureController,
                             in root: URL) async throws -> [Take] {
        var takes: [Take] = []
        for clip in 1...3 {
            let url = root.appendingPathComponent(
                String(format: "A001C%02d.mov", clip))
            try await MediaFixtures.writeClip(at: url, frames: 25)
            // the scan skips anything written in the last three seconds
            try ControllerFixtures.settle(url)
            takes.append(Take(url: url, scene: "", roll: "001",
                              takeNumber: clip,
                              startTimecode: MediaFixtures.startTimecode,
                              durationSeconds: 1,
                              recordedAt: Date(timeIntervalSince1970:
                                                1_700_000_000 + Double(clip))))
        }
        controller.takes = takes
        return takes
    }

    /// Wait for the sidecar the background writer is about to produce.
    private func sidecar(_ root: URL, _ file: String,
                         containing needle: String) async -> String {
        let url = root.appendingPathComponent(file)
        func text() -> String? { try? String(contentsOf: url, encoding: .utf8) }
        await ControllerWait.until { text()?.contains(needle) == true }
        return text() ?? ""
    }

    /// Forget everything the session knew and let the folder speak for itself.
    /// The budget is the I/O one: the scan loads metadata, duration and the
    /// timecode track of every file it finds before a take can come back.
    private func rescan(_ controller: CaptureController) async {
        controller.takes.removeAll()
        controller.scannedPaths.removeAll()
        controller.scanDestinationFolder()
        await ControllerWait.untilWritten {
            !controller.scanInFlight && controller.takes.count == 3
        }
    }

    @Test func allThreeRatingsComeBackFromTheFolder() async throws {
        try await ControllerHarness.run { controller, root in
            let takes = try await recordClips(controller, in: root)
            controller.setRating(.good, for: takes[0])
            controller.setComment("hero take", for: controller.takes[0])
            // takes[1] is deliberately left alone: unmarked is a state
            controller.setRating(.bad, for: takes[2])
            controller.setComment("boom in frame", for: controller.takes[2])

            let csv = await sidecar(root, TakeLogExporter.fileName,
                                    containing: "boom in frame")
            // Resolve's checkbox: ticked, empty, cleared — in that order
            #expect(csv.contains("A001C01.mov,001,1,true,hero take"))
            #expect(csv.contains("A001C02.mov,001,2,,"))
            #expect(csv.contains("A001C03.mov,001,3,false,Bad: boom in frame"))

            await rescan(controller)

            let restored = controller.takes.sorted {
                $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            #expect(restored.count == 3)
            #expect(restored.map(\.rating) == [.good, .none, .bad])
            #expect(restored.map(\.comment) == ["hero take", "", "boom in frame"])
        }
    }

    /// The markers sidecar records the position as a timecode only, so the
    /// restore has to reconstruct the offset from the take's own start TC.
    @Test func markersComeBackOnTheRightFrames() async throws {
        try await ControllerHarness.run { controller, root in
            _ = try await recordClips(controller, in: root)
            controller.takes[0].markers = [
                TakeMarker(seconds: 0.4, timecodeText: "10:00:00:10",
                           color: "red", note: "фокус"),
                TakeMarker(seconds: 0.8, timecodeText: "10:00:00:20"),
            ]
            controller.exportTakeLog()

            let csv = await sidecar(root, TakeLogExporter.markersFileName,
                                    containing: "10:00:00:20")
            #expect(csv.contains("File Name,Timecode,Color,Note"))
            // one value for the position, and it is the timecode
            #expect(!csv.contains("Seconds"))

            await rescan(controller)

            let restored = try #require(controller.takes.first {
                $0.url.lastPathComponent == "A001C01.mov"
            })
            #expect(restored.markers.map(\.seconds) == [0.4, 0.8])
            #expect(restored.markers.map(\.timecodeText)
                    == ["10:00:00:10", "10:00:00:20"])
            #expect(restored.markers.first?.color == "red")
            #expect(restored.markers.first?.note == "фокус")
        }
    }

    /// The same round trip for a clip that is NOT ours (owner item 24): the
    /// sidecar is keyed by file name, so a card clip in the record folder can
    /// carry markers, and they have to come back on the next launch the way a
    /// take's do. Such a clip has no timecode track we read, so its rows are
    /// offsets from zero on both sides of the file.
    @Test func markersOnAForeignClipComeBackFromTheSidecar() async throws {
        try await ControllerHarness.run { controller, root in
            // deliberately NOT written through TakeWriter: what makes a file
            // ours is the com.takeshot.origin tag, and this one must come back
            // from the scan as Other content
            let foreign = root.appendingPathComponent("A003_C012.mov")
            try Data([0x00]).write(to: foreign)
            try ControllerFixtures.settle(foreign)
            controller.otherMarkers["A003_C012.mov"] = [
                TakeMarker(seconds: 0.4, color: "red", note: "фокус"),
                TakeMarker(seconds: 0.8),
            ]
            controller.exportTakeLog()

            let csv = await sidecar(root, TakeLogExporter.markersFileName,
                                    containing: "A003_C012.mov")
            #expect(csv.contains("A003_C012.mov,00:00:00:10,red,фокус"))
            #expect(csv.contains("A003_C012.mov,00:00:00:20,orange,"))

            // forget the session's copy and let the folder speak for itself
            controller.otherMarkers.removeAll()
            controller.otherFiles.removeAll()
            controller.scannedPaths.removeAll()
            controller.scanDestinationFolder()
            await ControllerWait.untilWritten {
                !controller.scanInFlight
                    && controller.otherMarkers["A003_C012.mov"] != nil
            }

            let restored = try #require(controller.otherMarkers["A003_C012.mov"])
            #expect(restored.map(\.seconds) == [0.4, 0.8])
            #expect(restored.first?.color == "red")
            #expect(restored.first?.note == "фокус")
            // and it did not become a take on the way back
            #expect(controller.takes.isEmpty)
        }
    }
}
