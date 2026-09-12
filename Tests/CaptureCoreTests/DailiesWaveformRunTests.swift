import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

/// **A roll with no timecode, placed by ear** (owner: "ну и если ВДРУГ есть
/// возможность – синк дублей не только по таймкоду со звуком но еще и по
/// вейвформе").
///
/// The take and the wave here are two recordings of ONE room: the same
/// aperiodic loudness contour as a function of absolute time, at different
/// gains. That is the situation — a boom and a camera mic — and the wave
/// carries no `bext` at all, so nothing but the sound itself can place it.
@Suite(.timeLimit(.minutes(3))) struct DailiesWaveformRunTests {
    /// The take covers absolute 0…4 s of the room.
    private func take(at url: URL, room: UInt64 = 100) async throws -> URL {
        try await DailiesRig.writeTake(at: url, frames: 100, audioChannels: 2,
                                       room: room)
    }

    /// …and the wave covers −2…10 s of it, so the take starts two seconds in.
    private func wave(at url: URL, room: UInt64 = 100,
                      timecode: Bool = false) throws -> URL {
        try DailiesRig.writeWave(
            at: url, startSecondsSinceMidnight: 0, seconds: 12,
            room: room, from: -2, withTimecode: timecode)
    }

    private func facts(_ url: URL) throws -> BroadcastWaveFacts {
        try BroadcastWaveReader.read(url)
    }

    private func audioTracks(of url: URL) async throws -> Int {
        try await AVURLAsset(url: url).tracks(ofType: .audio).count
    }

    /// **The whole feature.** Without the switch the roll cannot be placed and
    /// the daily has the camera's sound alone; with it, the roll is found and
    /// the daily carries both.
    @Test func aRollWithNoTimecodeIsPlacedByEar() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await take(at: root.appendingPathComponent("A.mov"))
        let sound = try facts(try wave(at: root
            .appendingPathComponent("boom.wav")))
        #expect(sound.startSecondsSinceMidnight == nil,
                "the fixture wave has timecode after all")

        let deaf = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Deaf"),
            codec: .proResProxy, sounds: [sound])
        let withoutEars: URL = try #require(deaf.items.first?.output)
        #expect(try await audioTracks(of: withoutEars) == 1,
                "a roll with no timecode reached a daily that was not listening")

        let heard = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("Heard"),
            codec: .proResProxy, sounds: [sound], waveformSync: true)
        let withEars: URL = try #require(heard.items.first?.output)
        #expect(try await audioTracks(of: withEars) == 2,
                "the roll was not found by ear")
    }

    /// **A roll from another scene is not attached to this take.** There is
    /// always a best lag; what must not happen is a confident wrong answer,
    /// because a sound file on the wrong take is worse than one on nothing.
    @Test func aRollFromAnotherRoomIsNotAttached() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await take(at: root.appendingPathComponent("A.mov"),
                                    room: 100)
        let sound = try facts(try wave(
            at: root.appendingPathComponent("other.wav"), room: 7))
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"),
            codec: .proResProxy, sounds: [sound], waveformSync: true)
        let daily: URL = try #require(report.items.first?.output)
        #expect(try await audioTracks(of: daily) == 1,
                "a roll from another room was attached to this take")
    }

    /// A file that HAS timecode is placed by the clock and is never listened
    /// to: a correlation that disagreed with a recordist's timecode would be
    /// the app being confidently wrong about the one thing the file states
    /// about itself.
    @Test func aRollWithTimecodeIsNotListenedTo() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await take(at: root.appendingPathComponent("A.mov"))
        // timecode that puts it nowhere near the take
        let sound = try facts(try DailiesRig.writeWave(
            at: root.appendingPathComponent("timed.wav"),
            startSecondsSinceMidnight: 3 * 3600, seconds: 12,
            room: 100, from: -2, withTimecode: true))
        #expect(sound.startSecondsSinceMidnight != nil)
        let report = await DailiesEngine.run(
            items: [DailiesRig.item(for: source)],
            burnins: DailiesRig.noBurnins,
            into: root.appendingPathComponent("D"),
            codec: .proResProxy, sounds: [sound], waveformSync: true)
        let daily: URL = try #require(report.items.first?.output)
        #expect(try await audioTracks(of: daily) == 1,
                "a timecoded roll was placed by ear instead of by its clock")
    }

    /// The candidates are the rolls with no timecode and nothing else, and
    /// only when the run was asked to listen.
    @Test func onlyTheRollsWithNoTimecodeAreListenedTo() async throws {
        let root = try DailiesRig.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let deaf = try facts(try wave(
            at: root.appendingPathComponent("deaf.wav")))
        let timed = try facts(try DailiesRig.writeWave(
            at: root.appendingPathComponent("timed.wav"),
            startSecondsSinceMidnight: 36_000, seconds: 4))
        #expect(await DailiesEngine.waveformCandidates([deaf, timed],
                                                       enabled: false).isEmpty)
        let listening = await DailiesEngine.waveformCandidates([deaf, timed],
                                                               enabled: true)
        #expect(listening.count == 1)
        #expect(listening.first?.sound.url.lastPathComponent == "deaf.wav")
        #expect(listening.first?.envelope.isEmpty == false)
    }
}
