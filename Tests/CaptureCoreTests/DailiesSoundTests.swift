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
@Suite struct DailiesSoundTests {
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
}
