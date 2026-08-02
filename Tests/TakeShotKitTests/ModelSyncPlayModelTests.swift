import AVFoundation
import CaptureCore
import CoreMedia
import Foundation
import Testing

@testable import TakeShotKit

/// The sync-play session over real generated media: one master transport, one
/// synchronized start, and the players staying within a frame of each other.
///
/// Drift is the contract this feature lives on: two performances a few frames
/// apart read as a different comparison, so the suite measures the spread of
/// the players' master-domain positions directly and holds it to one frame.
@Suite @MainActor struct ModelSyncPlayModelTests {
    /// One frame at the fixtures' 25 fps — the drift budget.
    private static let frame = 1.0 / 25.0

    /// Real clips through the app's own writer, one per spec, plus the source
    /// descriptions a session is built from.
    private func writeSources(
        _ specs: [(tc: Timecode?, frames: Int)],
        in directory: URL) async throws -> [SyncPlayModel.Source] {
        var sources: [SyncPlayModel.Source] = []
        for (index, spec) in specs.enumerated() {
            let url = try await MediaFixtures.writeClip(
                at: directory.appendingPathComponent("take\(index).mov"),
                frames: spec.frames, startTimecode: spec.tc)
            sources.append(SyncPlayModel.Source(
                url: url, name: "take\(index)", startTimecode: spec.tc,
                duration: Double(spec.frames) / 25.0))
        }
        return sources
    }

    /// How far apart the players' master-domain positions are right now —
    /// the widest pairwise disagreement, in seconds.
    private func spread(of model: SyncPlayModel) -> Double {
        let positions = model.tiles.enumerated().map { index, tile in
            tile.player.currentTime().seconds - model.schedule.offsets[index]
        }
        guard positions.allSatisfy(\.isFinite),
              let top = positions.max(), let bottom = positions.min()
        else { return .infinity }
        return top - bottom
    }

    /// Play drives ALL players, and their clocks agree within a frame — the
    /// shared-host-time start, measured rather than assumed.
    @Test func playDrivesEveryPlayerInLockstep() async throws {
        let media = try MediaFixtures.makeDirectory("sync-lockstep")
        defer { try? FileManager.default.removeItem(at: media) }
        let sources = try await writeSources(
            [(MediaFixtures.startTimecode, 100),
             (Timecode(hours: 10, minutes: 0, seconds: 0, frames: 12, fps: 25), 100),
             (Timecode(hours: 10, minutes: 0, seconds: 1, frames: 0, fps: 25), 100)],
            in: media)
        let model = SyncPlayModel(sources: sources)
        defer { model.shutDown() }

        model.play()
        #expect(model.isPlaying)

        let rolling = await ControllerWait.untilWritten {
            model.tiles.allSatisfy { $0.player.rate == 1 }
        }
        #expect(rolling, "play did not start every player")

        let locked = await ControllerWait.untilWritten {
            self.spread(of: model) <= Self.frame
                && model.tiles.allSatisfy { $0.player.currentTime().seconds > 0.2 }
        }
        let measured = spread(of: model)
        #expect(locked, "the players never agreed: spread \(measured) s")
        #expect(measured <= Self.frame,
                "players drifted \(measured) s apart (budget \(Self.frame))")

        // pausing re-aligns everyone on the exact frame the master stopped on
        model.pause()
        #expect(!model.isPlaying)
        let parked = await ControllerWait.untilWritten {
            model.tiles.allSatisfy { $0.player.rate == 0 }
                && self.spread(of: model) <= Self.frame
        }
        #expect(parked, "paused players disagree: \(spread(of: model)) s")
    }

    /// By-TC alignment seeks each clip to its own offset: the same wall-clock
    /// moment parked in every tile before anything plays.
    @Test func byTimecodeParksEachClipAtItsOffset() async throws {
        let media = try MediaFixtures.makeDirectory("sync-tc-park")
        defer { try? FileManager.default.removeItem(at: media) }
        // ranges rel. 10:00:00 — [0,3] [1,3] [0.48,3]: window [1,3], length 2
        let sources = try await writeSources(
            [(Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25), 75),
             (Timecode(hours: 10, minutes: 0, seconds: 1, frames: 0, fps: 25), 50),
             (Timecode(hours: 10, minutes: 0, seconds: 0, frames: 12, fps: 25), 63)],
            in: media)
        let model = SyncPlayModel(sources: sources, alignmentMode: .byTimecode)
        defer { model.shutDown() }

        #expect(model.schedule.usedTimecode)
        #expect(abs(model.schedule.length - 2) < 1e-9)
        let expected = [1.0, 0.0, 0.52]
        for (offset, wanted) in zip(model.schedule.offsets, expected) {
            #expect(abs(offset - wanted) < 1e-9,
                    "offset \(offset), expected \(wanted)")
        }

        let parked = await ControllerWait.untilWritten {
            model.tiles.enumerated().allSatisfy { index, tile in
                let time = tile.player.currentTime().seconds
                return time.isFinite
                    && abs(time - model.schedule.offsets[index]) <= Self.frame / 2
            }
        }
        #expect(parked, "the tiles never parked on their aligned first frames")

        // the tile labels read the window's start in each take's own TC
        #expect(model.tileTimecodeText(0) == "10:00:01:00")
        #expect(model.tileTimecodeText(1) == "10:00:01:00")
        #expect(model.tileTimecodeText(2) == "10:00:01:00")
    }

    /// A seek re-issues the synchronized start: the players land together at
    /// the new position, still rolling, still within a frame.
    @Test func seekingResyncsEveryPlayer() async throws {
        let media = try MediaFixtures.makeDirectory("sync-seek")
        defer { try? FileManager.default.removeItem(at: media) }
        let sources = try await writeSources(
            [(MediaFixtures.startTimecode, 100), (MediaFixtures.startTimecode, 100)],
            in: media)
        let model = SyncPlayModel(sources: sources)
        defer { model.shutDown() }

        model.play()
        let rolling = await ControllerWait.untilWritten {
            model.tiles.allSatisfy { $0.player.rate == 1 }
        }
        #expect(rolling)

        model.seek(to: 0.4)
        let resynced = await ControllerWait.untilWritten {
            model.tiles.allSatisfy {
                $0.player.rate == 1 && $0.player.currentTime().seconds >= 0.4
            } && self.spread(of: model) <= Self.frame
        }
        #expect(resynced,
                "seek while playing lost the lock: \(spread(of: model)) s")

        // paused seeks are exact: zero-tolerance parks at the target
        model.pause()
        model.seek(to: 1.0)
        let parked = await ControllerWait.untilWritten {
            model.tiles.allSatisfy {
                abs($0.player.currentTime().seconds - 1.0) <= Self.frame / 2
            }
        }
        #expect(parked, "a paused seek missed its mark")
        #expect(model.position.currentTime == 1.0)
    }

    /// By-start with unequal lengths: the shorter take freezes on its last
    /// frame while the longer plays on, and the transport runs to the longest
    /// clip's end — no looping mid-comparison.
    @Test func shorterClipsFreezeOnTheirLastFrame() async throws {
        let media = try MediaFixtures.makeDirectory("sync-freeze")
        defer { try? FileManager.default.removeItem(at: media) }
        let sources = try await writeSources(
            [(MediaFixtures.startTimecode, 15), (MediaFixtures.startTimecode, 40)],
            in: media)
        let model = SyncPlayModel(sources: sources)
        defer { model.shutDown() }

        #expect(model.schedule.length == 1.6)
        model.play()

        // the short take runs out at 0.6 s and holds; the long one keeps going
        let froze = await ControllerWait.untilWritten {
            model.tiles[0].player.rate == 0 && model.tiles[1].player.rate == 1
        }
        #expect(froze, "the short take did not freeze while the long one played")
        let shortTime = model.tiles[0].player.currentTime().seconds
        #expect(shortTime >= 0.6 - 2 * Self.frame,
                "the short take rewound instead of freezing: \(shortTime)")

        // …until the master timeline itself runs out and everything stops
        let ended = await ControllerWait.untilWritten { !model.isPlaying }
        #expect(ended, "the transport never reached the end")
        #expect(model.position.currentTime >= 1.6 - 0.1)
        let frozen = model.tiles[0].player.currentTime().seconds
        #expect(frozen >= 0.6 - 2 * Self.frame,
                "the short take looped after freezing: \(frozen)")
    }

    /// One take audible at a time: the first by default, the speaker toggle
    /// moves it, and it is never a mix.
    @Test func exactlyOneTakeIsAudible() async throws {
        let media = try MediaFixtures.makeDirectory("sync-audio")
        defer { try? FileManager.default.removeItem(at: media) }
        let sources = try await writeSources(
            [(MediaFixtures.startTimecode, 5), (MediaFixtures.startTimecode, 5),
             (MediaFixtures.startTimecode, 5)],
            in: media)
        let model = SyncPlayModel(sources: sources)
        defer { model.shutDown() }

        #expect(model.tiles.map(\.player.isMuted) == [false, true, true])

        model.audibleIndex = 2
        #expect(model.tiles.map(\.player.isMuted) == [true, true, false])
        #expect(model.tiles.filter { !$0.player.isMuted }.count == 1)
    }

    /// Switching the alignment rebuilds the schedule and rewinds paused — a
    /// master second means something different under the other rule.
    @Test func switchingAlignmentRebuildsTheSchedule() async throws {
        let media = try MediaFixtures.makeDirectory("sync-switch")
        defer { try? FileManager.default.removeItem(at: media) }
        let sources = try await writeSources(
            [(Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 25), 75),
             (Timecode(hours: 10, minutes: 0, seconds: 1, frames: 0, fps: 25), 75)],
            in: media)
        let model = SyncPlayModel(sources: sources)
        defer { model.shutDown() }

        #expect(!model.schedule.usedTimecode)
        #expect(model.schedule.length == 3)

        model.play()
        model.alignmentMode = .byTimecode

        #expect(!model.isPlaying, "an alignment switch must not keep rolling")
        #expect(model.position.currentTime == 0)
        #expect(model.schedule.usedTimecode)
        #expect(abs(model.schedule.length - 2) < 1e-9)
        #expect(model.schedule.offsets.first.map { abs($0 - 1) < 1e-9 } == true)
    }
}
