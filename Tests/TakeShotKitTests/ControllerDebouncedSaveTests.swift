import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// **Everything that waits gets written on the way out.**
///
/// Five values are written to settings on a debounce — the monitor volume, the
/// mute and dim holds, the assist state, the LUT intensity — because each is
/// driven by a slider or a hotkey that can move ten times a second. The
/// debounce had no flush: `flushOnTerminate` emptied ONE of them, and a level
/// set inside the last 400 ms before Quit was gone (owner: "я вижу что он не
/// сохранил после шатдауна… установленную громкость звука").
@Suite @MainActor struct ControllerDebouncedSaveTests {
    @Test func aLevelSetAMomentBeforeQuitIsStillWritten() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorVolume = 0.42
            // Inside the debounce window: nothing is in settings yet.
            #expect(controller.settings.audio.monitorVolume != 0.42,
                    "the write was not debounced at all")
            #expect(controller.debounced.isPending(.monitorVolume))

            controller.debounced.flushAll()
            #expect(controller.settings.audio.monitorVolume == 0.42,
                    "the level went down with the process")
            #expect(!controller.debounced.isPending)
        }
    }

    /// **Every slot, not just the one somebody remembered.** The case list is
    /// what `flushAll` walks, so a new debounced setting cannot arrive without
    /// a flush — which is the whole reason it is a set rather than five named
    /// tasks.
    @Test func everySlotIsFlushed() {
        let queue = DebouncedSettings()
        var written: Set<DebouncedSettings.Slot> = []
        for slot in DebouncedSettings.Slot.allCases {
            queue.schedule(slot, after: .seconds(30)) { written.insert(slot) }
        }
        #expect(queue.isPending)
        queue.flushAll()
        let missed = Set(DebouncedSettings.Slot.allCases).subtracting(written)
        #expect(missed.isEmpty, "a slot was left waiting: \(missed)")
        #expect(!queue.isPending)
    }

    /// The last value wins — that is what a debounce is for, and a flush must
    /// write the newest rather than replaying every move.
    @Test func theLastValueIsTheOneWritten() {
        let queue = DebouncedSettings()
        var written: [Int] = []
        for value in 1...5 {
            queue.schedule(.monitorVolume, after: .seconds(30)) {
                written.append(value)
            }
        }
        queue.flush(.monitorVolume)
        #expect(written == [5], "\(written)")
    }

    /// A cancelled slot is not written by a later flush: a value superseded by
    /// a write from somewhere else must not come back.
    @Test func aCancelledSlotStaysCancelled() {
        let queue = DebouncedSettings()
        var written = false
        queue.schedule(.assist, after: .seconds(30)) { written = true }
        queue.cancel(.assist)
        queue.flushAll()
        #expect(!written, "a cancelled write was performed anyway")
    }

    /// Flushing twice writes once — the second flush has nothing to write,
    /// which is what keeps `flushOnTerminate` idempotent.
    @Test func flushingTwiceWritesOnce() {
        let queue = DebouncedSettings()
        var count = 0
        queue.schedule(.lutIntensity, after: .seconds(30)) { count += 1 }
        queue.flushAll()
        queue.flushAll()
        #expect(count == 1)
    }

    /// The mute and dim HOLDS are stored too — they are states an operator
    /// engaged, and coming back to a room that is quiet for no visible reason
    /// is worse than coming back to full level.
    @Test func theHoldsSurviveTheWayOut() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.monitorVolume = 0.8
            controller.debounced.flushAll()
            controller.toggleMonitorMute()
            controller.debounced.flushAll()
            #expect(controller.settings.audio.monitorMuted == true)
            #expect(controller.settings.audio.monitorVolume == 0.8,
                    "the mute stored its own zero as the level")
        }
    }
}

/// **The card list survives a quit** (owner: "он не сохранил после шатдауна
/// задачку оффлоада последнюю").
///
/// A copy interrupted by a crash or a quit is resumed from the same card, and
/// re-picking it through a file panel is the part of that the operator should
/// not have to do twice. Only cards still MOUNTED come back: a path to an
/// unplugged card is not a card.
@Suite @MainActor struct ControllerOffloadSourceMemoryTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeshot-osrc-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    @Test func theCardsComeBackWithTheSheet() async throws {
        try await ControllerHarness.run { controller, _ in
            let card = try self.scratch("card")
            defer { try? FileManager.default.removeItem(at: card) }
            let model = controller.offload
            model.addSource(card)
            #expect(controller.settings.offload.sourcePaths == [card.path])

            // A fresh sheet over the same settings.
            let second = OffloadSheetModel()
            second.attach(to: controller)
            second.prepare(settings: controller.settings, version: "test")
            #expect(second.sources.map(\.path) == [card.path],
                    "the card list did not come back: \(second.sources)")
        }
    }

    @Test func anUnpluggedCardDoesNotComeBack() async throws {
        try await ControllerHarness.run { controller, _ in
            let card = try self.scratch("gone")
            let model = controller.offload
            model.addSource(card)
            try FileManager.default.removeItem(at: card)

            let second = OffloadSheetModel()
            second.attach(to: controller)
            second.prepare(settings: controller.settings, version: "test")
            #expect(second.sources.isEmpty,
                    "an unplugged card came back: \(second.sources)")
        }
    }

    /// Removing a card is recorded — the destinations' rule, and it is there
    /// because a removal has to have somewhere to be written down.
    @Test func removingACardIsRemembered() async throws {
        try await ControllerHarness.run { controller, _ in
            let card = try self.scratch("card2")
            defer { try? FileManager.default.removeItem(at: card) }
            let model = controller.offload
            model.addSource(card)
            let row = try #require(model.sourceRows.first)
            model.removeSource(row.id)
            #expect(controller.settings.offload.sourcePaths == nil,
                    "the removal was not recorded")
        }
    }

    /// A sheet reopened over a list the operator is building must not have
    /// rows put back into it.
    @Test func aListInProgressIsNotSeededOver() async throws {
        try await ControllerHarness.run { controller, _ in
            let saved = try self.scratch("saved")
            let building = try self.scratch("building")
            defer {
                for url in [saved, building] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            controller.settings.offload.sourcePaths = [saved.path]
            let model = OffloadSheetModel()
            model.attach(to: controller)
            model.addSource(building)
            model.prepare(settings: controller.settings, version: "test")
            #expect(model.sources.map(\.path) == [building.path],
                    "the saved card was seeded over a list in progress")
        }
    }
}

/// **No debounced settings write may live outside the queue.**
///
/// The audit the owner asked for ("проверь что еще не сохраняет и тоже засейви
/// из такого важного"), as a rule rather than as a list: a write on a task of
/// its own is a write `flushOnTerminate` does not know about, which is exactly
/// how the volume came to be lost. One of the six was still on its own task
/// when this was written — the conversion had missed it — and this is what
/// found it.
@Suite struct NoStrayDebouncedWriteTests {
    @Test func nothingSchedulesASettingsWriteOnItsOwnTask() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakeShotKit")
        let walker = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            files += 1
            for (index, line) in raw.components(separatedBy: "\n").enumerated()
            where line.contains("PersistTask") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        try #require(files > 100, "the walk did not find the source tree")
        #expect(offenders.isEmpty, """
            a settings write is debounced on a task of its own, so nothing \
            flushes it on the way out: \(offenders.joined(separator: ", "))
            """)
    }
}
