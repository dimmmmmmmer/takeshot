import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

/// **How far a daily is scaled down** (owner: "во, точно, давай сделаем выбор
/// насколько снижать резолюшн").
///
/// The failure that matters is a ceiling that upscales: a 1080p take rendered
/// as 4K costs the disk four times the bytes and buys an editor nothing, and
/// nothing on screen would say it had happened.
@Suite(.timeLimit(.minutes(2))) struct DailiesResolutionTests {
    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }

    // MARK: - the arithmetic

    /// The default is what every daily was before the choice existed.
    @Test func theDefaultIsTheCeilingEveryDailyAlreadyHad() {
        #expect(DailiesResolution.hd.limit == DailiesEngine.maxSize)
        #expect(DailiesEngine.outputSize(for: size(3840, 2160))
            == size(1920, 1080))
    }

    @Test func aSourceIsFittedInsideTheChosenCeiling() {
        let uhd = size(3840, 2160)
        #expect(DailiesEngine.outputSize(for: uhd, resolution: .hd720)
            == size(1280, 720))
        #expect(DailiesEngine.outputSize(for: uhd, resolution: .sd)
            == size(960, 540))
        #expect(DailiesEngine.outputSize(for: uhd, resolution: .uhd) == uhd)
    }

    /// **Never up.** Upscaling costs the disk and buys an editor nothing, and
    /// it is the one mistake a ceiling makes silently.
    @Test func nothingIsEverScaledUp() {
        for resolution in DailiesResolution.allCases {
            #expect(DailiesEngine.outputSize(for: size(640, 360),
                                             resolution: resolution)
                == size(640, 360), "\(resolution) upscaled a small source")
        }
    }

    /// The ceiling bounds BOTH edges, so a shape that is not 16:9 is fitted by
    /// whichever edge runs out first and keeps its own aspect either way.
    @Test func anUnusualShapeKeepsItsAspect() {
        // 2.39: the width runs out first
        let wide = DailiesEngine.outputSize(for: size(4096, 1716),
                                            resolution: .hd)
        #expect(wide.width == 1920)
        #expect(abs(wide.height - 1920 / (4096 / 1716)) <= 2, "\(wide)")
        // 4:3: the height runs out first
        let boxy = DailiesEngine.outputSize(for: size(2880, 2160),
                                            resolution: .hd)
        #expect(boxy.height == 1080)
        #expect(abs(boxy.width - 1080 * (2880 / 2160)) <= 2, "\(boxy)")
    }

    /// `.source` is no ceiling at all — but still an even raster, because an
    /// odd dimension is a frame size half the encoders on this machine refuse.
    @Test func theSourceCeilingStillRoundsToAnEvenRaster() {
        #expect(DailiesEngine.outputSize(for: size(6144, 3160),
                                         resolution: .source)
            == size(6144, 3160))
        #expect(DailiesEngine.outputSize(for: size(1921, 1081),
                                         resolution: .source)
            == size(1920, 1080))
    }

    /// A raster the container would not state: a daily somebody can look at
    /// beats a run that fails at the encoder.
    @Test func anUnreadableRasterFallsBackToTheCeiling() {
        #expect(DailiesEngine.outputSize(for: .zero, resolution: .hd720)
            == size(1280, 720))
        #expect(DailiesEngine.outputSize(for: .zero, resolution: .source)
            == DailiesEngine.maxSize)
    }

    /// The desqueeze widens the picture BEFORE the ceiling is applied, and the
    /// widened shape is what gets fitted: a 2x anamorphic 1080p frame is
    /// 3840x1080, i.e. 3.56:1, so inside a 16:9 box the WIDTH binds and the
    /// result is short rather than 720 tall. Squeezing it back to fill the box
    /// would be the daily re-introducing the very squeeze the bake took out.
    @Test func aDesqueezeIsWidenedBeforeTheCeilingIsApplied() {
        let squeezed = DailiesEngine.outputSize(for: size(1920, 1080),
                                                desqueeze: 2,
                                                resolution: .hd720)
        #expect(squeezed == size(1280, 360), "\(squeezed)")
        // the desqueezed aspect, kept exactly
        #expect(abs(squeezed.width / squeezed.height - 3840.0 / 1080) < 0.01)
        // and the same source with no squeeze fills the box
        #expect(DailiesEngine.outputSize(for: size(1920, 1080), desqueeze: 1,
                                         resolution: .hd720)
            == size(1280, 720))
    }

    // MARK: - what it means to a run

    /// **A run at another ceiling is a different deliverable**, so a folder of
    /// 1080p dailies is not "already rendered" for a 720p run.
    @Test func theCeilingIsPartOfTheRecipe() {
        let burnins = DailiesRig.noBurnins
        let hd = DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
        let small = DailiesRecipe.fingerprint(burnins: burnins, codec: .h264,
                                              resolution: .hd720)
        #expect(hd != small)
        #expect(small.contains("res:720"))
    }

    /// …and the DEFAULT is absent from it, which is deliberate: every daily on
    /// every disk in existence was rendered at 1080p, and a field appended
    /// unconditionally would change all of their fingerprints at once — the
    /// next run over any of those folders would decide the show is stale.
    @Test func theDefaultCeilingLeavesEveryOldFingerprintAlone() {
        let burnins = DailiesRig.noBurnins
        #expect(DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
            == DailiesRecipe.fingerprint(burnins: burnins, codec: .h264,
                                         resolution: .hd))
        #expect(!DailiesRecipe.fingerprint(burnins: burnins, codec: .h264)
            .contains("res:"))
    }

    /// The settings field reads back what was written, and an unreadable value
    /// lands on 1080p rather than on the source's own raster — a blob naming a
    /// case this build does not know must not write 6K ProRes to a shuttle.
    @Test func anUnreadableSettingFallsBackToTheDefault() {
        var settings = DailiesSettings()
        #expect(settings.resolutionEffective == .hd)
        settings.resolution = "720"
        #expect(settings.resolutionEffective == .hd720)
        settings.resolution = "8640"
        #expect(settings.resolutionEffective == .hd)
    }

    // MARK: - a real file

    /// End to end: the ceiling reaches the picture on disk.
    @Test func theProxyIsWrittenAtTheChosenCeiling() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C001.mov"),
            width: 1920, height: 1080, frames: 10)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, resolution: .hd720)
        let daily: URL = try #require(report.items.first?.output)
        let track: AVAssetTrack = try #require(
            try await AVURLAsset(url: daily).tracks(ofType: .video).first)
        let raster = try await track.load(.naturalSize)
        #expect(raster == size(1280, 720), "the proxy is \(raster)")
    }
}
