@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// One take through the dailies engine, decoded back and measured: the
/// burn-ins are where the layout says, the timecode runs, big sources come
/// out 1080p, the audio comes out AAC stereo, and nothing ever lands on an
/// existing daily's name. The queue's own contract (FIFO, cancel, skip,
/// pause) is `DailiesQueueTests`; the fixtures are `DailiesRig`.
struct DailiesEngineTests {
    @Test func aTakeBecomesAPlayableDailyWithTheStripsBurnedIn() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("clip.mov"))
        let fixture = DailiesRig.item(for: source)

        let burned = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.allBurnins,
            into: root.appendingPathComponent("Dailies"))
        let clean = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Clean"))
        let burnedURL = try #require(burned.items.first?.output)
        let cleanURL = try #require(clean.items.first?.output)
        #expect(burnedURL.lastPathComponent == "clip_DAILY.mp4")

        // playable H.264 at the source raster, ~1 s
        let asset = AVURLAsset(url: burnedURL)
        let track = try #require(try await asset.tracks(ofType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 320 && Int(size.height) == 180)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.1)

        // every enabled strip region differs from the burn-in-less run…
        let burnedFrame = try await DailiesRig.decodeFrame(0, of: burnedURL)
        let cleanFrame = try await DailiesRig.decodeFrame(0, of: cleanURL)
        let overlay = DailiesOverlay(
            size: CGSize(width: 320, height: 180),
            texts: DailiesRig.allBurnins.overlayTexts(for: fixture))
        for rect in [overlay.layout.timecode, overlay.layout.clipName,
                     overlay.layout.project, overlay.layout.custom] {
            let region = try #require(rect)
            let difference = DailiesRig.meanAbsDiff(burnedFrame, cleanFrame,
                                                    in: region)
            #expect(difference > 15,
                    "strip at \(region) barely differs (\(difference))")
        }
        // …and the picture between the strips is the same take
        let control = DailiesRig.meanAbsDiff(
            burnedFrame, cleanFrame, in: DailiesRig.centerRegion(of: size))
        #expect(control < 6, "the picture itself drifted (\(control))")
    }

    /// The running clock: the TC strip at frame 42 reads 10:00:01:17 — three
    /// digits away from the frame-0 label — asserted as pixels (the strip
    /// region changes between the two frames while the picture region does
    /// not). What the text says exactly is `DailiesTimelineTests`' job.
    @Test func theRunningTimecodeAdvancesInsideItsStrip() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("clip.mov"), frames: 50)
        let fixture = DailiesRig.item(for: source)

        let report = await DailiesEngine.run(
            items: [fixture], burnins: DailiesRig.allBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output)

        let first = try await DailiesRig.decodeFrame(0, of: daily)
        let later = try await DailiesRig.decodeFrame(42, of: daily)
        let overlay = DailiesOverlay(
            size: CGSize(width: 320, height: 180),
            texts: DailiesRig.allBurnins.overlayTexts(for: fixture))
        let tcRegion = try #require(overlay.layout.timecode)
        let tcChange = DailiesRig.meanAbsDiff(first, later, in: tcRegion)
        let control = DailiesRig.meanAbsDiff(
            first, later,
            in: DailiesRig.centerRegion(of: CGSize(width: 320, height: 180)))
        #expect(tcChange > 4, "the TC strip did not change (\(tcChange))")
        #expect(control < 2, "the still picture changed (\(control))")
        #expect(tcChange > control * 3)
        // the static name strip stays put while the clock runs
        let nameRegion = try #require(overlay.layout.clipName)
        #expect(DailiesRig.meanAbsDiff(first, later, in: nameRegion) < 2)
    }

    @Test func aSourceLargerThan1080pIsDownscaledToFit() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("big.mov"),
            width: 2048, height: 1152, frames: 8)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output)
        let track = try #require(
            try await AVURLAsset(url: daily).tracks(ofType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 1920 && Int(size.height) == 1080)
    }

    /// Whatever the take embedded — here four channels — the daily carries
    /// AAC stereo, which is what editorial players actually open.
    @Test func theEmbedAudioComesOutAACStereo() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("clip.mov"), audioChannels: 4)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"))
        let daily = try #require(report.items.first?.output)
        let track = try #require(
            try await AVURLAsset(url: daily).tracks(ofType: .audio).first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try #require(descriptions.first)
        let stream = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description))
        #expect(stream.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(stream.pointee.mChannelsPerFrame == 2)
    }

    /// The app's no-silent-overwrite idiom (`CapturePipeline.uniqueURL`): a
    /// name that exists gets `_2`, and the existing file is left alone.
    @Test func anExistingDailyIsNeverOverwritten() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("clip.mov"), frames: 8)
        let folder = root.appendingPathComponent("Dailies")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("clip_DAILY.mp4")
        let marker = Data("yesterday's daily".utf8)
        try marker.write(to: existing)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder)
        let output = try #require(report.items.first?.output)
        #expect(output.lastPathComponent == "clip_DAILY_2.mp4")
        #expect(try Data(contentsOf: existing) == marker,
                "the existing daily was touched")
    }
}
