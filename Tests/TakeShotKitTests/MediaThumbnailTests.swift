import AppKit
import AVFoundation
import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Take and Other-content previews, decoded from real files.
///
/// Two things here are load bearing beyond "a picture appears". A take's file
/// finalizes asynchronously, so the decoder retries — and when every retry
/// fails it MUST let go of the in-flight mark, or that take can never be
/// retried for the rest of the session and its cell stays empty until relaunch.
/// The other is the duration shown on an Other-content cell: it comes from the
/// file, and it is what tells the operator whether a card was fully copied.
@Suite @MainActor struct MediaThumbnailTests {
    /// A take with a real recording behind it, inside the record folder.
    private func take(_ name: String, in root: URL,
                      clip: Int = 1) -> Take {
        ControllerFixtures.take(named: name, in: root, clip: clip)
    }

    /// Run the folder scan out to a standstill before asking for previews.
    ///
    /// `publish(foreign:)` prunes the preview caches down to what the walk it
    /// came from found, and a decode is two main-actor hops long — the duration
    /// lands on the first and the image on the second. A scan whose walk predates
    /// the fixture files can therefore drop the duration between the two, and
    /// the controller keeps a 60 s safety-net rescan of its own that no test can
    /// cancel. Draining first, with the files already aged past the "still being
    /// written" window, leaves nothing in flight to prune.
    private func settleScans(_ controller: CaptureController) async {
        for _ in 0..<3 {
            controller.scanDestinationFolder()
            await ControllerWait.until {
                !controller.scanInFlight && !controller.rescanWhenIdle
            }
        }
    }

    @Test func aTakeGetsItsPreviewFromItsOwnFile() async throws {
        try await ControllerHarness.run { controller, root in
            let take = self.take("A001_C001", in: root)
            try await MediaFixtures.writeClip(at: take.url, frames: 25)

            controller.requestThumbnail(for: take)
            let decoded = await ControllerWait.untilWritten {
                controller.thumbnails[take.id] != nil
            }
            #expect(decoded, "no thumbnail was decoded from \(take.url.path)")
            let image = try #require(controller.thumbnails[take.id])
            #expect(image.size.width > 0 && image.size.height > 0)
            // the decode is capped at 256 px — a full frame per take pinned
            // 100+ MB the list mode never showed
            #expect(image.size.width <= 256 && image.size.height <= 256)
            #expect(!controller.thumbnailsInFlight.contains(take.id))
        }
    }

    /// Cells re-ask as they scroll back into view; a second request for a take
    /// already in the cache must not start another decode.
    @Test func aSecondRequestIsServedFromTheCache() async throws {
        try await ControllerHarness.run { controller, root in
            let take = self.take("A001_C002", in: root, clip: 2)
            try await MediaFixtures.writeClip(at: take.url, frames: 25)

            controller.requestThumbnail(for: take)
            await ControllerWait.untilWritten { controller.thumbnails[take.id] != nil }
            let first = try #require(controller.thumbnails[take.id])

            controller.requestThumbnail(for: take)
            #expect(controller.thumbnailsInFlight.isEmpty,
                    "a cached take was queued for decoding again")
            #expect(controller.thumbnails[take.id] === first)
        }
    }

    /// A file that cannot be decoded has to release its in-flight mark. Without
    /// that, the take's cell is empty for the rest of the session even after the
    /// real reason (a copy still in progress) has gone away.
    @Test func aTakeThatCannotBeDecodedIsLeftRetryable() async throws {
        try await ControllerHarness.run { controller, root in
            let take = self.take("A001_C003", in: root, clip: 3)
            try MediaFixtures.writeCorruptClip(at: take.url)

            controller.requestThumbnail(for: take)
            #expect(controller.thumbnailsInFlight.contains(take.id))

            // ten attempts half a second apart — an I/O-sized budget
            let released = await ControllerWait.untilWritten {
                !controller.thumbnailsInFlight.contains(take.id)
            }
            #expect(released, "the take can never be retried in this session")
            #expect(controller.thumbnails[take.id] == nil)

            // …and asking again really does start over
            controller.requestThumbnail(for: take)
            #expect(controller.thumbnailsInFlight.contains(take.id))
        }
    }

    /// Other content: a still decodes directly, a movie through a frame
    /// generator and brings its duration with it. The duration is absent for a
    /// still — a photo has no length and showing "0:00" on one read as broken.
    @Test func otherContentCoversStillsAndMoviesWithTheirDurations() async throws {
        try await ControllerHarness.run { controller, root in
            let still = try ControllerFixtures.writePNG(
                at: root.appendingPathComponent("dropped.png"), side: 64)
            let movie = try await MediaFixtures.writeClip(
                at: root.appendingPathComponent("foreign.mov"), frames: 50)
            // aged past the scan's "still being written" window, so it does not
            // schedule a rescan two seconds into the test
            try ControllerFixtures.settle(still)
            try ControllerFixtures.settle(movie)
            await self.settleScans(controller)

            controller.requestOtherThumbnail(for: still)
            controller.requestOtherThumbnail(for: movie)

            let decoded = await ControllerWait.untilWritten {
                controller.otherThumbnails[still] != nil
                    && controller.otherThumbnails[movie] != nil
                    && controller.otherDurations[movie] != nil
            }
            #expect(decoded, "Other content produced no previews")
            #expect(controller.otherDurations[still] == nil,
                    "a photo was given a duration")
            let duration = try #require(controller.otherDurations[movie])
            #expect(abs(duration - 2.0) < 0.25, "duration=\(duration)")
            #expect(controller.otherThumbsInFlight.isEmpty)
        }
    }

    /// A CinemaDNG clip is a folder of frames, and the cell shows the MIDDLE
    /// one: the first frame of a take is usually the slate or a black frame.
    ///
    /// The frames here are PNGs wearing a .dng name — ImageIO sniffs the
    /// content, and what is under test is the routing and the frame choice, not
    /// the raw decoder.
    @Test func aCinemaDNGFolderPreviewsItsMiddleFrame() async throws {
        try await ControllerHarness.run { controller, root in
            let folder = root.appendingPathComponent("A001_dng")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            for index in 1...3 {
                try ControllerFixtures.writePNG(
                    at: folder.appendingPathComponent(
                        String(format: "%04d.dng", index)), side: 32)
            }
            #expect(CaptureController.isCinemaDNGFolder(folder))
            try ControllerFixtures.settle(folder)
            await self.settleScans(controller)

            controller.requestOtherThumbnail(for: folder)
            let decoded = await ControllerWait.untilWritten {
                controller.otherThumbnails[folder] != nil
                    && controller.otherDurations[folder] != nil
            }
            #expect(decoded, "the DNG sequence produced no preview")
            // three frames at the 24 fps the sequence reader assumes
            let duration = try #require(controller.otherDurations[folder])
            #expect(abs(duration - 3.0 / 24.0) < 0.001)
        }
    }

    /// An Other-content file whose preview cannot be decoded stays retryable,
    /// for the same reason a take does — a card dropped into the folder is
    /// unreadable while it is still copying and readable a minute later. The
    /// in-flight mark used to come off only on success, so one failed decode
    /// froze the cell for the rest of the session.
    @Test func anUnreadableOtherFileIsLeftRetryable() async throws {
        try await ControllerHarness.run { controller, root in
            let broken = try MediaFixtures.writeCorruptClip(
                at: root.appendingPathComponent("half-copied.mov"))

            controller.requestOtherThumbnail(for: broken)
            let released = await ControllerWait.untilWritten {
                !controller.otherThumbsInFlight.contains(broken)
            }
            #expect(released, "the cell can never be retried in this session")
            #expect(controller.otherThumbnails[broken] == nil)
        }
    }
}
