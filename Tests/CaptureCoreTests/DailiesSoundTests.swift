import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **The sound recordist's files, in the daily** (owner: "было бы классно иметь
/// возможность выбрать папку со звуком … чтоб он автоматически подружил нужные
/// тейки и записывал в дейлик и дорожки с камеры и со звука / ну и дорожки чтоб
/// были подписаны так как по метам").
///
/// The reader and the matching rule are measured on their own
/// (`BroadcastWaveReaderTests`, `SoundSyncTests`). What these hold is the end
/// of it: a run handed a folder of sound produces a daily with the camera's
/// track AND the recordist's, named, and a run handed sound that belongs to
/// another day produces exactly the daily it always did.
/// **A time limit on the whole suite, because the failure mode is a HANG.**
///
/// `AVAssetWriter` holds an input back once it runs far ahead of another that
/// has not been marked finished, so a sound leg much longer than the picture
/// can wait for ever for frames that have already stopped — measured, and
/// fixed by bounding the final drain to the picture's end. Without a limit
/// here that regression is a suite that never finishes, which reads as a slow
/// machine; a minute against the seconds these take is what tells them apart.
@Suite(.timeLimit(.minutes(2))) struct DailiesSoundTests {
    /// The take the fixtures write starts at 10:00:00:00.
    private var takeStart: Double { 10 * 3600 }

    /// Through the app's own reader and not `loadTracks(withMediaType:)`:
    /// that one faults in `swift_retain` on macOS 15, which is the runner
    /// (`AVAssetTracks.swift`).
    private func tracks(of url: URL) async throws -> [AVAssetTrack] {
        try await AVURLAsset(url: url).tracks(ofType: .audio)
    }

    /// A matched file becomes a second audio track.
    @Test func matchedSoundIsWrittenBesideTheCamerasOwnTrack() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C001.mov"), frames: 50,
            audioChannels: 2)
        let wave = try DailiesRig.writeWave(
            at: root.appendingPathComponent("MIX_001.wav"),
            startSecondsSinceMidnight: takeStart - 1, seconds: 6)
        let facts = try BroadcastWaveReader.read(wave)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, sounds: [facts])
        let daily: URL = try #require(report.items.first?.output,
                                      "the run produced no daily")
        let audio = try await tracks(of: daily)
        #expect(audio.count == 2, """
            the daily has \(audio.count) audio track(s) — the camera's and the \
            recordist's is two
            """)
    }

    /// …and it is NAMED, out of the file's own metadata.
    @Test func theSoundTrackIsNamedFromTheFile() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C002.mov"), frames: 50,
            audioChannels: 2)
        let wave = try DailiesRig.writeWave(
            at: root.appendingPathComponent("SC12A_T3.wav"),
            startSecondsSinceMidnight: takeStart, seconds: 6)
        let facts = try BroadcastWaveReader.read(wave)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, sounds: [facts])
        let daily: URL = try #require(report.items.first?.output)
        var names: [String] = []
        for track in try await tracks(of: daily) {
            // The type spelled out: `[AVMetadataItem]` in an inferred
            // test expression is one of the shapes the runner's older
            // compiler refuses and this one resolves (CLAUDE.md).
            let items: [AVMetadataItem] =
                (try? await track.load(.commonMetadata)) ?? []
            for item in items {
                if let value = try? await item.load(.stringValue) {
                    names.append(value)
                }
            }
        }
        #expect(names.contains { $0.contains("SC12A_T3") }, """
            the daily's audio tracks are named \(names) — none of them names \
            the file the sound came from
            """)
    }

    /// **Sound from another day is not this take's.** A folder pointed at
    /// yesterday produces the daily it always did, with the camera's track and
    /// nothing else — not a silent second track, and not a failure.
    @Test func soundFromAnotherDayIsLeftOutAndTheRunStillSucceeds() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C003.mov"), frames: 50,
            audioChannels: 2)
        let wave = try DailiesRig.writeWave(
            at: root.appendingPathComponent("YESTERDAY.wav"),
            startSecondsSinceMidnight: takeStart - 7 * 3600, seconds: 6)
        let facts = try BroadcastWaveReader.read(wave)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, sounds: [facts])
        #expect(report.isFullySucceeded, "items failed: \(report.failed)")
        let audio = try await tracks(of: try #require(report.items.first?.output))
        #expect(audio.count == 1, """
            the daily has \(audio.count) audio tracks — sound from seven hours \
            away was laid under it
            """)
    }

    /// A take with no sound at all is still a daily. The engine's own rule: one
    /// item's missing sound must not cost the other thirty their dailies.
    @Test func aRunWithNoSoundFolderIsUnchanged() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C004.mov"), frames: 50,
            audioChannels: 2)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"), codec: .proResProxy)
        #expect(report.isFullySucceeded)
        let audio = try await tracks(of: try #require(report.items.first?.output))
        #expect(audio.count == 1)
    }
    /// **A roll much longer than the take does not hang the run**, and its
    /// sound ends with the picture.
    ///
    /// `AVAssetWriter` holds an input back once it runs far ahead of another
    /// that has not been marked finished, and the video input is not marked
    /// until the very end — so an unbounded drain of a long sound leg waits
    /// for ever for a picture that has already stopped. It never showed up on
    /// the per-take files above because a few seconds of surplus fit in the
    /// writer's own buffer; a recordist's running safety is a whole setup
    /// long, and this is that.
    @Test func aRunningSafetyDoesNotHangTheRunOrOutlastThePicture() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await DailiesRig.writeTake(
            at: root.appendingPathComponent("A001C001.mov"), frames: 50,
            audioChannels: 2)
        // two seconds of picture under thirty seconds of sound
        let wave = try DailiesRig.writeWave(
            at: root.appendingPathComponent("SAFETY.wav"),
            startSecondsSinceMidnight: takeStart - 5, seconds: 30)
        let facts = try BroadcastWaveReader.read(wave)

        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Dailies"),
            codec: .proResProxy, sounds: [facts])
        let daily: URL = try #require(report.items.first?.output,
                                      "the run produced no daily")
        let asset = AVURLAsset(url: daily)
        let audio: [AVAssetTrack] = try await asset.tracks(ofType: .audio)
        #expect(audio.count == 2, "the roll did not reach the daily")
        let video: AVAssetTrack = try #require(
            try await asset.tracks(ofType: .video).first)
        let picture = try await video.load(.timeRange).duration.seconds
        // A second past the picture and not thirty: the pump keeps the sound
        // a second AHEAD of the frame in hand on purpose (that lead is what
        // stops the writer holding the picture back), so a daily's sound
        // legitimately ends up to `audioLead` past its last frame plus an AAC
        // packet. What must not happen is the roll's whole length.
        let allowed = picture
            + DailiesTranscode.audioLead.seconds + 0.2
        for track in audio {
            let sound = try await track.load(.timeRange).duration.seconds
            #expect(sound <= allowed,
                    Comment(rawValue: "a sound track runs \(sound)s under "
                        + "\(picture)s of picture"))
        }
    }

}
