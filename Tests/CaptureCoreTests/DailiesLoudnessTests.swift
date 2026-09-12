import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **Every review copy at the same level**, end to end: a take is measured,
/// the gain reaches the file, and a run without the switch is untouched.
@Suite(.timeLimit(.minutes(3))) struct DailiesLoudnessTests {
    /// A take with real sound in it. −26 LUFS at 997 Hz, which is three
    /// decibels under the target and well inside the boost cap — so what the
    /// run does is the gain and not the limit on it.
    private func take(at url: URL, amplitude: Double = 0.05) async throws -> URL {
        try await DailiesRig.writeTake(at: url, frames: 100, audioChannels: 2,
                                       tone: amplitude)
    }

    private func render(_ source: URL, into folder: URL,
                        normalize: Bool) async throws -> URL {
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins, into: folder,
            codec: .proResProxy, normalizeAudio: normalize)
        return try #require(report.items.first?.output,
                            "the take produced no daily")
    }

    private func loudness(of url: URL) async throws -> Double {
        let meter: LoudnessMeter = try #require(
            await DailiesTranscode.measure(AVURLAsset(url: url)),
            "nothing to measure in \(url.lastPathComponent)")
        return try #require(meter.loudness, "the file measured as silence")
    }

    /// The whole point: the daily comes out on the target, and the take it was
    /// made from did not.
    @Test func aNormalisedDailyLandsOnTheTarget() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await take(at: root.appendingPathComponent("A.mov"))
        let before = try await loudness(of: source)
        #expect(abs(before - -26) < 1.5, "the fixture measured \(before)")

        let daily = try await render(source,
                                     into: root.appendingPathComponent("N"),
                                     normalize: true)
        let after = try await loudness(of: daily)
        // −23 spelled out, not read off the constant the gain was computed
        // from: that comparison passes whatever the target is
        #expect(abs(after - -23) < 1.5, "the daily measured \(after), not -23")
    }

    /// **A run without the switch is the run this app has always made.** The
    /// sound that comes out is the sound that went in, to within what the
    /// review codec does to it.
    @Test func aRunWithoutTheSwitchLeavesTheSoundAlone() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await take(at: root.appendingPathComponent("A.mov"))
        let before = try await loudness(of: source)
        let daily = try await render(source,
                                     into: root.appendingPathComponent("P"),
                                     normalize: false)
        let after = try await loudness(of: daily)
        #expect(abs(after - before) < 1,
                "an untouched daily measured \(after) against \(before)")
    }

    /// A take with nothing to measure still renders, with its sound track
    /// where it was: the gain is nil (`AudioGain` refuses to compute one from
    /// silence, and `LoudnessMeter` refuses to report one) and the run carries
    /// on. What this pins is that the refusal does not cost the daily.
    @Test func aTakeWithNothingToMeasureStillRenders() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // no `tone`: the fixture's packets are digital silence
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("S.mov"), frames: 60,
            audioChannels: 2)
        let daily = try await render(source,
                                     into: root.appendingPathComponent("N"),
                                     normalize: true)
        let asset = AVURLAsset(url: daily)
        #expect(try await !asset.tracks(ofType: .video).isEmpty)
        #expect(try await !asset.tracks(ofType: .audio).isEmpty,
                "the silent take lost its sound track")
    }

    /// A take with no audio track at all runs exactly as it did — the picture
    /// is what a daily is for.
    @Test func aTakeWithNoSoundStillRenders() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("M.mov"), frames: 30)
        let daily = try await render(source,
                                     into: root.appendingPathComponent("N"),
                                     normalize: true)
        #expect(try await !AVURLAsset(url: daily).tracks(ofType: .video)
            .isEmpty)
    }

    /// **A normalised daily is a different deliverable**, so a folder of
    /// untouched ones is not "already rendered" for a normalised run.
    @Test func normalisingIsPartOfTheRecipe() {
        let plain = DailiesRecipe.fingerprint(burnins: DailiesRig.noBurnins,
                                              codec: .h264)
        let even = DailiesRecipe.fingerprint(burnins: DailiesRig.noBurnins,
                                             codec: .h264, normalizeAudio: true)
        #expect(plain != even)
        #expect(even.contains("loudness:"))
        // …and the default leaves every old fingerprint alone
        #expect(!plain.contains("loudness:"))
        #expect(plain == DailiesRecipe.fingerprint(
            burnins: DailiesRig.noBurnins, codec: .h264, normalizeAudio: false))
    }
}
